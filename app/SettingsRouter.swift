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

    /// One "edit this provider" request: the id it names, together with the
    /// ordinal that ordered it.
    struct EditProviderRequest: Equatable, Sendable {
        let token: Int
        let id: String
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

    /// "Edit this provider" requests not yet delivered, oldest first.
    ///
    /// A queue of self-contained values, not an id slot plus a separate counter.
    /// The slot form had the id and the token in two properties a consumer read
    /// at different moments: two requests in flight bumped the counter and
    /// overwrote the id, so the latest token could be paired with the wrong
    /// provider — or the first request lost outright.
    ///
    /// Consumed-once (`takePendingEditRequests`) is also what stops a form
    /// opening unprompted: a fresh view cannot replay a request that was already
    /// delivered, and there is no stale token to trip over on first appearance.
    private(set) var editProviderRequests: [EditProviderRequest] = []

    /// Ordinal of the next edit request. Monotonic and never reset, so two
    /// requests can never share a token even after the queue has drained.
    private var nextEditToken = 0

    /// Ask for the Model Providers pane, with the add-provider form open.
    func requestAddProvider() {
        tab = .providers
        addProviderRequests += 1
    }

    /// Ask for the Model Providers pane, with no form raised.
    ///
    /// Deliberately not `requestAddProvider`: the user asked to *manage* the
    /// providers they already have, and raising a blank new-provider form over
    /// that list would answer a question they did not ask.
    func requestManageProviders() {
        tab = .providers
    }

    /// Ask for the Model Providers pane with provider `id`'s own form open.
    func requestEditProvider(id: String) {
        tab = .providers
        nextEditToken += 1
        editProviderRequests.append(EditProviderRequest(token: nextEditToken, id: id))
    }

    /// Take every undelivered edit request and clear them, oldest first.
    func takePendingEditRequests() -> [EditProviderRequest] {
        defer { editProviderRequests = [] }
        return editProviderRequests
    }
}
