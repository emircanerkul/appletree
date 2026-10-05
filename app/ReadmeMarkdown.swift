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

/// How one table column is aligned, from the markdown's `---:` markers.
nonisolated enum ColumnAlign: Equatable {
    case leading, center, trailing
}

/// What a markdown block is, which decides how it is drawn.
nonisolated enum BlockRole: Equatable {
    case heading(Int)
    case listItem(Int)
    case codeBlock
    /// One table row: its cells plus each column's alignment. A row is a block,
    /// not a cell — see `MarkdownBlocks.parse`.
    case tableRow(cells: [AttributedString], header: Bool, align: [ColumnAlign])
    case paragraph
}

/// One rendered block.
nonisolated struct ReadmeBlock: Identifiable {
    let id: Int
    let text: AttributedString
    let role: BlockRole
}

/// Where a markdown link in a bundled document should actually go.
///
/// Markdown links are written relative to the repository — `LICENSE`,
/// `.github/SECURITY.md`, `docs/benchmarks/BENCHMARKS.md` — and Foundation
/// hands those through with `scheme == nil`. SwiftUI then passes the bare
/// string to macOS, which treats it as a filesystem path, fails to open it, and
/// raises "The application can't be opened. (-50)". That is what clicking
/// `SECURITY.md` or `LICENSE` in the README did.
///
/// So a link with no scheme is never opened as-is. It is either satisfied
/// in-app (a document that ships in the bundle) or resolved against the
/// repository on GitHub, which is where a relative link in a README means to
/// point.
nonisolated enum DocLink {
    /// A scheme-less link that names a file the app already bundles.
    static func bundledDocument(for target: String) -> BundledDocRef? {
        let name = target.trimmingCharacters(in: CharacterSet(charactersIn: "./"))
        switch name.lowercased() {
        case "license", "license.md", "license.txt": return .license
        case "readme", "readme.md": return .readme
        default: return nil
        }
    }

    /// Resolve any link to something worth opening, or `nil` to ignore it.
    ///
    /// - `#anchor` links are in-page: the app has no anchor scrolling, so they
    ///   are dropped rather than opened (a bare `#license` as a path fails the
    ///   same way a bare `LICENSE` does).
    /// - `mailto:`, `https:` and any other real scheme are left alone.
    /// - Everything else becomes a GitHub blob or tree URL.
    static func resolve(_ url: URL) -> URL? {
        if url.scheme != nil {
            // A pure fragment has no host worth opening on its own.
            if url.absoluteString.hasPrefix("#") { return nil }
            return url
        }
        let target = url.absoluteString
        if target.hasPrefix("#") { return nil }
        // Already absolute but unschemed (rare); nothing sensible to do.
        if target.isEmpty { return nil }
        return repoURL(for: target)
    }

    /// A repository path turned into a browsable GitHub URL.
    ///
    /// A trailing slash means a directory, so it goes to the tree view; a file
    /// goes to the blob view. Both resolve on the default branch, which GitHub
    /// redirects to the real default even when it is not `main`.
    private static func repoURL(for target: String) -> URL? {
        let repo = "https://github.com/emircanerkul/appletree"
        let isDirectory = target.hasSuffix("/")
        let cleaned = target.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleaned.isEmpty else { return URL(string: repo) }
        let kind = isDirectory ? "tree" : "blob"
        // Percent-encode each path segment: the README links contain none today,
        // but a future `docs/my notes.md` must not produce a broken URL.
        let encoded = cleaned.split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return URL(string: "\(repo)/\(kind)/main/\(encoded)")
    }
}

