import SwiftUI

// Settings (Cmd+,): language, the planner used by the Clean Up panel, and
// custom model providers — any OpenAI- or Anthropic-compatible endpoint by
// its base URL, protocol and key. Provider plans arrive over plain HTTPS;
// AppleTree's own guards and two-step delete are AppleTree's own.

// MARK: - Providers

struct ProvidersView: View {
    @State private var store = ProviderStore.shared
    @State private var editing: ProviderForm?
    private let router = SettingsRouter.shared
    /// The last add-provider request this view has honoured.
    ///
    /// A request can arrive before Settings exists (a click in the main window
    /// opens Settings as a side effect), so the router hands out a counter and
    /// this remembers what it has seen. Wiring the form to a plain flag would
    /// drop exactly that first click — the one the user made.
    @State private var handledRequest = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Custom model providers")
                    .font(.headline)
                Spacer()
                Button { editing = .new } label: {
                    Label("Add provider", systemImage: "plus")
                }
            }
            Text("Connect a relay, a self-hosted server, or any other OpenAI- or Anthropic-compatible endpoint by its base URL, protocol, and models.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if store.providers.isEmpty {
                Text("No custom providers. Add one to let AppleTree plan a cleanup for you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            } else {
                List(store.providers) { provider in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName)
                            Text("\(provider.model) · \(provider.baseURL.absoluteString)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { editing = .existing(provider) }
                        Button("Delete", role: .destructive) { store.delete(provider) }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(item: $editing) { form in
            ProviderFormView(initial: form)
        }
        // Honour a pending "Add a model provider" from anywhere in the app, and
        // keep honouring new ones for as long as this view is mounted.
        .onChange(of: router.addProviderRequests, initial: true) { _, pending in
            guard pending > handledRequest else { return }
            handledRequest = pending
            editing = .new
        }
        // Honour any pending "edit this provider", then drain them. The router
        // hands the id and its token out together and clears the queue, so this
        // cannot pair a token with the wrong provider, cannot drop one of two
        // requests made in quick succession, and cannot replay a request on a
        // later appearance of this view — which is what would otherwise raise a
        // form the user never asked for on first show.
        //
        // Resolved through the store, so a request naming a provider that has
        // since been deleted opens nothing rather than a form for something
        // that no longer exists.
        .onChange(of: router.editProviderRequests, initial: true) { _, _ in
            for request in router.takePendingEditRequests() {
                guard let provider = store.providers.first(where: { $0.id == request.id }) else { continue }
                editing = .existing(provider)
            }
        }
    }
}

/// What the sheet edits: a brand-new provider or an existing one.
enum ProviderForm: Identifiable {
    case new
    case existing(LLMProvider)
    var id: String { switch self { case .new: "new"; case .existing(let p): p.id } }
    var isNew: Bool { if case .new = self { return true }; return false }
}

/// The add/edit sheet: provider ID, display name, base URL, protocol, key,
/// models — mirroring how other tools name these fields.
struct ProviderFormView: View {
    let initial: ProviderForm

    @Environment(\.dismiss) private var dismiss
    @State private var id = ""
    @State private var displayName = ""
    @State private var baseURL = ""
    @State private var api: APIProtocol = .openAIChat
    @State private var key = ""
    @State private var model = ""
    @State private var models: [String] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Custom model API")
                .font(.headline)
            field(String(localized: "Provider ID"), text: $id, placeholder: "acme-gateway",
                  caption: String(localized: "Lowercase identifier, starting with a letter, that uniquely names this provider in requests and as its credential name."))
            field(String(localized: "Display name"), text: $displayName, placeholder: String(localized: "Display name"))
            field(String(localized: "Base URL"), text: $baseURL, placeholder: "https://gateway.example/v1")
            Picker("API protocol", selection: $api) {
                ForEach(APIProtocol.allCases) { proto in
                    Text(proto.label).tag(proto)
                }
            }
            SecureField("Enter your API key", text: $key)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Models").font(.callout)
                    Spacer()
                    Button("Fetch available models") { Task { await fetchModels() } }
                        .disabled(baseURL.isEmpty)
                }
                if models.isEmpty {
                    Text("No models will be shown in the selector. Unlisted IDs can still be sent directly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    Picker("Model", selection: $model) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                        // Keep a typed-but-unlisted ID selectable, but only when
                        // it is not already a row. This tag used to be added
                        // unconditionally, so a model that the endpoint listed
                        // *and* was already selected appeared twice in the menu.
                        if !model.isEmpty && !models.contains(model) {
                            Text(model).tag(model)
                        }
                    }
                }
                TextField("Model ID", text: $model, prompt: Text("gpt-4o-mini"))
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(initial.isNew ? String(localized: "Create provider")
                                      : String(localized: "Save changes")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 520, alignment: .leading)
        .onAppear {
            if case .existing(let p) = initial {
                id = p.id; displayName = p.displayName; baseURL = p.baseURL.absoluteString
                api = p.api; model = p.model
                key = ProviderStore.getKey(for: p.id) ?? ""
            }
        }
    }

    private var isValid: Bool {
        // The id doubles as the Keychain credential name; keep it strict.
        id.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil
            && URL(string: baseURL)?.scheme != nil && !model.isEmpty
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout)
            TextField(placeholder, text: text, prompt: Text(placeholder))
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// GET /models (OpenAI shape) — a nicety; endpoints without it just stay
    /// on the typed model ID.
    private func fetchModels() async {
        error = nil
        guard let base = URL(string: baseURL) else { return }
        var request = URLRequest(url: base.appending(path: "models"))
        request.timeoutInterval = 15
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            let body = String(decoding: data, as: UTF8.self)
            guard (200..<300).contains(http.statusCode) else {
                // Endpoints say why (bad key, wrong URL); quote them rather
                // than a generic caption.
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    .flatMap { $0["error"] as? [String: Any] }?["message"] as? String
                    ?? body.split(separator: "\n").first.map(String.init) ?? ""
                error = String(localized: "HTTP \(http.statusCode): \(message.prefix(200))")
                return
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = obj["data"] as? [[String: Any]] {
                // An endpoint can list the same id twice, and the Picker keys
                // rows by the string itself — a repeat rendered the same model
                // twice. Set drops the repeats; sorted() keeps the old order.
                models = Set(list.compactMap { $0["id"] as? String }).sorted()
            } else {
                error = String(localized: "Could not read a model list from this endpoint; type the ID.")
            }
        } catch {
            self.error = String(localized: "Could not fetch models: \(error.localizedDescription)")
        }
    }

    private func save() {
        guard let url = URL(string: baseURL) else { return }
        let provider = LLMProvider(id: id, displayName: displayName.isEmpty ? id : displayName,
                                   baseURL: url, api: api, model: model)
        ProviderStore.shared.save(provider, key: key.isEmpty ? nil : key)
        dismiss()
    }
}

