import SwiftUI

// SwiftUI keeps the process alive after the last window closes; macOS 27 then
// flags the app as "Running in Background" in the Dock. A utility app should
// end when its last window closes, so delegate the decision to AppKit, which
// owns termination policy.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct AppleTreeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Which Settings pane shows, and whether the add-provider form is pending.
    /// Shared, because the main window's buttons set it.
    @State private var settings = SettingsRouter.shared

    init() {
        // `AppleTree /some/path` is a scan target, not a document to open.
        // Left to AppKit, the path becomes an open-file request and SwiftUI
        // then skips creating the main window entirely.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
    }

    var body: some Scene {
        WindowGroup("AppleTree") {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .windowStyle(.automatic)
        .commands {
            // Replace AppKit's stock About panel: it can show a version, but
            // not that the app is open source or where the project lives.
            CommandGroup(replacing: .appInfo) {
                Button(String(localized: "About AppleTree")) { AboutWindow.show() }
            }
            // AppKit's Help menu normally points at a help book; with none,
            // macOS greys it out with "Help isn't available for AppleTree".
            // AppleTree has no manual to write — it is one window and a button
            // — so the menu opens the project's own README (bundled, so it needs
            // no network) and then the places a user actually needs: the bug
            // form, security, feature requests, questions, and source.
            CommandGroup(replacing: .help) {
                Button(String(localized: "AppleTree README")) { DocumentWindow.show(.readme) }
                    .helpText(String(localized: "Read the documentation bundled with the app"))
                Button(String(localized: "AppleTree License")) { DocumentWindow.show(.license) }
                    .helpText(String(localized: "Read the license bundled with the app"))
                Divider()
                ForEach(AppLinkItem.all) { item in
                    Button(item.title) { AppLinks.open(item.url) }
                        .helpText(item.detail)
                }
            }
        }

        // Cmd+, — language and custom model providers.
        Settings {
            // Bound to the router so a click on "Add a model provider" anywhere
            // in the app can select this tab. The provider form's own sheet is
            // raised by ProvidersView from the same request.
            TabView(selection: $settings.tab) {
                GeneralSettingsView()
                    .tabItem { Label(String(localized: "General"), systemImage: "gear") }
                    .tag(SettingsRouter.Tab.general)
                ProvidersView()
                    .tabItem { Label(String(localized: "Model Providers"), systemImage: "point.3.filled.connected.trianglepath.dotted") }
                    .tag(SettingsRouter.Tab.providers)
            }
            .frame(minHeight: 360)
        }
    }
}

private extension View {
    /// `.help()` takes a `LocalizedStringKey`, and the tooltip text here is
    /// already resolved, so it goes through the verbatim initializer to avoid
    /// looking the resolved sentence up in the tables a second time.
    func helpText(_ text: String) -> some View { help(Text(verbatim: text)) }
}
