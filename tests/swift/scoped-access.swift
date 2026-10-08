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
// What is asserted here. Almost all of it is *behaviour*: real bookmarks are
// created for real directories in this process and the type's state is read
// back. Measured while writing this file: on an unsigned, unsandboxed test
// binary `URL.bookmarkData(options: .withSecurityScope)` on a temp directory
// succeeds (~780 bytes) and the resolved URL starts access — so the round trip,
// `covers`, and `Grant.hold()` are all exercisable without an entitlement. If a
// future toolchain does make that call fail, the suite says so out loud and
// falls back to asserting the documented no-grant contract, rather than going
// quietly green on nothing.
//
// Only two kinds of assertion are structural, and each is labelled:
//   - the entitlement keys, which cannot be exercised in-process (a missing
//     entitlement is a property of the shipped bundle, not of this binary);
//   - one comment-stripped check that ContentView's gate uses the coverage test
//     rather than the bookmark-existence test, because ContentView does not
//     compile into this target. Source text is stripped of comments first, so a
//     comment can never satisfy a code-shaped assertion.

import Foundation

var failed = 0
var passed = 0
var substitutions = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        passed += 1
        print("PASS \(name)")
    } else {
        failed += 1
        print("FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }
}

/// A check that was not run as written because the process cannot exercise it.
func substitute(_ name: String, _ why: String) {
    substitutions += 1
    print("SUBSTITUTED \(name) — \(why)")
}

func note(_ message: String) { print("NOTE \(message)") }

/// The source with `//` and `/* */` comments removed.
///
/// Every source-shaped assertion below runs on this, so a comment that
/// *describes* the code can never satisfy a check about the code.
func strippingComments(_ source: String) -> String {
    var out = ""
    var i = source.startIndex
    var inLine = false, inBlock = false
    var inString = false
    while i < source.endIndex {
        let c = source[i]
        let next = source.index(after: i)
        let pair = source[i..<min(next, source.endIndex)]
        if inLine {
            if c == "\n" { inLine = false; out.append(c) }
        } else if inBlock {
            if pair.hasPrefix("*/") {
                inBlock = false
                i = source.index(i, offsetBy: 1)
            }
        } else if inString {
            out.append(c)
            if c == "\\" {
                if next < source.endIndex {
                    out.append(source[next])
                    i = next
                }
            } else if c == "\"" {
                inString = false
            }
        } else if pair.hasPrefix("//") {
            inLine = true
            i = source.index(i, offsetBy: 1)
        } else if pair.hasPrefix("/*") {
            inBlock = true
            i = source.index(i, offsetBy: 1)
        } else {
            out.append(c)
            if c == "\"" { inString = true }
        }
        i = source.index(after: i)
    }
    return out
}

/// A path as the bookmark round trip reports it, with symlinks resolved.
/// Measured: a bookmark for a temp directory under `/var/folders` resolves to
/// the `/private/var/folders` spelling, and `URL(fileURLWithPath:)` does not
/// resolve that on its own.
func canonical(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

/// One Swift function's body, from its signature to its matching closing brace.
///
/// Scoping a source-shaped assertion to the function that owns the behaviour is
/// what gives it meaning: `ScopedAccess.covers(` occurs in several places, so a
/// whole-file `contains` cannot say *where* the gate calls it — and cannot fail
/// when the gate stops calling it at all (audit SW-21).
func functionBody(startingAt signature: String, in code: String) -> String {
    guard let start = code.range(of: signature),
          let open = code.range(of: "{", range: start.upperBound..<code.endIndex) else {
        return ""
    }
    var depth = 0
    var i = open.lowerBound
    while i < code.endIndex {
        let c = code[i]
        if c == "{" {
            depth += 1
        } else if c == "}" {
            depth -= 1
            if depth == 0 { return String(code[start.lowerBound...i]) }
        }
        i = code.index(after: i)
    }
    return ""
}

@main
enum ScopedAccessTests {
    static func main() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

        // The test binary reads `ScopedAccess`, which reads UserDefaults.standard:
        // the fixture must not clobber a real user's stored bookmark, so it is
        // saved and restored around everything below.
        let defaults = UserDefaults.standard
        let savedBookmark = defaults.data(forKey: ScopedAccess.bookmarkKey)
        defer {
            if let savedBookmark {
                defaults.set(savedBookmark, forKey: ScopedAccess.bookmarkKey)
            } else {
                defaults.removeObject(forKey: ScopedAccess.bookmarkKey)
            }
            check("the user's stored bookmark was restored",
                  defaults.data(forKey: ScopedAccess.bookmarkKey) == savedBookmark)
        }

        ScopedAccess.forget()

        // --- 1. Structural: the entitlements the route depends on -------------
        //
        // Not behavioural *on purpose*. Without
        // `files.bookmarks.app-scope` the bookmark call fails outright (measured:
        // error 256, "The file couldn't be opened"), so the route is unavailable
        // rather than degraded; the key is easy to drop during an unrelated edit
        // and only a shipped bundle can really test it.
        let entsPath = root.appendingPathComponent("app/AppleTree.entitlements")
        let ents = strippingComments((try? String(contentsOf: entsPath, encoding: .utf8)) ?? "")
        check("AppleTree.entitlements was read", !ents.isEmpty, entsPath.path)
        check("the app-scope bookmark entitlement is requested",
              ents.contains("<key>com.apple.security.files.bookmarks.app-scope</key>"),
              "without it bookmark creation fails outright (measured: error 256)")
        check("the picker entitlement is requested",
              ents.contains("<key>com.apple.security.files.user-selected.read-write</key>"),
              "the panel is how the user hands over the folder")
        // The retired key must not be a live entitlement. It is still *named* in
        // the retirement comment, so the check is on the `<key>` form (and this
        // file strips comments anyway): an `<key>` line means it is granted.
        check("the home-relative temporary exception was retired",
              !ents.contains("<key>com.apple.security.temporary-exception"),
              "the bookmark route replaces it; the exception must not linger")

        // --- 2. Behaviour: the no-grant state ---------------------------------
        //
        // A fresh install. The scan path must read this as "ask the user", never
        // as "scan anyway".
        check("no stored bookmark reports no granted path", ScopedAccess.grantedPath == nil)
        check("no stored bookmark is not stale", !ScopedAccess.isStale)
        check("no stored bookmark has nothing usable", !ScopedAccess.hasUsableBookmark)
        // Coverage is the gate's question now: with nothing stored, no target is
        // covered, and the gate must ask for one.
        for target in ["/", "/System/Volumes/Data", NSHomeDirectory(), "/Applications", "/Volumes/Any"] {
            check("no grant covers \(target)", !ScopedAccess.covers(target))
        }
        let empty = ScopedAccess.Grant()
        check("hold() with no bookmark grants nothing", empty.hold() == nil)
        check("hold() with no bookmark holds nothing", !empty.isHeld)

        // --- 3. Behaviour: a bookmark that is not a bookmark -------------------
        defaults.set(Data([0x00, 0x01, 0x02, 0x03]), forKey: ScopedAccess.bookmarkKey)
        check("a corrupt bookmark reports no granted path", ScopedAccess.grantedPath == nil,
              "resolving garbage must fail safe")
        check("a corrupt bookmark covers nothing", !ScopedAccess.covers("/Applications"))
        let corrupt = ScopedAccess.Grant()
        check("hold() on a corrupt bookmark grants nothing", corrupt.hold() == nil)
        check("hold() on a corrupt bookmark holds nothing", !corrupt.isHeld)

        // `forget()` must actually clear the key: this is what "the stored
        // folder is gone" means to every other owner.
        ScopedAccess.forget()
        check("forget() clears the stored bookmark",
              defaults.data(forKey: ScopedAccess.bookmarkKey) == nil)

        // --- 4. Behaviour: a real bookmark for a real directory -----------------
        //
        // Two throwaway directories the process owns, so the round trip is the
        // real one: create, store, resolve, cover, hold.
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bz-scoped-access-\(UUID().uuidString)")
        let picked = base.appendingPathComponent("picked")
        let pickedSecond = base.appendingPathComponent("picked-second")
        try? fm.createDirectory(at: picked, withIntermediateDirectories: true)
        try? fm.createDirectory(at: pickedSecond, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        // Does the toolchain let an unsigned binary create an app-scoped
        // bookmark on a directory it owns? Measured yes (see the header).
        var canBookmark = false
        do {
            _ = try picked.bookmarkData(options: [.withSecurityScope],
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
            canBookmark = true
        } catch {
            canBookmark = false
            note("this toolchain refuses .withSecurityScope bookmarks in an unsigned process: \((error as NSError).code)")
        }

        if !canBookmark {
            substitute("the bookmark round-trip, coverage and hold() tests",
                       "the process cannot create an app-scoped bookmark, so the documented no-grant contract is asserted instead")
            check("a bookmark that cannot be created is not reported",
                  ScopedAccess.remember(picked) == false)
            check("a refused bookmark leaves no granted path", ScopedAccess.grantedPath == nil)
            check("a refused bookmark covers nothing", !ScopedAccess.covers(canonical(picked.path)))
            let refused = ScopedAccess.Grant()
            check("a refused bookmark grants nothing", refused.hold() == nil)
            check("a refused bookmark holds nothing", !refused.isHeld)
        } else {
            let pickedPath = canonical(picked.path)
            let secondPath = canonical(pickedSecond.path)
            check("remember() stores a bookmark for a real directory",
                  ScopedAccess.remember(picked))
            let granted = ScopedAccess.grantedPath
            check("the stored bookmark resolves to the chosen directory",
                  granted.map(canonical) == pickedPath, granted ?? "nil")
            check("the stored bookmark is not stale", !ScopedAccess.isStale)
            check("a stored bookmark is usable", ScopedAccess.hasUsableBookmark)

            // `covers`: exact, descendant, and the two negative boundaries. The
            // path-boundary rule is what keeps a sibling name from matching.
            check("covers() accepts the granted path itself",
                  ScopedAccess.covers(pickedPath))
            check("covers() accepts a descendant",
                  ScopedAccess.covers(pickedPath + "/sub/deeper"))
            check("covers() rejects an unrelated path",
                  !ScopedAccess.covers("/Applications"))
            check("covers() rejects a name-prefix sibling",
                  !ScopedAccess.covers(pickedPath + "-elsewhere"),
                  "a prefix match without the path separator is not coverage")
            check("covers() rejects the parent directory",
                  !ScopedAccess.covers(canonical(base.path)),
                  "a grant covers its subtree, not its ancestors")

            // B3's regression, asserted as state: a grant of one folder must not
            // disable the gate for Home or the disk. Measured on the old
            // existence gate: with `/Applications` bookmarked, `grantedPath` was
            // `/Applications` while `/Users/…` was DENIED — so a Home click
            // raised no panel and scanned nothing.
            check("a grant of another folder does not cover Home",
                  !ScopedAccess.covers(NSHomeDirectory()),
                  "home is not on the picked path")
            check("a grant of another folder does not cover Macintosh HD",
                  !ScopedAccess.covers("/System/Volumes/Data"))
            check("a grant of another folder does not cover /Applications",
                  !ScopedAccess.covers("/Applications"))

            // `hold()`: real extension, idempotent for an unchanged bookmark.
            let grant = ScopedAccess.Grant()
            let heldOnce = grant.hold()
            check("hold() acquires the stored directory", heldOnce.map(canonical) == pickedPath,
                  heldOnce ?? "nil")
            check("hold() reports the grant as held", grant.isHeld)
            let heldTwice = grant.hold()
            check("a repeated hold() returns the same directory and stays held",
                  heldTwice.map(canonical) == pickedPath && grant.isHeld,
                  "dropping and re-acquiring would close the window cleanup runs in")

            // B8: re-picking mid-session must move the extension to the new
            // folder. The old short-circuit returned the first path forever, so
            // the newly chosen folder was never actually reachable.
            check("remember() overwrites the stored bookmark on a re-pick",
                  ScopedAccess.remember(pickedSecond))
            check("the stored bookmark now resolves to the second pick",
                  ScopedAccess.grantedPath.map(canonical) == secondPath,
                  ScopedAccess.grantedPath ?? "nil")
            let heldAfterRepick = grant.hold()
            check("hold() follows a re-pick to the new directory",
                  heldAfterRepick.map(canonical) == secondPath,
                  "the old short-circuit returned \(heldOnce ?? "nil") instead")
            check("hold() still reports the grant as held after a re-pick", grant.isHeld)

            grant.release()
            check("release() drops the grant", !grant.isHeld)
            check("hold() re-acquires after release", grant.hold().map(canonical) == secondPath)
            grant.release()

            // Coverage is read from storage, not from the held extension:
            // forgetting must make the gate ask again.
            ScopedAccess.forget()
            check("a forgotten bookmark covers nothing", !ScopedAccess.covers(secondPath))
            let forgotten = ScopedAccess.Grant()
            check("hold() after forget() grants nothing", forgotten.hold() == nil)
            check("hold() after forget() holds nothing", !forgotten.isHeld)
        }

        // --- 5. Behaviour: a boot-volume grant covers the scanned volume --------
        //
        // The panel's "Macintosh HD" row stands for the Data volume, and the
        // disk target is that volume: one pick has to authorize the whole
        // subtree the app scans, or the B2 loop comes back.
        if canBookmark, ScopedAccess.remember(URL(fileURLWithPath: ScopedAccess.bootVolumeDataPath)) {
            let granted = ScopedAccess.grantedPath
            note("a bookmark of \(ScopedAccess.bootVolumeDataPath) resolves to \(granted ?? "nil")")
            check("the disk grant resolves to the boot volume",
                  granted == "/" || granted == ScopedAccess.bootVolumeDataPath, granted ?? "nil")
            for target in ["/", ScopedAccess.bootVolumeDataPath, NSHomeDirectory(),
                           "/Applications", "/opt", "/private/var"] {
                check("the boot-volume grant covers \(target)", ScopedAccess.covers(target))
            }
            // B4: the grant covers the boot volume, not other devices mounted in
            // its tree. `/Volumes/Foo` is reachable through that tree but its
            // bytes are not on the granted volume, so it still needs its own pick.
            for target in ["/Volumes", "/Volumes/External", "/System/Volumes/Data/Volumes/External"] {
                check("the boot-volume grant does not cover \(target)",
                      !ScopedAccess.covers(target),
                      "a mounted drive is another device's bytes")
            }
        } else {
            substitute("the boot-volume coverage tests",
                       "no app-scoped bookmark could be created in this process")
        }

        // A grant of `/` (what a plain `file:///` pick used to store) behaves the
        // same, in either spelling of the volume.
        if canBookmark, ScopedAccess.remember(URL(fileURLWithPath: "/")) {
            check("a / grant covers the disk target",
                  ScopedAccess.covers(ScanPathAlias.dataVolume))
            check("a / grant covers Home", ScopedAccess.covers(NSHomeDirectory()))
            check("a / grant does not cover a mounted drive",
                  !ScopedAccess.covers("/Volumes/External"))
        } else {
            substitute("the / grant coverage tests",
                       "no app-scoped bookmark could be created in this process")
        }
        ScopedAccess.forget()

        // --- 6. Structural: the UI gate asks the coverage question -------------
        //
        // ContentView does not compile into this target, so these are the
        // source-shaped assertions: the scan gate must call `covers`, and must no
        // longer decide on the mere existence of a bookmark (B3). Comments are
        // stripped first, so prose cannot satisfy them.
        //
        // The gate is read from `requestScan`'s OWN body, not the whole file. A
        // whole-file `contains("ScopedAccess.covers(")` passed even when the gate
        // was unreachable, because `chooseFolder` calls `covers` too — so the
        // assertion could not see the defect (SW-21). Scoping it to the function
        // that decides means a gate that stops firing fails here.
        let contentPath = root.appendingPathComponent("app/ContentView.swift")
        let content = strippingComments((try? String(contentsOf: contentPath, encoding: .utf8)) ?? "")
        check("ContentView.swift was read", !content.isEmpty, contentPath.path)
        let gate = functionBody(startingAt: "private func requestScan(", in: content)
        check("the scan gate's own body was found [structural]", !gate.isEmpty,
              "the assertions below cannot be evaluated without it")
        check("the scan gate asks whether the grant covers the target [structural]",
              gate.contains("!ScopedAccess.covers("),
              "coverage, not existence: an unrelated grant must not disable the gate")
        check("the scan gate no longer decides on a stored bookmark's existence [structural]",
              !gate.contains("ScopedAccess.hasUsableBookmark"),
              "existence is the B3 bug")
        // Coverage must be the ONLY condition that gates a scan. A second
        // predicate (`isSandboxGatedTarget`) meant only the targets the UI's own
        // list happened to name were gated, so a user-chosen folder scanned
        // uncovered and came back empty (SW-2).
        check("no second predicate narrows which targets are gated [structural]",
              !gate.contains("isSandboxGatedTarget"),
              "coverage alone decides; a target allowlist goes stale")

        print("")
        if substitutions > 0 { print("\(substitutions) substituted (see NOTE/SUBSTITUTED above)\n") }
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

/// The Data volume the whole-disk target scans, spelled here because `ScanTargets`
/// (app/Model.swift) is not compiled into this target.
enum ScanPathAlias {
    static let dataVolume = "/System/Volumes/Data"
}
