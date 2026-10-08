// The Full Disk Access grant must be reachable for the build that is running.
//
// Build (from repo root):
//   swiftc tests/swift/fda-grant.swift -parse-as-library -swift-version 6 \
//       -default-isolation MainActor -target arm64-apple-macos14.0 \
//       -o .build/fda-grant-tests
//   .build/fda-grant-tests
//
// Report: "it keep asking i already granted and restarted".
//
// TCC identifies an app by its *designated requirement* (DR), not by its name
// or its folder. Two things in this repo break that, and both are structural —
// so they are asserted from the sources rather than inferred at runtime.
//
// 1. The FDA card named a hardcoded path.
//
//    The card told the user to add `/Applications/AppleTree.app`, but
//    `make deploy-sandbox` installs a SEPARATE bundle at
//    `/Applications/AppleTree (Sandboxed).app`. Measured on this machine, the
//    two are different apps to TCC — different `CDHash`, and the rehearsal one
//    was ad-hoc signed. A user who follows the card grants a *different* binary
//    than the one asking, so the prompt can never clear. The card must name the
//    bundle that is actually running.
//
// 2. The rehearsal was signed ad-hoc, pinning its DR to a cdhash.
//
//    `codesign -d -r-` on the installed rehearsal bundle reported
//    `designated => cdhash H"dc786d7e…"`, and the Makefile's own warning (for
//    the main build) already spells out the consequence: "An ad-hoc signature
//    pins the designated requirement to a cdhash, which changes on every
//    rebuild, so macOS TCC will drop the app Full Disk Access grant each time
//    you rebuild." `deploy-sandbox` did exactly that unconditionally, even
//    though an `Apple Development` identity was available — so the grant was
//    dropped by the very act of rebuilding the thing under test.
//
// The assertions are structural on purpose: neither defect can be reproduced
// without installing both bundles and clicking through System Settings, which a
// unit test cannot do. What it CAN pin is that the sources no longer contain the
// two shapes that caused it.

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

/// The recipe of a Makefile target, from its own line to the next target.
///
/// A target line starts at column 0, ends in `:` before any `=`, and is not a
/// variable assignment. `deploy-sandbox`'s recipe is what has to sign with a
/// stable identity, so this is the scope the assertion must read — not the
/// whole file, where `build`'s (correct) identity selection would satisfy it.
///
/// **Recipe comments are stripped.** A Makefile recipe may carry `#` comments
/// (tab-indented, so they are recipe lines, not Makefile comments), and the
/// `deploy-sandbox` recipe is full of prose that names `find-identity` and
/// `--sign -`. Testing the raw recipe meant a *comment* could satisfy a
/// positive assertion and could not fail a negative one — the same defect this
/// file already fixed for Swift source. Both directions now read executable
/// recipe text only, so a `# …` line neither proves nor breaks anything.
func makeRecipe(_ target: String, in makefile: String) -> String {
    let lines = makefile.split(separator: "\n", omittingEmptySubsequences: false)
    var out: [Substring] = []
    var inside = false
    for line in lines {
        let isTarget = !line.hasPrefix("\t") && !line.hasPrefix("#")
            && line.contains(":") && !line.contains("=")
            && !line.hasPrefix(" ")
        if isTarget {
            if inside { break }
            inside = line.hasPrefix("\(target):")
            continue
        }
        if inside {
            // Drop the comment tail, keeping what a shell would actually run.
            let code = line.prefix { $0 != "#" }
            if !code.trimmingCharacters(in: .whitespaces).isEmpty { out.append(code) }
        }
    }
    return out.joined(separator: "\n")
}

