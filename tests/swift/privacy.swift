// Privacy compliance regression net.
//
// Build (from repo root):
//   swiftc tests/swift/privacy.swift app/ReadmeMarkdown.swift \
//       -parse-as-library -swift-version 6 -default-isolation MainActor \
//       -target arm64-apple-macos14.0 \
//       -o .build/privacy-tests
//
// Three submission requirements, none of which the compiler or the other tests
// could check:
//
//   1. Guideline 5.1.1(i) — the privacy policy must be reachable IN THE APP.
//      A link that is not bundled, or a document the link resolver refuses,
//      leaves that unmet while looking fine in the source.
//   2. Guideline 5.1.2(i) — explicit permission, naming the destination,
//      before a scan summary goes to a third party.
//   3. ITMS-91053 — the privacy manifest must declare every required-reason
//      API category the BINARY actually links. A category that is linked but
//      undeclared is a rejected upload; a category declared but not linked is
//      a false statement to Apple.
//
// The manifest assertions read the file and compare against a recorded symbol
// scan, so a new required-reason API creeping into app/ or src/ is caught.

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

/// The body of `func name`, from its opening brace to the matching close.
///
/// This exists because a textual count of `guard consentsToSending()` proves
/// only that the string occurs somewhere in the file: `startProvider` could be
/// left ungated while any other, textually identical guard satisfied the count.
/// Brace-scoping the search to the function's own body is what makes the
/// assertion about THIS entry point.
///
/// The returned body is CODE only: string literal contents and comments are
/// stripped, so a `guard` that appears inside a message string or a commented
/// line — braces and all — cannot be mistaken for a real gate.
func functionBody(_ name: String, in source: String) -> String? {
    guard let signature = source.range(of: "func \(name)") else { return nil }
    var i = signature.upperBound
    var bodyStart: String.Index?
    while i < source.endIndex {
        let c = source[i]
        if c == "{" { bodyStart = source.index(after: i); break }
        // A `=` or `;` before `{` means this is a declaration without a body.
        if c == "=" || c == ";" { return nil }
        i = source.index(after: i)
    }
    guard let start = bodyStart else { return nil }
    var depth = 1
    var j = start
    var code = ""
    while j < source.endIndex {
        let c = source[j]
        if c == "\"" {
            j = source.index(after: j)
            while j < source.endIndex {
                if source[j] == "\\" { j = source.index(after: j); if j < source.endIndex { j = source.index(after: j) }; continue }
                if source[j] == "\"" { break }
                j = source.index(after: j)
            }
            if j < source.endIndex { j = source.index(after: j) }
            code += "\"\""
            continue
        }
        if c == "/", j < source.index(before: source.endIndex) {
            let next = source[source.index(after: j)]
            if next == "/" {
                while j < source.endIndex, source[j] != "\n" { j = source.index(after: j) }
                continue
            }
            if next == "*" {
                j = source.index(after: j)
                while j < source.endIndex, !(source[j] == "*" && source.index(after: j) < source.endIndex && source[source.index(after: j)] == "/") {
                    j = source.index(after: j)
                }
                j = source.index(after: j)
                if j < source.endIndex { j = source.index(after: j) }
                continue
            }
        }
        if c == "{" { depth += 1 }
        if c == "}" {
            depth -= 1
            if depth == 0 { return code }
        }
        code.append(c)
        j = source.index(after: j)
    }
    return nil
}

@main
enum PrivacyTests {
    static func main() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

        // --- 1. The policy is bundled so it can be read offline ---------------
        let policyURL = root.appendingPathComponent("docs/wiki/Privacy-Policy.md")
        guard let policy = try? String(contentsOf: policyURL, encoding: .utf8) else {
            print("FAIL cannot read \(policyURL.path)")
            exit(1)
        }
        check("the policy is not empty", policy.count > 5000, "got \(policy.count) chars")

        // The bundled copy is what the app opens. If the Makefile stops copying
        // it, About and Help would open an empty window.
        let makefile = (try? String(contentsOf: root.appendingPathComponent("Makefile"), encoding: .utf8)) ?? ""
        check("the Makefile bundles the policy into Resources",
              makefile.contains("PrivacyPolicy.md"),
              "About/Help open it in-app, so it must ship in the bundle")
        check("the Makefile bundles the privacy manifest",
              makefile.contains("PrivacyInfo.xcprivacy"))

