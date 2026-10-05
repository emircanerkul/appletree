import Foundation
import Observation

// Deliberately free of SwiftUI: this is the testable half of the Settings
// handoff, and a test can compile it without linking a view framework.

/// Which Settings pane is showing, and any pending "start adding a provider".
///
/// Settings is a Scene, not a view the app can reach into: nothing in the main
/// window can select its tab or raise its sheet directly. This is the one place
/// those two intents cross that boundary, so every "Add a model provider" in the
/// app lands the user in the same spot — the Model Providers pane with the form
/// already open — instead of merely opening Settings on whatever tab happened to
/// be showing.
@MainActor
@Observable
final class SettingsRouter {
    static let shared = SettingsRouter()

    enum Tab: Hashable {
        case general
        case providers
    }

    /// The pane on screen. Bound by the Settings `TabView`.
    var tab: Tab = .general

    /// Monotonic count of "start adding a provider" requests.
    ///
    /// A counter rather than a flag because the request must survive the window
    /// not existing yet: a click in the main window is recorded *before* Settings
    /// appears, and the consumer remembers the last value it handled, so a
    /// request made in that gap is still honoured on first appearance. A flag
    /// would be cleared only if someone happened to observe it at the right
    /// moment.
    private(set) var addProviderRequests = 0

    /// Ask for the Model Providers pane, with the add-provider form open.
    func requestAddProvider() {
        tab = .providers
        addProviderRequests += 1
    }
}
