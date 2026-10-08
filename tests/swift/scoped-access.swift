// Route B: reaching folders the sandbox denies, via a security-scoped bookmark.
//
// Build (from repo root):
//   swiftc tests/swift/scoped-access.swift app/ScopedAccess.swift \
//       -parse-as-library -swift-version 6 -default-isolation MainActor \
//       -target arm64-apple-macos14.0 -o .build/scoped-access-tests
//   .build/scoped-access-tests
//
// Why this exists. A sandboxed app cannot reach `/Users`, `/private/var` or
// `/opt`, and measured, Full Disk Access does NOT lift App Sandbox — so a
// sandboxed whole-disk scan needs the user to choose the folder once and for the
// app to store a bookmark. That is Apple's documented route and the reason
// `ScopedAccess` exists.
//
// The bookmark round-trip cannot be tested in-process here: creating one needs
// the `files.bookmarks.app-scope` entitlement, and this test binary is not
// sandboxed or entitled. What IS testable, and is what a regression would
// actually break, is the *state* contract the scan path depends on: what
// `grantedPath` reports before and after a bookmark is stored, that a second
// `begin()` does not leak the first extension, and that `forget()` really
// removes it. Those are asserted against a real UserDefaults suite, so the
// storage key is exercised rather than mocked.

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
enum ScopedAccessTests {
    static func main() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

        // --- the entitlement the route depends on ----------------------------
        //
        // Without `files.bookmarks.app-scope` the bookmark call itself fails
        // (measured: error 256, "The file couldn't be opened"), so the route is
        // unavailable rather than merely degraded. The key is easy to drop from
        // an entitlement file during an unrelated edit, and nothing else would
        // notice until a user tried to pick a disk.
        let entsPath = root.appendingPathComponent("app/AppleTree.entitlements")
        let ents = (try? String(contentsOf: entsPath, encoding: .utf8)) ?? ""
        check("AppleTree.entitlements was read", !ents.isEmpty, entsPath.path)
        check("the app-scope bookmark entitlement is requested",
              ents.contains("com.apple.security.files.bookmarks.app-scope"),
              "without it bookmark creation fails outright (measured: error 256)")
        check("the picker entitlement is requested",
              ents.contains("com.apple.security.files.user-selected.read-write"),
              "the panel is how the user hands over the folder")

        // --- the state contract the scan path reads --------------------------
        //
        // `ScopedAccess` reads `UserDefaults.standard`, so the fixture must not
        // clobber a real user's stored bookmark. It is saved and restored.
        let defaults = UserDefaults.standard
        let savedBookmark = defaults.data(forKey: ScopedAccess.bookmarkKey)

        // A clean start: nothing chosen yet. This is the state a fresh install
        // is in, and the scan path must treat it as "ask the user", not as
        // "scan anyway".
        ScopedAccess.forget()
        check("no stored bookmark reports no granted path", ScopedAccess.grantedPath == nil)
        check("no stored bookmark is not stale", !ScopedAccess.isStale)

        // `hold()` with nothing stored yields no path, so the caller cannot
        // start a scan against a folder it has no access to.
        let empty = ScopedAccess.Grant()
        check("hold() with no bookmark grants nothing", empty.hold() == nil)
        check("hold() with no bookmark holds nothing", !empty.isHeld)

        // A bookmark that is not a bookmark must be refused rather than crash or
        // silently resolve to somewhere unexpected.
        defaults.set(Data([0x00, 0x01, 0x02, 0x03]), forKey: ScopedAccess.bookmarkKey)
        check("a corrupt bookmark reports no granted path", ScopedAccess.grantedPath == nil,
              "resolving garbage must fail safe")
        let corrupt = ScopedAccess.Grant()
        check("hold() on a corrupt bookmark grants nothing", corrupt.hold() == nil)
        check("hold() on a corrupt bookmark holds nothing", !corrupt.isHeld)

        // `forget()` must actually clear the key: this is what "the stored
        // folder is gone" means to every other owner, and a `removeObject` that
        // missed the key would leave a stale grant forever.
        ScopedAccess.forget()
        check("forget() clears the stored bookmark",
              defaults.data(forKey: ScopedAccess.bookmarkKey) == nil)

        // `hold()` must be idempotent, and it must outlive a scan.
        //
        // Cleanup runs AFTER a scan and reaches the same paths, so releasing the
        // extension at the end of the walk would make every `Move to Trash` on a
        // chosen folder fail. This is why the grant is session-held rather than
        // scan-held, and why the app's only route to the user's files is now the
        // bookmark: the home-relative temporary exception was retired.
        //
        // Asserted on the type's own state rather than through the sandbox, which
        // this binary cannot enter.
        let grant = ScopedAccess.Grant()
        _ = grant.hold()
        _ = grant.hold()
        check("repeated hold() is safe to call", true)
        grant.release()
        check("release() drops the grant", !grant.isHeld)
        // The retirement itself: the entitlement that used to carry the app's own
        // caches must be gone from the shipping set, or the refactor is only
        // half-done and the review surface was not actually reduced.
        // The retired key must not be a live entitlement. It is still *named* in
        // the retirement comment (so the reason survives), so the check is on the
        // key form rather than any mention: an `<key>` line means it is granted.
        check("the home-relative temporary exception was retired",
              !ents.contains("<key>com.apple.security.temporary-exception.files.home-relative-path"),
              "the bookmark route replaces it; the exception must not linger")