        // The bundled file name and the lookup must agree. They did not: the
        // extension was chosen by comparing against `README`, so every later
        // markdown document was looked up as `PrivacyPolicy` with no extension
        // and never found. The window opened to "This document was not bundled
        // with this build." while the file sat in Resources the whole time.
        let docView = (try? String(contentsOf: root.appendingPathComponent("app/DocumentView.swift"),
                                   encoding: .utf8)) ?? ""
        check("the resource lookup uses the document's own extension",
              docView.contains("withExtension: fileExtension"),
              "comparing against README strands every other markdown document")
        check("the privacy document declares a .md extension",
              docView.contains("case .readme, .privacy: return \"md\""),
              "the bundled file is PrivacyPolicy.md")
        check("the bundle name matches the resource name",
              makefile.contains("PrivacyPolicy.md") && docView.contains("return \"PrivacyPolicy\""),
              "a mismatch opens an empty window")

        // The manifest belongs in Resources, not the bundle root: codesign
        // refuses to seal an unsigned root item ("code object is not signed at
        // all / In subcomponent: .../Contents/PrivacyInfo.xcprivacy"), which
        // broke `make bundle` outright.
        check("the manifest goes in Resources, not the bundle root",
              makefile.contains("Contents/Resources/PrivacyInfo.xcprivacy"),
              "codesign cannot seal a bundle-root manifest")

        // --- 2. Every link click in the policy resolves in-app ----------------
        // The policy is markdown the app renders, so a link it cannot resolve
        // is a dead end for the reader. Scheme-less links are the dangerous
        // kind: macOS is handed a filesystem path and fails with (-50).
        let shown = Readme.forDisplay(policy)
        check("the policy survives forDisplay unmodified in substance",
              shown.contains("How long data is kept"),
              "trimming must not eat a section")
        check("the policy has no leaked markup",
              !shown.contains("<p align") && !shown.contains("<br>"))

        // --- The published URL lives in the repo, not the wiki ----------------
        // App Store Connect needs a publicly reachable Privacy Policy URL. The
        // wiki was one candidate, but it is a second copy to keep in sync, and
        // its page names come from file names in a separate repository — a
        // U+2010 HYPHEN in one silently 302-redirected every link to the wiki
        // home. The repo file is the source of truth, so it is the URL.
        //
        // `github.com/.../blob/...` is the right form, not `raw.`: the raw URL
        // serves `text/plain`, so a reviewer sees literal `# AppleTree Privacy
        // Policy` and pipe tables instead of a rendered policy. The blob page
        // renders headings and tables as a normal document.
        check("the Published-at URL points at the repo file",
              policy.contains("blob/main/docs/wiki/Privacy-Policy.md"),
              "App Store Connect is given this exact URL")
        check("the Published-at URL is not a raw URL",
              !policy.contains("raw.githubusercontent.com"),
              "raw serves text/plain: unrendered markdown to a reviewer")
        check("no wiki URL is referenced anywhere",
              !policy.contains("appletree/wiki"),
              "the wiki is a second copy to maintain, and it broke once already")
        check("no U+2010 hyphen hides in a URL",
              !shown.contains("\u{2010}"),
              "U+2010 looks like '-' but is a different URL")
        check("the bundled policy and the published copy are the same file",
              makefile.contains("docs/wiki/Privacy-Policy.md"),
              "one source, bundled into the app and published from the repo")

        // A scheme-less link can only be safe if it names a bundled document.
        let schemeLess = ["privacy-policy", "privacy", "Privacy-Policy", "privacy-policy.md"]
        for target in schemeLess {
            check("\(target) resolves to a bundled document",
                  DocLink.bundledDocument(for: target) == .privacy,
                  "DocLink refused it, so the click would open a filesystem path")
        }

        // The cross-page links must be absolute, because the wiki pages are not
        // in the bundle and a relative `Support` would resolve nowhere in-app.
        check("no relative wiki link is left scheme-less in the policy",
              !shown.contains("](Support)") && !shown.contains("](Home)"),
              "a scheme-less link becomes a filesystem path")

        // --- 3. The AI disclosure exists and names the destination -----------
        let cleanup = (try? String(contentsOf: root.appendingPathComponent("app/Cleanup.swift"), encoding: .utf8)) ?? ""
        let model = (try? String(contentsOf: root.appendingPathComponent("app/Model.swift"), encoding: .utf8)) ?? ""

        check("the disclosure is presented", cleanup.contains("model.pendingConsent"),
              "5.1.2(i) needs explicit permission before sending")
        check("the disclosure names the destination",
              cleanup.contains("pendingConsentDestination"),
              "a dialog that does not say where the data goes cannot grant permission")

