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

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
