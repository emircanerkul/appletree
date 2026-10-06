import AppKit
import SwiftUI

/// Right-hand inspector: what can be reclaimed, pick, trash, rescan. While an
/// agent cleanup is on screen, the whole panel is that run.
struct CleanupPanel: View {
    let model: ScanModel
    /// Raises the Settings window. Needed to reach the add-provider form, which
    /// lives in a Scene the panel cannot call into directly.
    @Environment(\.openSettings) private var openSettings
    /// Ticked rows, keyed by PATH.
    ///
    /// This was a `Set<Int>` of node IDs, which a rescan invalidates: node IDs
    /// are slots in one scan's arrays (see `Cleanup.find`), and the engine
    /// renumbers them on every walk, so ticks silently vanished or — worse —
    /// re-bound to a folder the user never picked, which is the folder the
    /// Move button then acted on. Paths are the identity this file's own
    /// convention already uses for anything that outlives one scan.
    @State private var picked: Set<String> = []
    @State private var confirming = false
    /// The agent a sign-out was confirmed for, or nil.
    @State private var signingOut: AgentKind?

    /// The single source of truth for what Move acts on: the ticks that still
    /// resolve against the CURRENT scan. Every other read of the selection —
    /// the label, the byte total, the enabled state, the dialog — derives from
    /// this, so the count a user is shown is always the count that moves.
    private var pickedItems: [CleanupItem] {
        model.cleanup.filter { picked.contains($0.path) }
    }
    private var pickedBytes: UInt64 { pickedItems.reduce(0) { $0 + $1.bytes } }
    private var totalBytes: UInt64 { model.cleanup.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        Group {
            if let run = model.agentRun {
                AgentRunView(run: run, model: model, retry: { model.restart(run) }) {
                    run.cancel()
                    withAnimation(.snappy) { model.agentRun = nil }
                }
                .transition(.opacity)
            } else {
                reclaimable
                    .transition(.opacity)
            }
        }
        .confirmationDialog(pickedItems.count == 1 ? "Move 1 folder to the Trash?" : "Move \(String(pickedItems.count)) folders to the Trash?", isPresented: $confirming) {
            Button("Move to Trash (\(Fmt.size(pickedBytes)))", role: .destructive) { trashPicked() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can put them back from the Trash until you empty it. The tools that made them rebuild them when needed.")
        }
        .confirmationDialog(signOutTitle, isPresented: Binding(
            get: { signingOut != nil }, set: { if !$0 { signingOut = nil } }
        ), titleVisibility: .visible) {
            if let kind = signingOut {
                Button(String(localized: "Sign out of \(kind.name)"), role: .destructive) {
                    signingOut = nil
                    Task { await model.signOut(kind) }
                }
            }
            Button("Cancel", role: .cancel) { signingOut = nil }
        } message: {
            Text(signOutMessage)
        }
        // App Store Guideline 5.1.2(i): explicit permission before personal data
        // goes to a third party, "including with third-party AI". The disclosure
        // names the destination and describes the payload, and no cleanup starts
        // until the user answers. Declining leaves the app fully usable.
        .confirmationDialog(
            String(localized: "Send a summary of this scan to \(model.pendingConsentDestination)?"),
            isPresented: Binding(
                get: { model.pendingConsent },
                set: { if !$0 { model.declineCleanupConsent() } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Send and clean up")) { model.grantCleanupConsent() }
            Button("Cancel", role: .cancel) { model.declineCleanupConsent() }
        } message: {
            Text("AppleTree will send \(model.pendingConsentDestination) the paths, names, sizes and dates of the largest items in this scan — folder and file names, but never the contents of your files. They leave your Mac and are handled under that provider's own terms. Sending it is what lets a planner suggest what to remove.")
        }
        // A real binding, not `.constant(...)`: the constant form only ever
        // dismissed because the OK action happened to clear the array first,
        // leaving a permanently-true presentation behind it.
        .alert("Some folders couldn't be moved", isPresented: Binding(
            get: { !model.cleanupTrash.failures.isEmpty },
            set: { if !$0 { model.cleanupTrash.clearFailures() } }
        )) {
            Button("OK") { model.cleanupTrash.clearFailures() }
        } message: {
            Text(model.cleanupTrash.failures.joined(separator: "\n"))
        }
        .alert("Couldn't sign out", isPresented: Binding(
            get: { model.signOutFailure != nil }, set: { if !$0 { model.signOutFailure = nil } }
        )) {
            Button("OK") { model.signOutFailure = nil }
        } message: {
            Text(model.signOutFailure ?? "")
        }
    }

    /// Sign-out cannot happen mid-run: the engine would lose its planner.
    private var signOutTitle: String {
        guard let kind = signingOut else { return "" }
        return String(localized: "Sign out of \(kind.name)?")
    }

    private var signOutMessage: String {
        guard let kind = signingOut else { return "" }
        return String(localized: "\(kind.name) forgets the account it is signed in with. The next plan needs a browser sign-in again. Nothing else on your Mac changes.")
    }

    private var reclaimable: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reclaimable")
                    .font(.headline)
                Text(model.cleanup.isEmpty ? "Nothing large to clean up"
                     : "\(Fmt.size(totalBytes)) in \(String(model.cleanup.count)) folders")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            List(model.cleanup) { item in
                HStack(alignment: .top, spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { picked.contains(item.path) },
                        set: { on in if on { picked.insert(item.path) } else { picked.remove(item.path) } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.display)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Text(item.kind)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(Fmt.size(item.bytes))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .help(item.display)
                .onTapGesture { model.reveal(item.node) }
                .contextMenu {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                    }
                }
            }
            .listStyle(.inset)
            .disabled(model.cleanupTrash.running)

            Divider()
            VStack(spacing: 8) {
                agentButton
                    .disabled(model.cleanupTrash.running)
                Button {
                    confirming = true
                } label: {
                    // Count and bytes both come from the resolved rows, so the
                    // number shown is exactly the number that moves.
                    Text(pickedItems.isEmpty ? "Select folders to clean up"
                         : "Move \(String(pickedItems.count)) to Trash · \(Fmt.size(pickedBytes))")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(pickedItems.isEmpty || model.scanning || model.cleanupTrash.running)
            }
            .padding(12)
        }
    }

    /// What the primary button runs, and the menu that reaches everything else.
    ///
    /// This used to be an `if / else if` chain whose menu was itself gated on
    /// `ready.count > 1 || !providers.isEmpty`. On this app's most common state
    /// — one agent signed in, no custom provider — that rendered one bare
    /// button with no menu at all, so a signed-in agent could not be swapped or
    /// removed. Both halves are now unconditional: exactly one primary action
    /// for the planner in effect, and always a menu built from the one catalog,
    /// whatever is installed.
    @ViewBuilder private var agentButton: some View {
        if let setup = model.agentSetup {
            SetupProgress(setup: setup) {
                setup.cancel()
                model.agentSetup = nil
            } retry: {
                model.setUp(setup.kind)
            }
        } else {
            // The onboarding line the first-run panel carried. With nothing
            // runnable the user has just arrived and does not yet know what the
            // button will do, so the explanation sits beside it — derived from
            // the *same* resolved choice the button uses.
            if let choice = model.preferredChoice, !choice.runnable {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Let AI clean up for you", systemImage: "sparkles")
                        .font(.headline)
                    Text(onboardingLine(choice))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                primaryAction
                plannerMenu
            }
            .disabled(model.tree == nil || model.scanning || model.cleanupTrash.running)
        }
    }

    /// The one-click path for the planner the user picked. Copy and behaviour
    /// stay exactly as before for each kind; only the choice of *which* kind is
    /// now owned by the catalog rather than this view.
    @ViewBuilder private var primaryAction: some View {
        switch model.preferredChoice {
        case .agent(let agent):
            Button {
                model.startAgent(agent)
            } label: {
                Label(String(localized: "Clean up with \(agent.kind.name)"), systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help(String(localized: "\(agent.kind.name) reads this scan and suggests what can go. Nothing is removed until you say so."))
        case .provider(let provider):
            // A custom endpoint needs no install or sign-in: it is ready once
            // its model and key are set in Settings.
            Button {
                model.startProvider(provider)
            } label: {
                Label(String(localized: "Clean up with \(provider.displayName)"), systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help(String(localized: "\(provider.displayName) reads this scan and suggests what can go. Nothing is removed until you say so."))
        case .agentSignedOut(let kind):
            Button {
                model.setUp(kind)
            } label: {
                Label(String(localized: "Sign in to \(kind.name)"), systemImage: "person.crop.circle.badge.checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help(String(localized: "\(kind.name) is installed but signed out. Signing in lets it plan what can go."))
        case .agentMissing(let kind):
            Button {
                model.setUp(kind)
            } label: {
                Label(String(localized: "Set up \(kind.name)"), systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help(kind == .codex ? String(localized: "Free with a ChatGPT account.")
                                 : String(localized: "Needs a Claude Pro plan."))
        case .none:
            // Nothing resolves at all (the catalog is still loading). The menu
            // beside it is built from `AgentKind.allCases`, so it stays usable.
            //
            // A Button, not a `SettingsLink`: SettingsLink only opens Settings,
            // leaving the user on whichever pane was showing with no way to
            // reach the form. This opens Model Providers with the add-provider
            // sheet already up.
            Button {
                model.addModelProvider { openSettings() }
            } label: {
                Label(String(localized: "Add a model provider"), systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help(String(localized: "Or use any model — a self-hosted server, a relay, a gateway."))
        }
    }

    /// Every planner, always reachable. This is the control whose absence the
    /// user hit: with one agent signed in there was no menu to swap it, and no
    /// way at all to sign it out.
    private var plannerMenu: some View {
        Menu {
            runSection
            if !model.agentEnv.ready.isEmpty {
                Divider()
                accountSection
            }
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.bordered)
        // `.extraLarge` to match the primary button's 28.5pt, not because the
        // chevron is large: `.bordered` and `.borderedProminent` are different
        // size tiers, so the same `.controlSize` yields 20.5pt beside 28.5pt.
        // A frame cannot fix it either — the bordered capsule keeps its own
        // intrinsic height, so `frame(height:)` only pads around it.
        .controlSize(.extraLarge)
        .fixedSize()
        .help(String(localized: "Choose the planner"))
        .accessibilityLabel(String(localized: "Choose the planner"))
    }

    /// The planners to run: everything that can start now, then what needs one
    /// setup step, then the way to add a provider. Between them these always
    /// list both agents, so the menu is never empty.
    @ViewBuilder private var runSection: some View {
        let choices = model.plannerChoices
        ForEach(choices.filter(\.runnable)) { choice in
            Button(choice.label) { activate(choice) }
        }
        let needsWork = choices.filter { !$0.runnable && $0.kind != nil }
        if !needsWork.isEmpty {
            Divider()
            ForEach(needsWork) { choice in
                Button(choice.menuLabel) { activate(choice) }
            }
        }
        // A real menu row rather than a `SettingsLink`, which rendered as plain
        // text here and could only open Settings, not the add-provider form.
        Divider()
        Button(String(localized: "Add a model provider…")) { model.addModelProvider { openSettings() } }
    }

    /// Signing out is the recovery path for a wrong or stale account, and the
    /// litigated half of the report: the app could install and sign in but had
    /// no way back out at all.
    @ViewBuilder private var accountSection: some View {
        ForEach(model.agentEnv.ready) { agent in
            Button(String(localized: "Sign out of \(agent.kind.name)"), role: .destructive) {
                signingOut = agent.kind
            }
        }
    }

    private func activate(_ choice: PlannerChoice) {
        switch choice {
        case .agent(let agent): model.startAgent(agent)
        case .provider(let provider): model.startProvider(provider)
        // From the menu the user asked to fix an account, not to spend a run.
        case .agentSignedOut(let kind): model.setUp(kind, startWhenReady: false)
        case .agentMissing(let kind): model.setUp(kind, startWhenReady: false)
        }
    }

    /// Why the primary button is not a run right now: nothing is signed in, or
    /// nothing is installed at all.
    ///
    /// Derived from the same resolved choice the button uses — not from "the
    /// first installed agent" — because those can differ: with a stored plan
    /// naming Claude Code while only Codex is installed, the old copy read
    /// "Sign in to Codex" beside a "Set up Claude Code" button.
    private func onboardingLine(_ choice: PlannerChoice) -> String {
        switch choice {
        case .agentSignedOut(let kind):
            return String(localized: "Sign in to \(kind.name) and it plans what can go from this scan.")
        case .agentMissing(let kind):
            return String(localized: "\(kind.name) reads this scan and plans what can go. \(accountLine(kind))")
        default:
            return String(localized: "Pick a planner and it plans what can go from this scan.")
        }
    }

    /// What an agent's account costs, so the offer is not a surprise.
    private func accountLine(_ kind: AgentKind) -> String {
        kind == .codex ? String(localized: "Free with a ChatGPT account.")
                       : String(localized: "Needs a Claude Pro plan.")
    }

    private func trashPicked() {
        // Capture what the user is actually acting on before the batch runs;
        // `pickedItems` is re-derived from the current scan on every read.
        let acting = pickedItems
        model.cleanupTrash.start(acting) { _ in
            // Drop only the ticks that were just handled. Clearing everything
            // would also discard a tick the user added while the batch ran.
            picked.subtract(acting.map(\.path))
            // The batch clears its busy state before this final rescan.
            model.startScan()
        }
    }

}

// MARK: - Agent run

/// The agent's work, live: its steps while it looks, the plan as it is
/// written, then AppleTree's own cleanup and the space it gave back.
private struct AgentRunView: View {
    let run: AgentRun
    let model: ScanModel
    let retry: () -> Void
    let close: () -> Void

    /// The locale SwiftUI resolved for this view, used to uppercase the
    /// localized section headings correctly (see `section`).
    @Environment(\.locale) private var locale

    /// The two sections, classified once from the single vocabulary type
    /// rather than two opposite string tests, so a card cannot be rendered in
    /// one section while its tick was decided by the other. The predicates are
    /// exhaustive over `PlanGroup`, which makes the old third state — a value
    /// that matched neither test — unrepresentable.
    private var safe: [PlanItem] { run.items.filter { $0.spec.group == .safe } }
    private var ask: [PlanItem] { run.items.filter { $0.spec.group == .ask } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if [.staged, .deleting, .done].contains(run.phase), hero > 0 {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(Fmt.size(hero))
                                .font(.system(size: 40, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text(heroLine)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 6)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                        .animation(.snappy, value: hero)
                    }
                    if run.phase == .thinking || !run.items.isEmpty {
                        steps
                    }
                    if !safe.isEmpty { section(String(localized: "Safe to remove"), safe) }
                    if !ask.isEmpty { section(String(localized: "Your call"), ask) }
                    if run.phase == .thinking {
                        SkeletonCard()
                        if run.items.isEmpty { SkeletonCard().opacity(0.6) }
                    }
                    if case .failed(let message) = run.phase {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .animation(.snappy, value: run.items.count)
            }
            .scrollIndicators(.never)
            Divider()
            footer
                .padding(14)
        }
        // QA and demos only: BZ_AUTOFREE=<seconds> approves the plan after a
        // pause, and BZ_DEMO_DRYRUN makes it touch nothing.
        //
        // The pairing is required, not incidental: this hook fires
        // `deleteForGood`, whose real path calls removefile(REMOVEFILE_RECURSIVE)
        // — irreversible, not the Trash — with no user click and no way to
        // cancel. Gating it on the dry run keeps the demo convenience while
        // making an accidental real deletion from an environment variable
        // unrepresentable.
        .onChange(of: run.phase) {
            guard run.isDryRun,
                  run.phase == .planned || run.phase == .staged,
                  let delay = ProcessInfo.processInfo.environment["BZ_AUTOFREE"].flatMap(Double.init) else { return }
            Task {
                try? await Task.sleep(for: .seconds(delay))
                // The run may have been cancelled or replaced during the pause;
                // acting on a stale phase would move a run nobody is watching.
                guard !Task.isCancelled, model.agentRun === run else { return }
                if run.phase == .planned { run.moveToTrash() } else { run.deleteForGood(env: model.agentEnv) }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: busy)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .contentTransition(.opacity)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 4)
            if run.phase == .thinking { Clock(run: run) }
        }
        .animation(.snappy, value: run.phase)
    }

    private var busy: Bool { [.thinking, .trashing, .deleting].contains(run.phase) }

    /// The big number: what waits to be deleted, then what was freed.
    private var hero: UInt64 { run.phase == .done ? (run.reclaimed ?? run.freed) : run.pendingBytes }

    private var title: String {
        switch run.phase {
        case .thinking: String(localized: "\(run.displayName) is looking")
        case .planned: run.items.isEmpty ? String(localized: "Nothing worth removing") : String(localized: "Here's the plan")
        case .trashing: String(localized: "Moving to the Trash")
        case .staged: String(localized: "In the Trash")
        case .deleting: String(localized: "Deleting")
        case .done: String(localized: "All clean")
        case .failed: String(localized: "\(run.displayName) couldn't finish")
        }
    }

    private var subtitle: String {
        switch run.phase {
        case .thinking: run.items.isEmpty ? String(localized: "Reading your scan, nothing is touched") : String(localized: "Writing the plan")
        case .planned: run.summary
        case .trashing: String(localized: "Nothing is deleted yet")
        case .staged: stagedLine
        case .deleting: String(localized: "Only what this cleanup moved; the rest of your Trash stays")
        case .done: finishedLine
        case .failed: String(localized: "Nothing was changed.")
        }
    }

    private var heroLine: String {
        guard run.phase == .done else { return String(localized: "ready to delete") }
        // Less can come back than the cards said: clones share blocks, and a
        // tool's own cleanup may leave part of its folder.
        if let back = run.reclaimed, run.freed > back + back / 10 {
            return String(localized: "back on your disk · the cards estimated \(Fmt.size(run.freed))")
        }
        return String(localized: "back on your disk")
    }

    private var stagedLine: String {
        let waiting = run.targets.contains { $0.isCommand && $0.status == .waiting }
        return waiting ? String(localized: "Put anything back from the Trash, or delete it permanently. Tool caches are cleared then too.")
            : String(localized: "Put anything back from the Trash, or delete it permanently.")
    }

    private var finishedLine: String {
        let failed = run.items.filter { if case .failed = $0.status { true } else { false } }.count
        if failed > 0 { return failed == 1 ? String(localized: "One item couldn't be cleaned.") : String(localized: "\(String(failed)) items couldn't be cleaned.") }
        // A dry run synthesizes `freed` but skips the rescan, so claiming the
        // map is up to date would be false — the folders are all still there.
        if run.isDryRun { return String(localized: "Nothing needed doing.") }
        return run.freed > 0 ? String(localized: "Rescanned. The map is up to date.") : String(localized: "Nothing needed doing.")
    }

    // MARK: Steps

    /// The last few things the agent did; the newest is live.
    private var steps: some View {
        VStack(alignment: .leading, spacing: 5) {
            let shown = Array(run.steps.suffix(run.phase == .thinking ? 4 : 1).enumerated())
            ForEach(shown, id: \.element) { index, step in
                let live = run.phase == .thinking && index == shown.count - 1
                HStack(spacing: 7) {
                    Group {
                        if live {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 14)
                    Text(run.phase == .thinking ? step : String(localized: "Planned in \(String(Int((run.planSeconds ?? 0).rounded()))) s"))
                        .font(.callout)
                        .foregroundStyle(live ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .modifier(Shimmer(active: live))
                }
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
        }
        .padding(.bottom, 4)
    }

    private func section(_ name: String, _ items: [PlanItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Locale-aware: `String.uppercased()` maps i→I and ı→I regardless
            // of language, so Turkish "Güvenle kaldırılabilir" rendered as
            // "KALDIRILABILIR" instead of "KALDIRILABİLİR". Uppercasing a
            // string that was just localized needs that same locale.
            Text(name.uppercased(with: locale))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
            ForEach(items) { item in
                PlanCard(item: item, editable: run.phase == .planned, current: run.current == item.id) {
                    guard let tree = model.tree, let path = item.paths.first,
                          let node = tree.node(at: path) else { return }
                    model.reveal(node)
                }
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        switch run.phase {
        case .thinking:
            Button("Stop", action: close)
                .frame(maxWidth: .infinity)
        case .planned:
            VStack(spacing: 8) {
                Button {
                    run.moveToTrash()
                } label: {
                    Text(run.selectedBytes == 0 ? "Pick what to remove"
                         : run.trashBytes > 0 ? "Move \(Fmt.size(run.trashBytes)) to Trash" : "Continue")
                        .frame(maxWidth: .infinity)
                        .contentTransition(.numericText())
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(run.selectedBytes == 0)
                .animation(.snappy, value: run.selectedBytes)
                Button("Cancel", action: close)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        case .trashing, .deleting:
            let chosen = run.targets
            let done = chosen.filter {
                run.phase == .trashing ? ($0.status != .waiting && $0.status != .running) || $0.isCommand
                    : $0.status == .done || { if case .failed = $0.status { true } else { false } }($0)
            }.count
            ProgressView(value: Double(done), total: Double(max(1, chosen.count)))
                .animation(.snappy, value: done)
        case .staged:
            VStack(spacing: 8) {
                Button {
                    run.deleteForGood(env: model.agentEnv)
                } label: {
                    Text("Delete \(Fmt.size(run.pendingBytes)) permanently")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(run.pendingBytes == 0)
                .help("Deletes only what this cleanup moved to the Trash, and clears the tool caches")
                Button("Keep in the Trash", action: close)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        case .done:
            Button("Done", action: close)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        case .failed:
            HStack {
                Button("Close", action: close)
                Spacer()
                Button("Try again", action: retry)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Seconds since the run began, ticking so the panel never looks frozen.
private struct Clock: View {
    let run: AgentRun

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            Text(String(format: "%.1f s", context.date.timeIntervalSince(run.startedAt)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }
}

private struct PlanCard: View {
    @Bindable var item: PlanItem
    let editable: Bool
    let current: Bool
    let reveal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            status
                .frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.spec.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Fmt.size(item.bytes))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(item.spec.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = item.note, item.blocked == nil {
                    Label(note, systemImage: "hammer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let blocked = item.blocked {
                    Label(blocked, systemImage: "hand.raised.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if case .failed(let message) = item.status {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: item.isCommand ? "terminal" : "trash")
                        Text(item.isCommand ? item.spec.command : where_)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(
            // White at low opacity is the app's convention for raising a
            // surface on the dark panel — not an unstyled leftover.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(current ? 0.10 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(current ? 0.8 : 0), lineWidth: 1)
        )
        // Dim what AppleTree will not touch: a blocked card always, and once
        // the plan is locked in, the cards the user left out. The previous
        // second term required `status == .waiting`, but the only exit from
        // `.planned` that keeps cards on screen rewrites every unselected item
        // to `.skipped` on the same turn — so no render ever observed that
        // state and unselected cards stayed as prominent as the chosen ones.
        .opacity(item.blocked != nil || (!editable && !item.selected) ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            if editable, item.blocked == nil { item.selected.toggle() }
            reveal()
        }
        .help(item.paths.joined(separator: "\n"))
        .contextMenu {
            ForEach(item.paths, id: \.self) { path in
                Button("Reveal \((path as NSString).lastPathComponent) in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
        }
        .animation(.snappy, value: item.status)
    }

    /// Where the folders are, shortest form.
    private var where_: String {
        let home = NSHomeDirectory()
        let shown = item.paths.map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 }
        guard let first = shown.first else { return "" }
        return shown.count == 1 ? first : "\(first) +\(shown.count - 1)"
    }

    @ViewBuilder private var status: some View {
        switch item.status {
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .inTrash:
            Image(systemName: "trash.circle.fill")
                .foregroundStyle(.blue)
                .transition(.scale.combined(with: .opacity))
        case .skipped, .waiting:
            if item.status == .skipped {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.tertiary)
            } else {
                Toggle("", isOn: $item.selected)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(!editable || item.blocked != nil)
            }
        }
    }
}

/// A card-shaped placeholder that breathes while the plan is written.
private struct SkeletonCard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.05))
            .frame(height: 64)
            .phaseAnimator([0.4, 1.0]) { view, phase in
                view.opacity(phase)
            } animation: { _ in .easeInOut(duration: 0.9) }
    }
}

/// A soft light sweeping across live text.
private struct Shimmer: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.overlay {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    LinearGradient(
                        stops: [.init(color: .clear, location: t - 0.25),
                                .init(color: .white.opacity(0.55), location: t),
                                .init(color: .clear, location: t + 0.25)],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .mask(content)
                }
            }
        } else {
            content
        }
    }
}

/// Installing or signing in, in a line the user can glance at.
private struct SetupProgress: View {
    let setup: AgentSetup
    let cancel: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch setup.step {
            case .installing, .signingIn:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(setup.step == .installing ? "Installing \(setup.kind.name)" : "Sign in to \(setup.kind.name)")
                            .font(.headline)
                            .modifier(Shimmer(active: true))
                        Text(setup.step == .installing ? "About 15 seconds, no password needed"
                             : "Finish in the browser window that just opened")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("Cancel", action: cancel)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                HStack {
                    Button("Cancel", action: cancel)
                    Spacer()
                    Button("Try again", action: retry)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .animation(.snappy, value: setup.step)
    }
}