/// The source with `//` and `/* */` comments removed.
///
/// A positive source-shaped assertion must run on this, or a comment that
/// merely *names* the symbol satisfies it — which is exactly how the old
/// `content.contains("!AppEnvironment.isSandboxed")` check passed while proving
/// nothing. Negative assertions stay on the raw text, where a comment is also a
/// hit: stricter, and a literal named anywhere is still worth failing.
func strippingComments(_ source: String) -> String {
    var out = ""
    var i = source.startIndex
    var inLine = false, inBlock = false, inString = false
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

/// One function's body, from its signature to its matching closing brace.
///
/// Scoping a source-shaped assertion to the function that owns the behaviour is
/// what makes it mean something: the same symbol appears elsewhere in the file,
/// so a whole-file search cannot say *where* it was used.
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
enum FDAGrantTests {
    static func main() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

        // --- 1. The card names the running bundle, never a hardcoded path ------
        let contentPath = root.appendingPathComponent("app/ContentView.swift")
        let content = (try? String(contentsOf: contentPath, encoding: .utf8)) ?? ""
        check("ContentView.swift was read", !content.isEmpty, contentPath.path)

        // The exact string that misdirected the grant. Any hardcoded
        // `/Applications/…` in the guidance re-creates the defect, whatever the
        // bundle is called next time.
        check("the FDA card does not hardcode an app path",
              !content.contains("add /Applications/"),
              "the card must not name a path that only holds for one build")
        // It must instead ask the bundle it is running from, so the rehearsal
        // and the normal install each name themselves.
        check("the FDA card names the running bundle",
              content.contains("Bundle.main.bundleURL"),
              "the user must be told the app that is actually asking")

        // The old key is stated in full because the tables are keyed by it: a
        // card whose text changed while the key did not would render English in
        // every language (exactly the drift tests/check-l10n.py exists to stop).
        check("the old hardcoded-path key is gone from the sources",
              !content.contains("Remove any old AppleTree rows, then add /Applications/AppleTree.app."),
              "the literal still ships in the card")

        // --- 2. The rehearsal signs with a stable identity ---------------------
        let makefile = (try? String(contentsOf: root.appendingPathComponent("Makefile"),
                                    encoding: .utf8)) ?? ""
        check("Makefile was read", !makefile.isEmpty)
        let recipe = makeRecipe("deploy-sandbox", in: makefile)
        check("the deploy-sandbox recipe was found", !recipe.isEmpty,
              "the assertion below cannot be evaluated without it")
        // A stable identity makes the DR certificate-based, which survives a
        // rebuild. Ad-hoc makes it a cdhash, which does not.
        check("deploy-sandbox signs with a real identity when one exists",
              recipe.contains("find-identity"),
              "an unconditional ad-hoc signature drops the FDA grant on every rebuild")
        // ...and still falls back, so the target works on a Mac with none, as
        // the existing warning for `build` already does. The signature now comes
        // from a variable, so the assertion is on the fallback assignment rather
        // than on the literal flag the codesign call happens to spell.
        check("deploy-sandbox keeps an ad-hoc fallback",
              recipe.contains("SIGN=\"-\""),
              "a machine with no identity must still be able to rehearse")
        // The failure it must NOT reproduce: an unconditional ad-hoc sign.
        check("deploy-sandbox no longer signs ad-hoc unconditionally",
              !recipe.contains("--sign -"),
              "the unconditional form is what dropped the grant on every rebuild")

        // --- 3. The sandboxed build does not ask for an FDA it cannot use ------
        //
        // The card is unsatisfiable in a sandboxed build. Measured with the SAME
        // bundle identifier and signing identity, so the same TCC grant applied
        // to both: the unsandboxed build reported `FDA.isActive() == true` and
        // could read ~/Library/Messages, while the sandboxed build reported
        // `false` and was denied. tccd logged the grant
        // (`Modify kTCCServiceSystemPolicyAllFiles` for this bundle), so the
        // denial is App Sandbox's own, not a missing consent. Offering the card
        // therefore loops forever: grant, restart, card again.
        //
        // The sandboxed build's route to the user's files is not FDA at all: it
        // is the security-scoped bookmark the folder panel creates (see
        // `ScopedAccess`), so asking for FDA would be asking for something the
        // build can never receive *and* does not need.
        //
        // `requestScan` does not compile into this target, so this is a
        // source-shaped assertion — but scoped and code-shaped: the function's
        // own body is extracted (after comments are stripped, so prose cannot
        // satisfy it), and the question is whether the sandbox refusal sits
        // *before* the card is raised. A bare `content.contains(...)` was
        // satisfied by any comment that named the symbol, which is how the old
        // assertion passed while proving nothing.
        let code = strippingComments(content)
        let requestBody = functionBody(startingAt: "private func requestScan(", in: code)
        check("requestScan's body was found in ContentView.swift", !requestBody.isEmpty,
              "the assertion below cannot be evaluated without it")
        let refusal = requestBody.range(of: "guard !AppEnvironment.isSandboxed")
        let raised = requestBody.range(of: "needsFDA = true")
        check("the FDA card is not raised in a sandboxed build",
              refusal != nil && raised != nil
                && refusal!.lowerBound < raised!.lowerBound,
              "the guard must refuse a sandboxed build before the card is raised")

        // --- 4. The home-relative exception is retired, not merely unused -----
        //
        // It used to grant the app's own cache folders so a Home scan worked with
        // no user action. It is gone: one folder the user picks grants the home
        // *and* the rest of the disk, and it never covered what the product needs
        // anyway (measured: with it, `/System/Volumes/Data/Users`,
        // `/System/Volumes/Data/private/var` and `/opt` were still DENIED, so a
        // whole-disk scan was blind to most of the volume).
        //
        // Half-done refactors are the trap here: leaving the key in place while
        // the code stops relying on it keeps the review surface without keeping
        // any benefit. The assertion is on the `<key>` form, because the
        // retirement comment names it deliberately.
        let entPath = root.appendingPathComponent("app/AppleTree.entitlements")
        let ents = (try? String(contentsOf: entPath, encoding: .utf8)) ?? ""
        check("AppleTree.entitlements was read", !ents.isEmpty, entPath.path)
        check("the home-relative temporary exception is retired",
              !ents.contains("<key>com.apple.security.temporary-exception"),
              "the bookmark route replaces it; the key must not be granted")
        // The three keys the surviving design needs.
        for needed in ["com.apple.security.app-sandbox",
                       "com.apple.security.files.user-selected.read-write",
                       "com.apple.security.files.bookmarks.app-scope"] {
            check("the surviving entitlement is present: \(needed)",
                  ents.contains("<key>\(needed)</key>"),
                  "the bookmark route cannot work without it")
        }

        print("")
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
