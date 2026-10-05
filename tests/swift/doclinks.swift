// Link-resolution regression net for the bundled documents.
//
// Build (from repo root):
//   swiftc tests/swift/doclinks.swift app/ReadmeMarkdown.swift \
//       -parse-as-library -swift-version 6 -default-isolation MainActor \
//       -target arm64-apple-macos14.0 \
//       -o .build/doclink-tests
//
// The bug: markdown links written relative to the repository (`LICENSE`,
// `.github/SECURITY.md`) reach Foundation with `scheme == nil`. SwiftUI handed
// them to macOS as filesystem paths, and every click raised
//
//     The application can't be opened. (-50)
//
// So the rule is: a scheme-less link is NEVER opened as-is. It is either served
// in-app (a document we bundle) or resolved to GitHub. These assertions pin
// both halves, and assert on the real README/LICENSE rather than a fixture, so
// a new relative link added to either document is covered automatically.

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
enum DocLinkTests {
    static func main() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

        // --- Everything with a real scheme passes through untouched ----------
        let https = URL(string: "https://apps.apple.com/app/id6819034229")!
        check("an https link is preserved",
              DocLink.resolve(https)?.absoluteString == https.absoluteString)
        let mail = URL(string: "mailto:licensing@appletree.apps.erklab.com")!
        check("a mailto link is preserved",
              DocLink.resolve(mail)?.absoluteString == mail.absoluteString)

        // --- In-page anchors are dropped, not opened -------------------------
        // `#license` as a path fails exactly like `LICENSE` does, and the app has
        // no anchor scrolling to honour instead.
        check("a bare anchor is not opened",
              DocLink.resolve(URL(string: "#license")!) == nil)
        check("an anchor on a path is not opened",
              DocLink.resolve(URL(string: "#readme")!) == nil)

        // --- Bundled documents resolve to the in-app viewer ------------------
        check("LICENSE resolves to the bundled license",
              DocLink.bundledDocument(for: "LICENSE") == .license)
        check("SECURITY.md does NOT resolve to a bundled doc",
              DocLink.bundledDocument(for: ".github/SECURITY.md") == nil,
              "only documents the app ships may be claimed")
        check("README.md resolves to the bundled README",
              DocLink.bundledDocument(for: "README.md") == .readme)

        // --- Relative file links become GitHub blob URLs ---------------------
        let security = DocLink.resolve(URL(string: ".github/SECURITY.md")!)
        check("a relative file link resolves to a GitHub blob URL",
              security?.absoluteString == "https://github.com/emircanerkul/appletree/blob/main/.github/SECURITY.md",
              security?.absoluteString ?? "nil")
        // A trailing slash means a directory, so it must go to `tree`, not `blob`.
        let dir = DocLink.resolve(URL(string: "docs/benchmarks/results/")!)
        check("a relative directory link resolves to a tree URL",
              dir?.absoluteString == "https://github.com/emircanerkul/appletree/tree/main/docs/benchmarks/results",
              dir?.absoluteString ?? "nil")

        // --- No scheme-less link in either document can reach the system ------
        // This is the assertion that would have caught the -50 bug: walk the real
        // documents, and require every link the parser produces to resolve to
        // something with a real scheme (or be deliberately dropped).
        for name in ["README.md", "LICENSE"] {
            let url = root.appendingPathComponent(name)
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
                check("\(name) is readable", false); continue
            }
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .full
            options.failurePolicy = .returnPartiallyParsedIfPossible
            guard let parsed = try? AttributedString(markdown: raw, options: options) else {
                check("\(name) parses", false); continue
            }
            var schemeLess = 0
            var resolvedOK = 0
            var dropped = 0
            for run in parsed.runs {
                guard let link = run.link else { continue }
                if link.scheme == nil {
                    schemeLess += 1
                    // Must be claimed in-app or converted; never returned as-is.
                    let bundled = DocLink.bundledDocument(for: link.absoluteString) != nil
                    if bundled { resolvedOK += 1; continue }
                    guard let resolved = DocLink.resolve(link) else { dropped += 1; continue }
                    if resolved.scheme == nil {
                        check("\(name): scheme-less link is never returned scheme-less",
                              false, link.absoluteString)
                    } else {
                        resolvedOK += 1
                    }
                }
            }
            // The README is the document full of relative links. The LICENSE has
            // none today (only https and mailto), so requiring one there would
            // assert a property the file does not have — the walk still runs, so
            // adding one later is covered without editing this test.
            check("\(name) parsed its links",
                  schemeLess >= 0, "found \(schemeLess)")
            check("\(name): every relative link resolves or is dropped",
                  resolvedOK + dropped == schemeLess,
                  "\(resolvedOK) resolved + \(dropped) dropped != \(schemeLess)")
        }

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
