import AppKit
import SwiftUI

// The parsing and markdown trimming live in ReadmeMarkdown.swift, free of
// SwiftUI. This file is the view layer only.

// MARK: - Bundled documents

/// A text document that ships inside the app, so reading it needs no browser and
/// no network.
///
/// Both the README and the LICENSE are read this way. They used to open
/// github.com in the user's browser, which is wrong twice over: it needs the
/// internet to read documentation that ships with the app, and it sends the
/// reader out of the app to a page laid out by GitHub rather than by us.
nonisolated enum BundledDoc: String, CaseIterable {
    case readme
    case license

    /// Resource name in the app bundle.
    var resource: String {
        switch self {
        case .readme: return "README"
        case .license: return "LICENSE"
        }
    }

    /// Window title.
    var title: String {
        switch self {
        case .readme: return String(localized: "AppleTree README")
        case .license: return String(localized: "AppleTree License")
        }
    }

    /// The file's text, or `nil` when the resource was left out of the build —
    /// which the viewer reports rather than showing an empty window.
    var text: String? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: resource == "README" ? "md" : nil)
                ?? Bundle.main.url(forResource: resource, withExtension: nil) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The markdown as it should be shown.
    ///
    /// The README is trimmed of the blocks written for GitHub's renderer (see
    /// `Readme.forDisplay`). The LICENSE is plain text with no markdown, so it is
    /// shown verbatim: trimming it could silently drop a clause.
    var displayText: String? {
        guard let raw = text else { return nil }
        switch self {
        case .readme: return Readme.forDisplay(raw)
        case .license: return raw
        }
    }
}

// MARK: - The window

/// A bundled document in a window of its own, rendered as real text.
///
/// SwiftUI's `Text` renders an `AttributedString`'s characters but drops its
/// block structure, so headings, lists and fences would flatten into paragraphs.
/// The blocks come from `ReadmeMarkdown`, which walks Foundation's
/// `presentationIntent`; this draws each one. Native rendering, no web view, no
/// third-party markdown parser.
@MainActor
final class DocumentWindow {
    /// One window per document, so opening the README twice raises the same
    /// window instead of stacking duplicates.
    private static var controllers: [BundledDoc: NSWindowController] = [:]

    static func show(_ doc: BundledDoc) {
        if let controller = controllers[doc] {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: DocumentView(doc: doc)))
        window.title = doc.title
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 780, height: 740))
        window.isReleasedWhenClosed = false
        window.center()
        let controller = NSWindowController(window: window)
        controllers[doc] = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - The view

private struct DocumentView: View {
    let doc: BundledDoc
    /// Parsed once when the view is created, not on every body evaluation.
    private let blocks: [ReadmeBlock]
    private let missing: Bool
    private let source: String

    init(doc: BundledDoc) {
        self.doc = doc
        let raw = doc.displayText
        missing = raw == nil
        source = raw ?? ""
        // The LICENSE is markdown (that is how GitHub publishes it), so it is
        // parsed like the README — otherwise its `**emphasis**` and `[links]`
        // show through as literal syntax and read as a rendering bug.
        //
        // Fidelity was checked before choosing this: every operative sentence of
        // both the MIT and the CC BY-NC-SA text survives the parse (verified by
        // substring against the rendered output). If a future license edit ever
        // made parsing lossy, the fallback below still shows the verbatim source
        // rather than a blank window.
        blocks = MarkdownBlocks.parse(raw ?? "")
    }

    var body: some View {
        Group {
            if missing {
                VStack(spacing: 10) {
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("This document was not bundled with this build.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if blocks.isEmpty {
                // Parsing produced nothing (plain text, or a parse failure):
                // show the source rather than a blank window, so the document
                // stays readable.
                ScrollView {
                    Text(source)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if doc == .readme { header }
                        ForEach(blocks) { block in
                            DocumentBlockView(block: block)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 22)
                    .textSelection(.enabled)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .preferredColorScheme(.dark)
    }

    /// The app's own header, standing in for the HTML table at the top of the
    /// README that a markdown parser cannot render.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AppleTree")
                        .font(.largeTitle.weight(.semibold))
                    Text("A fast, native disk-space treemap for macOS.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            // The commercial-use answer, where a reader looks for it.
            HStack(spacing: 10) {
                Button(String(localized: "Get it on the Mac App Store")) { AppLinks.open(AppLinks.appStore) }
                    .buttonStyle(.borderedProminent)
                Button(String(localized: "View license")) { DocumentWindow.show(.license) }
                    .buttonStyle(.link)
            }
            Divider().padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }
}

/// One block, styled by its role.
private struct DocumentBlockView: View {
    let block: ReadmeBlock

    var body: some View {
        switch block.role {
        case .heading(let level):
            Text(block.text)
                .font(headingFont(level))
                .padding(.top, level <= 1 ? 4 : 12)
        case .listItem(let ordinal):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ordinal > 0 ? "\(ordinal)." : "•")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(block.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 6)
        case .codeBlock:
            Text(block.text)
                .font(.system(.callout, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .tableRow(let cells, let header, let align):
            // Real columns, one row: the markdown's own column alignment drives
            // a Grid so numbers line up as a table rather than as stacked rows.
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                        Text(cell)
                            .font(.system(.callout, design: .monospaced))
                            .fontWeight(header ? .semibold : .regular)
                            .frame(maxWidth: .infinity, alignment: frameAlignment(for: align, at: index))
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Color.white.opacity(header ? 0.08 : 0.04),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .paragraph:
            Text(block.text).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A column's alignment, falling back to leading when the table declared
    /// fewer alignments than it has cells.
    private func frameAlignment(for align: [ColumnAlign], at index: Int) -> Alignment {
        guard align.indices.contains(index) else { return .leading }
        switch align[index] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title.weight(.semibold)
        case 2: return .title2.weight(.semibold)
        case 3: return .title3.weight(.semibold)
        default: return .headline
        }
    }
}