/// Documents the app bundles, named here so the link resolver does not have to
/// import the SwiftUI view layer to talk about them.
nonisolated enum BundledDocRef {
    case readme
    case license
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
    /// Structural role, kept separate from the rendered `BlockRole` because a
    /// table row needs its cells collected before it becomes a block.
    private enum RunRole: Equatable {
        case heading(Int)
        case listItem(Int)
        case codeBlock
        case tableCell(column: Int, row: Int, header: Bool)
        case tableStart
        case paragraph
    }

    static func parse(_ markdown: String) -> [ReadmeBlock] {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else { return [] }

        var blocks: [ReadmeBlock] = []
        /// Alignment declared by the table's `---:` markers, indexed by column.
        var align: [ColumnAlign] = []

        // The block being accumulated, and the cells of the table row being
        // accumulated. A table row is ONE block: keying on the run's first
        // intent component would key on the CELL, which turned every cell into
        // its own full-width row (the bug the README's benchmark tables showed).
        var text = AttributedString()
        var role: BlockRole?
        var container: Int?

        var cells: [AttributedString] = []
        var cellsContainer: Int?
        var cellsHeader = false

        func appendBlock() {
            defer { text = AttributedString(); role = nil; container = nil }
            guard !text.characters.isEmpty, let role else { return }
            blocks.append(ReadmeBlock(id: blocks.count, text: text, role: role))
        }

        func flushCells() {
            defer { cells = []; cellsContainer = nil; cellsHeader = false }
            guard !cells.isEmpty else { return }
            blocks.append(ReadmeBlock(
                id: blocks.count,
                text: AttributedString(),
                role: .tableRow(cells: cells, header: cellsHeader, align: align)))
        }

        for run in parsed.runs {
            let runRole = runRoleOf(run)

            // A table cell: collect it into the current row. Its own identity is
            // per-cell, which is exactly why the row is keyed on the row
            // identity instead.
            if case .tableCell(_, let row, let header) = runRole {
                let rowContainer = containerOf(run, for: row)
                if cellsContainer != rowContainer {
                    flushCells()
                    cellsContainer = rowContainer
                    cellsHeader = header
                }
                // Column alignment rides on every cell run (the `.table`
                // component is attached to each one, not to a run of its own),
                // so it is read here rather than from a table-start run.
                if align.isEmpty { align = alignmentOf(run) }
                let piece = AttributedString(parsed[run.range])
                // Cells are drawn in their own Grid columns, so the separator is
                // only needed when a cell's own text is empty (a blank column).
                cells.append(piece)
                continue
            }
            // Anything after a table belongs to a new block.
            flushCells()

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
                continues = !text.characters.isEmpty && sameKind(blockRole(runRole), role)
            case (let open?, let next?):
                continues = open == next && sameKind(blockRole(runRole), role)
            default:
                continues = false
            }
            if !continues { appendBlock() }

            role = blockRole(runRole)
            container = runContainer
            text.append(parsed[run.range])
        }
        // Order matters: a trailing table row is a block, and must be emitted
        // even when no later run flushes it.
        flushCells()
        appendBlock()
        return blocks
    }

    /// The container identity a table cell belongs to.
    ///
    /// For a cell the intent chain is `[cell, row, table]`, so the ROW is the
    /// second component. Grouping by the row is what makes one block per row.
    private static func containerOf(_ run: AttributedString.Runs.Run, for row: Int) -> Int {
        let components = run.presentationIntent?.components ?? []
        for component in components {
            switch component.kind {
            case .tableRow(let n):
                if n == row { return component.identity }
            case .tableHeaderRow:
                return component.identity
            default:
                continue
            }
        }
        // No row component: fall back to the table itself so all cells of an
        // unclassifiable table still group by table rather than one per cell.
        return components.last?.identity ?? -1
    }

    private static func alignmentOf(_ run: AttributedString.Runs.Run) -> [ColumnAlign] {
        let components = run.presentationIntent?.components ?? []
        for component in components {
            if case .table(let columns) = component.kind {
                return columns.map { column in
                    switch column.alignment {
                    case .right: return .trailing
                    case .center: return .center
                    default: return .leading
                    }
                }
            }
        }
        return []
    }

    private static func runRoleOf(_ run: AttributedString.Runs.Run) -> RunRole {
        guard let components = run.presentationIntent?.components else { return .paragraph }
        var headingLevel: Int?
        var listOrdinal: Int?
        var inCode = false
        var cell: (column: Int, row: Int, header: Bool)?
        var headerColumn: Int?
        var sawTable = false
        for component in components {
            switch component.kind {
            case .header(let level): headingLevel = level
            case .listItem(let ordinal): listOrdinal = ordinal
            case .codeBlock: inCode = true
            case .tableCell(let column):
                cell = (column, 0, false)
            case .tableRow(let row):
                if let c = cell { cell = (c.column, row, false) }
            case .tableHeaderRow:
                if let c = cell { headerColumn = c.column }
            case .table: sawTable = true
            default: continue
            }
        }
        if let headerColumn { return .tableCell(column: headerColumn, row: -1, header: true) }
        if let cell { return .tableCell(column: cell.column, row: cell.row, header: false) }
        if sawTable { return .tableStart }
        if let headingLevel { return .heading(headingLevel) }
        if let listOrdinal { return .listItem(listOrdinal) }
        if inCode { return .codeBlock }
        return .paragraph
    }

    private static func blockRole(_ role: RunRole) -> BlockRole {
        switch role {
        case .heading(let level): return .heading(level)
        case .listItem(let ordinal): return .listItem(ordinal)
        case .codeBlock: return .codeBlock
        // Cells never reach here; the table branch consumes them.
        case .tableCell: return .paragraph
        case .tableStart: return .paragraph
        case .paragraph: return .paragraph
        }
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