// MARK: - Language

/// Languages AppleTree ships strings for. "system" follows macOS; a picked
/// language applies at next launch (AppleLanguages). Never use "" as a Picker
/// identity: an empty tag renders as a blank selection row.
let availableLanguages: [(code: String, name: String)] = [
    ("system", String(localized: "Follow system")),
    ("en", "English"),
    ("tr", "Türkçe"),
    ("de", "Deutsch"),
    ("fr", "Français"),
    ("es", "Español"),
    ("zh-Hans", "简体中文"),
    ("ja", "日本語"),
]

/// The language this app itself stored, or nil when it has never been set.
///
/// The app's own domain only: `UserDefaults.standard` would also surface the
/// system-wide AppleLanguages list (typically "en-US" and friends), which is
/// not a picker tag and made the row render blank.
func storedAppLanguage() -> String? {
    let domain = Bundle.main.bundleIdentifier ?? "com.erklab.apps.appletree"
    return (UserDefaults.standard.persistentDomain(forName: domain)?["AppleLanguages"] as? [String])?.first
}

/// The shipped code matching a language tag — "en-US" → "en",
/// "zh-Hans-CN" → "zh-Hans" — or nil when AppleTree ships no table for it.
func shippedLanguageCode(for tag: String) -> String? {
    let lower = tag.lowercased()
    let shipped = availableLanguages.filter { $0.code != "system" }
    if let exact = shipped.first(where: { $0.code.lowercased() == lower }) { return exact.code }
    // Longest prefix wins, so "zh-Hans-CN" matches "zh-Hans", not a bare "zh".
    return shipped
        .filter { lower.hasPrefix($0.code.lowercased() + "-") }
        .max { $0.code.count < $1.code.count }?.code
}

