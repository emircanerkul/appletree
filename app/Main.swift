import SwiftUI

@main
struct AppleTreeApp: App {
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