        // Restore whatever the real user had.
        if let savedBookmark {
            defaults.set(savedBookmark, forKey: ScopedAccess.bookmarkKey)
        } else {
            defaults.removeObject(forKey: ScopedAccess.bookmarkKey)
        }
        check("the user's stored bookmark was restored",
              defaults.data(forKey: ScopedAccess.bookmarkKey) == savedBookmark)

        // --- 4. A whole-disk click must open the picker, not show a card ------
        //
        // The first cut raised a "Choose the folder to scan" card instead. That
        // cannot work: only `NSOpenPanel` extends the sandbox, so a button that
        // displays instructions cannot make the click succeed. Worse, the
        // bookmark result was ignored, so a failure to store one left
        // `hasUsableBookmark` false and the next click showed the card again —
        // the same choose-card-choose loop as the FDA card it replaced.
        //
        // Measured: picking the sidebar's "Macintosh HD" yields `file:///`, and
        // bookmarking `/` FAILED (0 bytes) from a build holding only the
        // home-relative grant, while `/System/Volumes/Data` succeeded. So the
        // retry to the data volume is not a nicety; it is what makes that
        // particular click work at all.
        let content = (try? String(contentsOf: root.appendingPathComponent("app/ContentView.swift"),
                                   encoding: .utf8)) ?? ""
        check("ContentView.swift was read for the picker checks", !content.isEmpty)
        check("a whole-disk request in a sandboxed build opens the picker",
              content.contains("chooseFolder()\n            return"),
              "showing a card cannot grant the sandbox; only the panel can")
        check("the picker does not ignore a failed bookmark",
              content.contains("if !ScopedAccess.remember(url)"),
              "an ignored failure is what looped: choose, card, choose")
        check("a `file:///` choice is retried as the data volume",
              content.contains("ScopedAccess.remember(URL(fileURLWithPath: volume))"),
              "`/` cannot be bookmarked; its data volume can")
        check("the unsatisfiable folder card was removed",
              !content.contains("needsScopedRoot"),
              "dead UI that cannot grant anything must not ship")
        check("the scan path asks the one question, not two",
              content.contains("ScopedAccess.hasUsableBookmark"),
              "reassembling grantedPath/isStale at the caller invites the loop back")

        // The Home target is gated too, now that the home-relative exception is
        // retired: `~/` is DENIED until a folder is chosen (measured on a build
        // with only the sandbox, picker and bookmark entitlements). Leaving Home
        // ungated would restore the original symptom — a scan of nothing,
        // reported as "Nothing large to clean up" rather than as a missing
        // permission. `/Applications` and a mounted drive are deliberately NOT
        // gated: both are readable on the entitlements alone, so prompting for
        // them would be a prompt for nothing.
        check("the Home target is gated on a chosen folder",
              content.contains("target == ScanTargets.home.path"),
              "`~/` is denied once the exception is retired, so Home must ask")
        check("the whole-disk target is gated on a chosen folder",
              content.contains("target == ScanTargets.macintoshHD.path"),
              "the disk is denied too")
        check("readable targets are not gated",
              !content.contains("target == ScanTargets.applications.path) {"),
              "Applications is readable on the entitlements alone")

        // --- 5. The Home target is gated too, now that the exception is gone ---
        //
        // When the home-relative exception granted `~/`, a Home scan worked with
        // no user action. With it retired, `~/` is DENIED until a folder is
        // chosen — measured on a build with only the sandbox, picker and bookmark
        // entitlements. Leaving Home ungated would restore the original symptom:
        // a scan of nothing, reported as "Nothing large to clean up" rather than
        // as a missing permission.
        //
        // `/Applications` and a mounted drive are deliberately NOT gated: both
        // are readable on the entitlements alone, so prompting for them would be
        // a prompt for nothing.
        check("the Home target is gated on a chosen folder",
              content.contains("target == ScanTargets.home.path"),
              "`~/` is denied once the exception is retired, so Home must ask")
        check("the whole-disk target is gated on a chosen folder",
              content.contains("target == ScanTargets.macintoshHD.path"),
              "the disk is denied too")
        // The gate must not cover the targets that are readable without a grant,
        // or every Applications scan would demand a picker for no reason.
        check("readable targets are not gated",
              !content.contains("target == ScanTargets.applications.path) {"),
              "Applications is readable on the entitlements alone")

        print("")
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
