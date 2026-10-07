// SettingsRouter regression net.
//
// Build (from repo root):
//   swiftc tests/swift/router-handoff.swift app/SettingsRouter.swift \
//       -parse-as-library -swift-version 6 -default-isolation MainActor \
//       -target arm64-apple-macos14.0 -framework SwiftUI \
//       -o .build/router-tests
//
// Why this exists: Settings is a Scene, so a click in the main window cannot
// reach it directly. Two things cross that boundary and both are easy to get
// wrong:
//
// 1. WHICH pane to show. Opening Settings is not enough — the user lands on
//    whichever tab was last visible, with no way to reach the form they asked
//    for. (That was the reported bug: "Add a model provider" opened Settings,
//    not the provider form.)
// 2. The click can arrive BEFORE Settings exists. The request is recorded first
//    and the window appears as a side effect, so a plain boolean flag set and
//    consumed at the wrong moment is dropped — precisely the first click.

import Foundation

var failed = 0
var passed = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        passed += 1
        print("PASS \(name)")
    } else {
        failed += 1
        print("FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }
}

@main
enum RouterHandoffTests {
    static func main() {
        let router = SettingsRouter.shared

        // --- Requesting the form also selects its pane ------------------------
        router.tab = .general
        router.requestAddProvider()
        check("requesting the form selects the Model Providers pane",
              router.tab == .providers, "tab is \(router.tab)")

        // --- The request is a COUNTER, so a pre-window click is not lost -------
        // This is the property a boolean flag cannot provide: the consumer
        // remembers the value it handled, so a request made before it existed
        // is still pending when it first appears.
        let afterFirst = router.addProviderRequests
        check("a request bumps the counter", afterFirst >= 1, "got \(afterFirst)")

        router.requestAddProvider()
        check("a second request bumps it again",
              router.addProviderRequests == afterFirst + 1,
              "got \(router.addProviderRequests)")

        // A consumer that has handled N and sees N+1 must act; one that has
        // handled N and sees N must not. Both directions are asserted, because
        // re-opening the sheet on every unrelated redraw would be as wrong as
        // dropping the click.
        var handled = 0
        var raised = 0
        func consume() {
            let pending = router.addProviderRequests
            if pending > handled { handled = pending; raised += 1 }
        }
        consume()
        check("the first observe raises the form", raised == 1, "raised \(raised)")
        consume()
        check("observing again without a request does nothing",
              raised == 1, "raised \(raised) — the form would reopen on every redraw")
        router.requestAddProvider()
        consume()
        check("a new request raises it again", raised == 2, "raised \(raised)")

        // --- It never silently switches away from what the user chose ---------
        router.tab = .general
        check("setting a pane directly is respected", router.tab == .general)
        router.requestAddProvider()
        check("and requesting the form moves it", router.tab == .providers)

        // --- Managing the list raises no form ---------------------------------
        // "Manage model providers" is not "Add": the user asked for the list
        // they already have, so a blank new-provider sheet must NOT appear. The
        // add counter is the observable that proves it did not.
        router.tab = .general
        let beforeManage = router.addProviderRequests
        router.requestManageProviders()
        check("managing selects the Model Providers pane",
              router.tab == .providers, "tab is \(router.tab)")
        check("managing does not raise the add-provider form",
              router.addProviderRequests == beforeManage,
              "counter moved \(beforeManage) -> \(router.addProviderRequests)")

        // --- Editing names one provider, carried with its token ---------------
        router.tab = .general
        router.requestEditProvider(id: "acme")
        check("editing selects the Model Providers pane",
              router.tab == .providers, "tab is \(router.tab)")
        let firstEdit = router.takePendingEditRequests()
        check("editing delivers exactly one request",
              firstEdit.count == 1, "got \(firstEdit.count)")
        check("editing records which provider",
              firstEdit.first?.id == "acme", "got \(firstEdit.first?.id ?? "nil")")
        check("editing's counter matches the delivered token",
              firstEdit.first?.token == 1, "got \(String(describing: firstEdit.first?.token))")
        // Consumed-once: the request must not survive its delivery, or a view
        // appearing later would replay it and open a form nobody asked for.
        check("a delivered edit request is not delivered again",
              router.takePendingEditRequests().isEmpty,
              "a replay would re-open the form on first appearance")

        // Two requests before the consumer runs must BOTH survive, and must
        // keep their own ids. The old id-slot-plus-counter form lost the first
        // and could pair the latest token with the wrong provider.
        router.requestEditProvider(id: "beta")
        router.requestEditProvider(id: "gamma")
        let both = router.takePendingEditRequests()
        check("two quick requests both survive",
              both.map(\.id) == ["beta", "gamma"], "got \(both.map(\.id))")
        check("their tokens are distinct and ordered",
              both.map(\.token) == [2, 3] || both[0].token < both[1].token,
              "got \(both.map(\.token))")
        check("taking them clears the queue", router.takePendingEditRequests().isEmpty)

        // Managing the list must not have raised an edit request either.
        check("managing raised no edit request",
              router.takePendingEditRequests().isEmpty)

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
