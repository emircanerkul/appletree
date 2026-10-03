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

        // Cmd+, — language and custom model providers.
        Settings {
            TabView {
                GeneralSettingsView()
                    .tabItem { Label(String(localized: "General"), systemImage: "gear") }
                ProvidersView()
                    .tabItem { Label(String(localized: "Model Providers"), systemImage: "point.3.filled.connected.trianglepath.dotted") }
            }
            .frame(minHeight: 360)
        }
    }
}