struct GeneralSettingsView: View {
    /// The saved choice, "system" when following macOS.
    @State private var language: String
    @State private var saved: String
    /// Scan automatically at launch. Default off: the absence of a stored
    /// value means "do not scan", so a first run never starts a whole-disk
    /// scan before the user has chosen. Changing this here also answers the
    /// one-time home-screen offer, so the two cannot disagree.
    @AppStorage("bz.autoScan") private var autoScan = false

    init() {
        // Default "system" (Follow system). A stored tag is normalized to a
        // shipped code so the Picker always has a matching row to show.
        let savedCode = storedAppLanguage().flatMap(shippedLanguageCode(for:)) ?? "system"
        _language = State(initialValue: savedCode)
        _saved = State(initialValue: savedCode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Every row flush left: the pickers are given a leading-aligned
            // frame, otherwise their label+pull-down pair centres itself and
            // the rows no longer line up with the toggle and captions below.
            Picker("Language", selection: $language) {
                ForEach(availableLanguages, id: \.code) { entry in
                    Text(entry.name).tag(entry.code)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if language != saved {
                HStack(spacing: 8) {
                    Text("Relaunch AppleTree to apply the language.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Relaunch") {
                        if language == "system" {
                            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                        } else {
                            UserDefaults.standard.set([language], forKey: "AppleLanguages")
                        }
                        saved = language
                        FDA.relaunch()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Scan when AppleTree opens", isOn: $autoScan)
                    // Settings is the durable home of this preference; changing
                    // it deliberately also answers the first-run offer, so the
                    // home screen never re-asks a question already decided here.
                    .onChange(of: autoScan) { ScanModel.answerAutoScan(autoScan) }
                Text("Scan the whole disk at launch. Turn off to pick a folder yourself first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            PlannerSettingsView()
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: 420, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
    }

}

/// The "Clean Up planner" row.
///
/// It lists the same catalog the Clean Up panel's menu does, so the planner
/// Settings shows and the one the panel runs cannot disagree — they used to
/// keep separate fallback rules (Settings preferred the first provider, the
/// panel preferred a ready provider), which is how the two surfaces could point at
/// different engines while both looked correct.
private struct PlannerSettingsView: View {
    /// Re-read when model providers are added, edited or deleted.
    @State private var store = ProviderStore.shared

    private var choices: [PlannerChoice] {
        PlannerChoice.catalog(providers: store.providers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if choices.isEmpty {
                Text("No planner configured.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Clean Up planner", selection: Binding(
                    get: {
                        PlannerChoice.preferredID(stored: store.engineTag, in: choices)
                            ?? choices[0].id
                    },
                    // Written through the store, which publishes it: a direct
                    // `UserDefaults.set` left the Picker reading a value it
                    // could not observe, so the checkmark never moved.
                    set: { (value: String) in store.select(engineTag: value) }
                )) {
                    ForEach(choices) { choice in
                        Text(choice.settingsLabel).tag(choice.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Which AI proposes what can go from the scan. Nothing is removed without your say.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
