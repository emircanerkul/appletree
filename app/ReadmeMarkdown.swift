import Foundation

// MARK: - Markdown the app can render
//
// The README ships inside the app, so "read the docs" needs no browser and no
// network. Foundation parses markdown natively, but SwiftUI's `Text` renders an
// `AttributedString`'s characters and drops its block structure — headings,
// lists and fences would all flatten into paragraphs.
//
// This file is deliberately free of SwiftUI: it is the part worth testing, and
// a test can compile it without linking a view framework.

/// What a markdown block is, which decides how it is drawn.
nonisolated enum BlockRole: Equatable {
    case heading(Int)
    case listItem(Int)
    case codeBlock
    case tableRow
    case paragraph
}

/// One rendered block.
nonisolated struct ReadmeBlock: Identifiable {
    let id: Int
    let text: AttributedString
    let role: BlockRole
}

/// The README, bundled into the app.
nonisolated enum Readme {
    /// The bundled file. `nil` only when the resource was left out of the build,
    /// which the viewer reports rather than showing an empty window.
    static var text: String? {
        guard let url = Bundle.main.url(forResource: "README", withExtension: "md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// A README written for GitHub, trimmed to what renders in the app.
    ///
    /// The file opens with an HTML header table and a hosted demo `<video>`.
    /// Foundation's markdown parser has no HTML support: it either shows those
    /// tags as literal text or swallows the prose inside them. Both blocks are
    /// removed here, and the viewer draws its own header instead — which keeps
    /// the title, the icons and the App Store link without any markup leaking.
    ///
    /// Fenced code is passed through untouched: a `<` in a code sample is
    /// content, not markup, and must survive.
    static func forDisplay(_ markdown: String) -> String {
        var out: [String] = []
        var inFence = false
        // The closing tag of a multi-line HTML block being skipped.
        var skippingUntil: String?
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                inFence.toggle()
                out.append(raw)
                continue
            }
            if inFence {
                out.append(raw)
                continue
            }
            if let close = skippingUntil {
                if line.hasPrefix(close) { skippingUntil = nil }
                continue
            }
            if line.hasPrefix("<table") { skippingUntil = "</table>"; continue }
            if line.hasPrefix("<video") { skippingUntil = "</video>"; continue }
            // Any other standalone markup line: <p …>, </p>, <br>, <sub>,
            // <picture>, <source …>, <img …>. Only a line that is *wholly*
            // markup is dropped, so prose mentioning a tag inside backticks
            // (e.g. `AppleTree <path>`) is untouched.
            if isMarkupOnly(line) { continue }
            out.append(raw)
        }
        return out.joined(separator: "\n")
    }

    /// Whether a line is nothing but an HTML tag.
    private static func isMarkupOnly(_ line: String) -> Bool {
        line.hasPrefix("<") && line.hasSuffix(">")
    }
}

/// Turns the README into blocks using Foundation's own markdown parser.
nonisolated enum MarkdownBlocks {
    static func parse(_ markdown: String) -> [ReadmeBlock] {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else { return [] }

        var blocks: [ReadmeBlock] = []
        var text = AttributedString()
        var role: BlockRole?
        // The intent container's numeric identity: successive runs of one
        // paragraph share it; a new paragraph gets a new one.
        var container: Int?

        func flush() {
            defer { text = AttributedString(); role = nil; container = nil }
            guard !text.characters.isEmpty, let role else { return }
            blocks.append(ReadmeBlock(id: blocks.count, text: text, role: role))
        }

        for run in parsed.runs {
            let runRole = roleOf(run)
            let runContainer = run.presentationIntent?.components.first?.identity

            // Whether this run continues the block being built.
            //
            // A run with NO presentation intent (a stray markup line, or any
            // text Foundation could not classify) must never continue a block:
            // it has no container, and treating "no container" as "same
            // container" is exactly what let one leaked `<p>` absorb the
            // `## Features` heading behind it, so the heading rendered as body
            // text.
            let continues: Bool
            switch (container, runContainer) {
            case (nil, nil):
                continues = !text.characters.isEmpty && sameKind(runRole, role)
            case (let open?, let next?):
                continues = open == next && sameKind(runRole, role)
            default:
                continues = false
            }
            if !continues { flush() }

            role = runRole
            container = runContainer
            text.append(parsed[run.range])
        }
        flush()
        return blocks
    }

    static func roleOf(_ run: AttributedString.Runs.Run) -> BlockRole {
        guard let components = run.presentationIntent?.components else { return .paragraph }
        for component in components {
            switch component.kind {
            case .header(let level): return .heading(level)
            case .listItem(let ordinal): return .listItem(ordinal)
            case .codeBlock: return .codeBlock
            case .tableHeaderRow, .tableRow: return .tableRow
            default: continue
            }
        }
        return .paragraph
    }

    /// Whether two roles are the same kind of block. Successive runs of one
    /// paragraph share a container and must merge; a heading whose level changed
    /// must not.
    static func sameKind(_ a: BlockRole, _ b: BlockRole?) -> Bool {
        guard let b else { return true }
        switch (a, b) {
        case (.heading(let x), .heading(let y)): return x == y
        case (.listItem, .listItem): return true
        case (.codeBlock, .codeBlock): return true
        case (.tableRow, .tableRow): return true
        case (.paragraph, .paragraph): return true
        default: return false
        }
    }
}
