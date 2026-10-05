// README viewer regression net.
//
// Build (from repo root):
//   swiftc tests/swift/readme.swift app/ReadmeMarkdown.swift \
//       -parse-as-library -swift-version 6 -default-isolation MainActor \
//       -target arm64-apple-macos14.0 -framework AppKit \
//       -o .build/readme-tests
//
// Two bugs this exists to prevent, both found by rendering the shipping README:
//
// 1. The README's own HTML header leaked into the view as literal tags, and one
//    leaked line (a `<p>` with no presentation intent) then ABSORBED the
//    `## Features` heading behind it — so "Features" rendered as body text.
//    The cause was treating "no container identity" as "same container".
// 2. A `<` inside fenced code is content. Stripping lines by a broader rule
//    would silently eat code samples, so the fence is asserted here.

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
enum ReadmeTests {
    static func main() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("README.md")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            print("FAIL cannot read README.md at \(url.path)")
            exit(1)
        }

        let shown = Readme.forDisplay(raw)

        // --- The HTML blocks are gone, and nothing else is -------------------
        check("no <table> survives", !shown.contains("<table"))
        check("no <td>/<tr> survives", !shown.contains("<td") && !shown.contains("<tr"))
        check("no <video> survives", !shown.contains("<video"))
        check("no <picture>/<source> survives",
              !shown.contains("<picture") && !shown.contains("<source"))
        check("no leaked <p> line survives", !shown.contains("<p align"))
        // `</p>` and `<br>` are the ones that got glued to prose and rendered
        // as literal text next to real words.
        check("no stray closing </p> survives", !shown.contains("</p>"))
        check("no stray <br> survives", !shown.contains("<br>"))
        // A backticked tag is documentation, not markup.
        check("prose mentioning a tag is kept", shown.contains("AppleTree <path>"))

        // --- Headings are still headings ------------------------------------
        // The bug: a leaked markup line swallowed the next heading, which then
        // rendered as an ordinary paragraph.
        let blocks = MarkdownBlocks.parse(shown)
        check("parsing produced blocks", !blocks.isEmpty, "got \(blocks.count)")
        let headings = blocks.compactMap { block -> String? in
            if case .heading = block.role { return String(block.text.characters) }
            return nil
        }
        check("the Features heading was parsed as a heading",
              headings.contains { $0.trimmingCharacters(in: .whitespaces) == "Features" },
              "headings: \(headings.prefix(12))")
        check("multiple section headings survive", headings.count >= 8, "got \(headings.count)")

        // --- Fenced code keeps its content ----------------------------------
        // A rule that stripped every tag-like line would eat this.
        let sample = """
        Intro.

        ```sh
        # a < b and <tag> must survive inside a fence
        echo "<hello>"
        ```

        After.
        """
        let fenced = Readme.forDisplay(sample)
        check("code fence content with < survives",
              fenced.contains("a < b and <tag> must survive inside a fence"),
              fenced)
        check("code fence quotes survive", fenced.contains("echo \"<hello>\""))
        check("code fence itself survives", fenced.contains("```sh"))

        // --- Prose outside a fence starts a NEW block -----------------------
        // Directly targets the regression: unclassified text must not merge with
        // the heading that follows it.
        let leaky = """
        <p align="center">
        </p>
        ## Features

        Body text.
        """
        let leakyBlocks = MarkdownBlocks.parse(Readme.forDisplay(leaky))
        let leakyHeadings = leakyBlocks.compactMap { block -> String? in
            if case .heading = block.role { return String(block.text.characters) }
            return nil
        }
        check("a leaked markup line does not swallow the next heading",
              leakyHeadings.contains { $0.trimmingCharacters(in: .whitespaces) == "Features" },
              "headings: \(leakyHeadings)")

        // The same guard, exercised WITHOUT the stripper in front of it.
        //
        // `forDisplay` removes the leaked line, so the check above would still
        // pass if the parser's container rule were wrong. This parses raw markup
        // directly, with the shape the guard genuinely governs: a run Foundation
        // could not classify, a blank line, then a heading it did classify. The
        // no-intent run must not absorb the heading.
        //
        // Note the shape matters. `<p x>\n## Head` (no blank line) is parsed by
        // Foundation as ONE unclassified run — the heading is never identified
        // as a heading at all, which no parser rule can recover. That case is
        // the stripper's job, and is covered above.
        let rawLeak = "<p>x</p>\n\n## Head\n\nBody.\n"
        let rawBlocks = MarkdownBlocks.parse(rawLeak)
        let rawHeadings = rawBlocks.compactMap { block -> String? in
            if case .heading = block.role { return String(block.text.characters) }
            return nil
        }
        check("the parser alone keeps the heading after a no-intent run",
              rawHeadings.contains { $0.trimmingCharacters(in: .whitespaces) == "Head" },
              "headings: \(rawHeadings)")
        // And that run is its own block, not glued onto the heading.
        check("the unclassified run did not merge into the heading block",
              rawBlocks.count == 3, "blocks: \(rawBlocks.map { String(describing: $0.role) })")

        // --- The real README's structure is intact ---------------------------
        // Tables and code blocks are the two block kinds besides headings that
        // the README leans on heavily. The counts track the README itself: it
        // has three fenced blocks (its ```sh samples).
        let codeBlocks = blocks.filter { if case .codeBlock = $0.role { return true } else { return false } }
        check("all three code blocks were detected", codeBlocks.count == 3, "got \(codeBlocks.count)")
        let tableRows = blocks.filter { if case .tableRow = $0.role { return true } else { return false } }
        check("table rows were detected", tableRows.count >= 8, "got \(tableRows.count)")
        let listItems = blocks.filter { if case .listItem = $0.role { return true } else { return false } }
        check("list items were detected", listItems.count >= 8, "got \(listItems.count)")

        // --- The LICENSE renders without losing any clause -------------------
        // The LICENSE is markdown, so the viewer parses it. That is only safe if
        // the parse is lossless for the operative text, which is exactly the kind
        // of thing that would pass review visually and still be wrong. These
        // sentences are the grant, the warranty disclaimer and the definitions.
        let licenseURL = root.appendingPathComponent("LICENSE")
        if let license = try? String(contentsOf: licenseURL, encoding: .utf8) {
            let rendered = Readme.forDisplay(license)
            let blocks = MarkdownBlocks.parse(rendered)
            let out = blocks.map { String($0.text.characters) }.joined(separator: "\n")
            let operative = [
                "Permission is hereby granted, free of charge, to any person obtaining a copy",
                "to use, copy, modify, merge, publish, distribute, sublicense, and/or sell",
                "THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND",
                "Attribution-NonCommercial-ShareAlike 4.0 International",
                "NonCommercial means not primarily intended for or directed towards",
                "Copyright (c) 2026 Ahmed Khaleel",
                "commercial purposes by the person who bought it",
                "stays CC BY-NC-SA",
            ]
            for sentence in operative {
                check("license clause survives rendering: \(sentence.prefix(42))…",
                      out.contains(sentence), "MISSING from rendered output")
            }
        } else {
            check("LICENSE is readable", false, "cannot read at \(licenseURL.path)")
        }

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
