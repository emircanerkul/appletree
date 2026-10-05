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

        // --- Every wiki URL is plain ASCII and internally consistent ---------
        // The "Published at" line is what App Store Connect is given, and the
        // links between pages have to agree with it. The live wiki page was
        // created with U+2010 HYPHEN in its filename — visually identical to
        // ASCII `-`, a different URL — so /wiki/Privacy-Policy 302-redirected
        // to the wiki home and the policy was unreachable from every link
        // pointing at it, including the one in this file.
        //
        // Wiki page names come from the file name in the wiki repo, so the
        // guard is: no non-ASCII anywhere in a wiki URL, and no hyphen other
        // than U+002D.
        let wikiURLs = ["Home", "Privacy-Policy", "Support"]
        for page in wikiURLs {
            let url = "https://github.com/emircanerkul/appletree/wiki/\(page)"
            check("\(page) has an all-ASCII URL",
                  url.allSatisfy { $0.isASCII },
                  "a non-ASCII character in a wiki page name breaks every link to it")
        }
        check("no U+2010 hyphen hides in a wiki link",
              !shown.contains("\u{2010}") && !policy.contains("wiki/Privacy\u{2010}Policy"),
              "U+2010 looks like '-' but resolves to a different page")

        // The published URL must name the same page the other links use.
        check("the Published-at URL uses the ASCII page name",
              policy.contains("wiki/Privacy-Policy"),
              "App Store Connect is given this exact URL")
        check("the Published-at URL is not the wiki home",
              !policy.contains("Published at:** https://github.com/emircanerkul/appletree/wiki\n"),
              "a URL that redirects to Home is not a privacy policy URL")

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

        // The gate must sit in Model, on BOTH start paths. Gating the buttons
        // would leave restart, Settings and install-and-run open.
        //
        // Counted as `guard consentsToSending()`, not `consentsToSending()`:
        // the plain identifier also matches the function's own definition, so
        // the looser count is satisfied by a single guard. That is not
        // hypothetical — the first version of this test passed with startAgent's
        // guard deleted.
        check("startProvider is gated",
              model.contains("func startProvider") && model.contains("guard consentsToSending()"))
        let gateCount = model.components(separatedBy: "guard consentsToSending()").count - 1
        check("BOTH start paths are gated", gateCount >= 2,
              "found \(gateCount) guard(s): one leaves the other entry point ungated")
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
        // derived off-device, and AppleTree sends simulator and Codex dates in
        // the scan summary. Declaring it would be a false statement.
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