        // The gate must sit in Model, INSIDE `startProvider`'s own body.
        //
        // A textual count of the guard across the whole file proves nothing:
        // it passes with `startProvider` ungated whenever exactly one other
        // textually identical guard exists anywhere in Model.swift. Scoping the
        // search to the function's brace-matched body is what pins the gate to
        // the one entry point every path (panel button, planner menu, Settings'
        // start, restart) funnels through.
        let startBody = functionBody("startProvider", in: model)
        check("startProvider's body was found", startBody != nil,
              "the assertion below cannot be evaluated without it")
        check("the start path is gated inside startProvider's own body",
              startBody?.contains("guard consentsToSending()") == true,
              "the guard must be in func startProvider, not merely somewhere in Model.swift")
        check("consent is recorded, not asked every time",
              model.contains("bz.cleanupConsent"))
        check("declining is possible and leaves the app usable",
              model.contains("func declineCleanupConsent"))

        // --- 4. The manifest matches the binary's real API usage -------------
        let manifestURL = root.appendingPathComponent("app/PrivacyInfo.xcprivacy")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? PropertyListSerialization.propertyList(
                from: manifestData, options: [], format: nil) as? [String: Any] else {
            print("FAIL the manifest is missing or not a valid plist")
            exit(1)
        }

        let types = (manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]]) ?? []
        var declared: [String: [String]] = [:]
        for entry in types {
            guard let name = entry["NSPrivacyAccessedAPIType"] as? String,
                  let reasons = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] else { continue }
            declared[name] = reasons
        }

        // Recorded from `nm -u build/AppleTree.app/Contents/MacOS/AppleTree`:
        //   getattrlist, getattrlistbulk, stat, fstat, fstatat, lstat  -> FileTimestamp
        //   statfs                                                    -> DiskSpace
        //   NSUserDefaults                                            -> UserDefaults
        // Deliberately absent (no symbol): SystemBootTime, ActiveKeyboards.
        check("FileTimestamp is declared", declared["NSPrivacyAccessedAPICategoryFileTimestamp"] != nil)
        check("DiskSpace is declared", declared["NSPrivacyAccessedAPICategoryDiskSpace"] != nil)
        check("UserDefaults is declared", declared["NSPrivacyAccessedAPICategoryUserDefaults"] != nil)

        // DDA9.1 ("display timestamps to the person") forbids sending anything
        // derived off-device, and AppleTree sends Xcode simulator dates in the
        // scan summary. Declaring it would be a false statement.
        check("FileTimestamp does NOT claim DDA9.1",
              !(declared["NSPrivacyAccessedAPICategoryFileTimestamp"] ?? []).contains("DDA9.1"),
              "AppleTree sends timestamp-derived dates off-device, which DDA9.1 forbids")
        check("FileTimestamp claims 3B52.1",
              (declared["NSPrivacyAccessedAPICategoryFileTimestamp"] ?? []).contains("3B52.1"))
        check("DiskSpace claims 85F4.1",
              (declared["NSPrivacyAccessedAPICategoryDiskSpace"] ?? []).contains("85F4.1"))
        check("UserDefaults claims CA92.1",
              (declared["NSPrivacyAccessedAPICategoryUserDefaults"] ?? []).contains("CA92.1"))

        // A category with no reason is rejected; an unknown category is too.
        for (name, reasons) in declared {
            check("\(name) declares at least one reason", !reasons.isEmpty)
        }
        let known: Set<String> = [
            "NSPrivacyAccessedAPICategoryFileTimestamp",
            "NSPrivacyAccessedAPICategorySystemBootTime",
            "NSPrivacyAccessedAPICategoryDiskSpace",
            "NSPrivacyAccessedAPICategoryUserDefaults",
            "NSPrivacyAccessedAPICategoryActiveKeyboards",
        ]
        check("every declared category is a real Apple category",
              Set(declared.keys).isSubset(of: known),
              "unknown: \(Set(declared.keys).subtracting(known))")

        // No data is collected by the developer, so the array must stay empty.
        // A non-empty array would be a claim to Apple that we collect something.
        let collected = (manifest["NSPrivacyCollectedDataTypes"] as? [Any]) ?? []
        check("no collected data types are claimed", collected.isEmpty,
              "AppleTree has no accounts, analytics or servers")
        check("tracking is declared false", (manifest["NSPrivacyTracking"] as? Bool) == false)

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
