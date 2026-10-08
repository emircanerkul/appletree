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

        // --- The header's own markup is gone, whichever tag would reveal it ---
        // The header is skipped as one block, so EVERY tag inside it must be
        // absent. Asserting only on `<p align` would pass even if the skip
        // stopped early, because the lines after the halfway point use `<h1>`,
        // `<sub>` and `<br>`. These are the markers that catch a short skip.
        check("no <h1> markup survives", !shown.contains("<h1"))
        check("no <img> markup survives", !shown.contains("<img"))
        check("no <sub> markup survives", !shown.contains("<sub"))
        check("no html comment survives", !shown.contains("<!--"))

        // --- The header's terminator is exclusive -----------------------------
        // The in-app skip ends at the header's explicit `<!-- /header -->`
        // marker, NOT at the `<br clear="all">` inside it. That inner `<br>`
        // exists to end the title's float; treating it as the terminator ended
        // the skip halfway and leaked the rest of the header as literal text.
        //
        // The header's own prose is deliberately absent either way — the viewer
        // draws the title, tagline and App Store button for itself, so re-adding
        // them here would duplicate them. What must survive is everything AFTER
        // the header, which is what a short skip would swallow.
        check("the Features heading still follows the header",
              shown.contains("## Features"))
        // Asserted against the tagline *read out of the file* rather than a
        // hardcoded copy of it. A literal here would silently stop testing
        // anything the next time the wording changes — the check would pass
        // because the old string is genuinely absent, not because the new one
        // was correctly stripped from the body.
        //
        // The markup is stripped from the derived line before comparing. The
        // raw line ends in `</p>`, and `forDisplay` removes that tag, so a
        // comparison against the raw text can never match what the viewer holds
        // — the assertion would pass no matter what leaked.
        if let tagRange = raw.range(of: "in under a second.</strong><br>\n") {
            let after = raw[tagRange.upperBound...]
            let tagline = Readme.stripMarkup(String(after.prefix { $0 != "\n" }))
                .trimmingCharacters(in: .whitespaces)
            check("the header's tagline is not duplicated into the body",
                  !tagline.isEmpty && !shown.contains(tagline),
                  "the viewer draws its own tagline; this would duplicate it")
        } else {
            check("the header has a tagline line", false,
                  "expected the tagline to follow the headline in the header")
        }
        // `</p>` and `<br>` are the ones that got glued to prose and rendered
        // as literal text next to real words.
        check("no stray closing </p> survives", !shown.contains("</p>"))
        check("no stray <br> survives", !shown.contains("<br>"))

        // --- The header stays compact ----------------------------------------
        // The title's `<br clear="all">` is what used to force the floats onto
        // their own row and add a whole extra band of vertical space. Without
        // it the title sits beside the marks, which is the compact layout.
        // Asserting on the raw file, not the displayed text, because the header
        // is removed from what the viewer shows.
        check("the header has no <br clear> spacer",
              !raw.contains("<br clear="),
              "that element adds a full row above the title")
        check("the header is terminated for the in-app skip",
              raw.contains("<!-- /header -->"),
              "without it the header markup leaks into the README window")
        // A table cannot be made borderless on GitHub, so its return would also
        // bring the borders back.
        check("the header is not a table", !raw.prefix(1200).contains("<table"))

        // --- The header marks stay clickable ---------------------------------
        // GitHub wraps every heading in `<div class="markdown-heading">`, which
        // its CSS gives `position: relative`. A positioned box paints ABOVE a
        // float, so a logo floated on its own line before the heading ends up
        // underneath that div — visible, but not clickable. Measured against
        // GitHub's own stylesheets: 42 of 49 probe points on the erklab mark hit
        // the heading instead of the link.
        //
        // Inside the heading there is no such overlap: the floats belong to the
        // heading's own box. So the header must put both marks INSIDE the <h1>,
        // which also keeps the compact single-row layout.
        let headerText = raw.prefix(900)
        let h1Start = headerText.range(of: "<h1")
        let h1End = headerText.range(of: "</h1>")
        check("the header has an <h1>", h1Start != nil && h1End != nil)
        if let s = h1Start, let e = h1End {
            let heading = String(headerText[s.lowerBound..<e.upperBound])
            check("the erklab link is inside the <h1>",
                  heading.contains("erklab.com"),
                  "outside it, the heading's positioned box covers the mark")
            check("the app icon is inside the <h1>",
                  heading.contains("assets/icon.png"),
                  "outside it, the heading's positioned box covers the mark")
            check("the erklab mark is an anchor, not a bare image",
                  heading.contains("<a href=\"https://erklab.com\">"))
        }
        // Floats outside the heading are the bug; they also cost a row.
        let beforeH1 = h1Start.map { String(headerText[headerText.startIndex..<$0.lowerBound]) } ?? ""
        check("no float is stranded before the <h1>",
              !beforeH1.contains("<img"),
              "a float here is covered by the heading and not clickable")

        // --- The marks are small enough to clear the <h1> underline ----------
        // GitHub draws `border-bottom: 1px solid` under an h1, at the bottom of
        // its content box. A float INSIDE the h1 that is taller than the line
        // box hangs below that line, and the rule is painted across it.
        //
        // Measured against GitHub's real stylesheets: the h1 content box ends at
        // y=74 in a 24px-padded document, and the 1px rule sits exactly there.
        // A 64px icon spans y 24..88 and is sliced; 48px spans 24..72 and clears
        // it. The h1's own line box (font-size 2em x line-height 1.25 = 40px) is
        // the natural bound, so 48px is the largest safe square icon here.
        //
        // These assertions read the declared widths from the markup, which is
        // what actually controls the rendered height.
        func declaredWidth(of asset: String) -> Int? {
            guard let r = raw.range(of: "src=\"\(asset)\"") else { return nil }
            let after = raw[r.upperBound...]
            guard let w = after.range(of: "width=\""),
                  let close = after[w.upperBound...].firstIndex(of: "\"") else { return nil }
            return Int(after[w.upperBound..<close])
        }
        if let icon = declaredWidth(of: "assets/icon.png") {
            check("the app icon is not taller than the h1 line box",
                  icon <= 48,
                  "declared \(icon)px: a square icon over ~48px crosses the h1 rule")
        } else {
            check("the app icon declares a width", false, "no width= on assets/icon.png")
        }
        // The erklab mark is 301x98, so its height is width / 3.07. It must also
        // stay under the rule.
        if let logo = declaredWidth(of: "assets/erklab-logo.svg") {
            let height = Double(logo) / (301.0 / 98.0)
            check("the erklab mark is not taller than the h1 line box",
                  height <= 48,
                  "declared \(logo)px wide -> \(String(format: "%.0f", height))px tall")
        } else {
            check("the erklab mark declares a width", false, "no width=")
        }
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
        //
        // Deliberately NOT starting with markup: a document that opens with an
        // HTML block has its header skipped wholesale (that is how the real
        // README's header is dropped), so a fixture beginning with `<p>` would
        // test the header rule instead of the parser's.
        let leaky = """
        Intro paragraph.

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
        // --- Tables are ROWS of cells, not one cell per block ---------------
        // The bug: keying a run on the first intent component keyed on the
        // CELL, so every cell became its own full-width block and the benchmark
        // tables rendered as a stack of single-cell rows. Counting `.tableRow`
        // blocks alone did NOT catch that, because each cell was itself such a
        // block — so the assertions below check cell counts and widths.
        let tableRows = blocks.compactMap { block -> (cells: [AttributedString], header: Bool, align: [ColumnAlign])? in
            if case .tableRow(let cells, let header, let align) = block.role { return (cells, header, align) }
            return nil
        }
        check("table rows were detected", tableRows.count >= 6, "got \(tableRows.count)")
        check("rows carry more than one cell",
              tableRows.allSatisfy { $0.cells.count >= 2 },
              "cell counts: \(tableRows.map(\.cells.count))")
        // The README's three tables are 3, 3 and 2 columns wide.
        check("a three-column table produced three cells in a row",
              tableRows.contains { $0.cells.count == 3 },
              "widths seen: \(Set(tableRows.map(\.cells.count)).sorted())")
        check("a header row is marked as one",
              tableRows.contains(where: \.header),
              "no row flagged header")
        // Column alignment must be read from the `---:` markers: the benchmark
        // tables right-align their numbers, and losing that is invisible in text.
        check("a row carries per-column alignment",
              tableRows.contains { $0.align.count >= 3 },
              "alignments: \(tableRows.map { $0.align.count })")
        // Cell text must be the cell, not the whole row concatenated. The README
        // has three tables; each header row's cells must be exactly the header
        // labels, individually — not the row's text in one cell.
        let headerRows = tableRows.filter(\.header)
        check("every table has a header row", headerRows.count >= 3, "got \(headerRows.count)")
        for row in headerRows {
            // A header cell is short (a label), never the whole row joined.
            check("header cells are individual labels",
                  row.cells.allSatisfy { String($0.characters).count < 30 },
                  "cells: \(row.cells.map { String($0.characters) })")
        }
        check("the engine table's header row holds its own labels",
              headerRows.contains { row in
                  let labels = row.cells.map { String($0.characters).trimmingCharacters(in: .whitespaces) }
                  return labels.contains("Scan time") && labels.contains("Peak memory")
              },
              "headers: \(headerRows.map { $0.cells.map { String($0.characters) } })")
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

        // --- UI-5: each table keeps its own column alignment ------------------
        //
        // `MarkdownBlocks.parse` held one alignment vector for the whole
        // document and only filled it when empty, so the second and every later
        // table rendered with the FIRST table's alignment. Two adjacent tables
        // with opposite alignment is the smallest fixture that exposes it.
        let twoTables = """
        | left | right |
        |:--|--:|
        | a | 1 |

        | right | left |
        |--:|:--|
        | b | 2 |
        """
        var alignVectors: [[ColumnAlign]] = []
        for block in MarkdownBlocks.parse(twoTables) {
            if case .tableRow(_, _, let align) = block.role { alignVectors.append(align) }
        }
        // Four rows: header + body of each table. The first two must share one
        // vector and the last two the other, and the two vectors must differ —
        // the defect was every table reusing the first one.
        let unique = alignVectors.map { $0.map(String.init(describing:)).joined(separator: ",") }
        check("each table keeps its own column alignment",
              unique.count == 4
                && unique[0] == unique[1] && unique[2] == unique[3]
                && unique[0] != unique[2],
              "alignments: \(unique)")

        // --- UI-6: an unclosed HTML block, and a leading autolink ------------
        //
        // A `<table>` with no `</table>` used to swallow the rest of the
        // document, and a document starting with `<https://…>` was classified as
        // an HTML header and rendered completely empty (both measured).
        let unclosed = "# Title\n<table>\n<tr><td>x</td></tr>\n\n## After\n\nprose\n"
        let unclosedOut = Readme.forDisplay(unclosed)
        check("an unclosed HTML block does not eat the document",
              unclosedOut.contains("## After") && unclosedOut.contains("prose"),
              "rendered: \(unclosedOut.prefix(80))")

        let autolink = "<https://example.com>\n\n# Heading\n\nprose\n"
        let autolinkOut = Readme.forDisplay(autolink)
        check("a document starting with an autolink still renders",
              autolinkOut.contains("# Heading") && autolinkOut.contains("prose"),
              "rendered: \(autolinkOut.prefix(80))")

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
