import AppKit
import SwiftUI

/// The treemap canvas: cushion-shaded rects rendered once into a bitmap per
/// layout change; hover/selection drawn as a light overlay per frame, and a
/// mouse move redraws only the few rects whose overlay changed.
final class TreemapNSView: NSView {
    var model: ScanModel? {
        // SwiftUI hands the same model back on every update; only a new one
        // needs a render (the rest goes through relayoutIfNeeded).
        didSet { if model !== oldValue { relayout() } }
    }

    /// Folders a plan would remove: lit while the rest dims.
    var highlights: [Int] = [] { didSet { if highlights != oldValue { litRects = nil } } }
    /// Their rects in the current layout, found once per change, not per frame.
    private var litRects: [CGRect]?
    private var rects: [TMRect] = []
    private var leaves: [TMRect] = [] // files only, for hit-testing
    /// `strip` is the title bar (text + hit target); `region` is the whole
    /// directory rect (hover boundary). Both in view points.
    private var labels: [TMLabel] = []
    /// Label text laid out once per render, not on every frame.
    private var labelText: [LabelText] = []
    private var labelHits: [(rect: CGRect, node: Int)] = []
    private var bitmap: CGImage?
    private var lastSize: CGSize = .zero
    private var lastRoot: Int = -1
    private var lastTreeID: ObjectIdentifier?
    private var lastRevision = -1
    private var lastShowFree = false

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        relayoutIfNeeded()
    }

    func relayoutIfNeeded() {
        guard let model, let tree = model.tree else { return }
        let treeID = ObjectIdentifier(tree)
        // `treeRevision` too: an in-place removal keeps the same `Tree` object,
        // so identity alone would never tell this view the sizes changed.
        if bounds.size != lastSize || model.viewRoot != lastRoot || treeID != lastTreeID
            || model.treeRevision != lastRevision
            || model.showFreeSpace != lastShowFree {
            relayout()
        }
    }

    func relayout() {
        guard let model, let tree = model.tree, bounds.width > 4, bounds.height > 4 else {
            rects = []; leaves = []; labels = []; labelText = []; labelHits = []
            hoveredLabel = nil; litRects = nil; bitmap = nil
            lastSize = .zero
            resetLookups()
            needsDisplay = true
            return
        }
        lastSize = bounds.size
        lastRoot = model.viewRoot
        lastTreeID = ObjectIdentifier(tree)
        lastRevision = model.treeRevision
        lastShowFree = model.showFreeSpace

        rects.removeAll(keepingCapacity: true)
        leaves.removeAll(keepingCapacity: true)
        labels.removeAll(keepingCapacity: true)
        renderBitmap(tree: tree)
        // Everything redraws, so the overlay simply starts from the model
        // (a zoom clears the selection, a rescan the hover).
        hoveredNode = model.hovered
        shown = Overlay(hovered: hoveredNode, label: hoveredLabel,
                        picked: model.picks.members, primary: model.picks.primary)
        needsDisplay = true
    }

    private func renderBitmap(tree: Tree) {
        let scale = window?.backingScaleFactor ?? 2
        let pw = max(1, Int((bounds.width * scale).rounded()))
        let ph = max(1, Int((bounds.height * scale).rounded()))
        let r = TreemapRenderer.render(
            tree: tree, pw: pw, ph: ph, scale: scale, root: model?.viewRoot ?? 0,
            showFree: model?.showFreeSpace ?? false, freeBytes: model?.freeBytes ?? 0
        )
        if ProcessInfo.processInfo.environment["BZ_TIMING"] != nil {
            NSLog("BZ render %dx%d: %d steps, layout %.1f ms, paint %.1f ms (%d bands)",
                  pw, ph, r.steps, r.layoutMs, r.paintMs, r.bands)
        }
        rects = r.rects
        leaves = r.leaves
        litRects = nil
        labels = r.labels
        bitmap = r.image
        resetLookups()
        labelText = labels.map { LabelText($0, tree: tree, freeBytes: model?.freeBytes ?? 0) }
        labelHits = Scan.hits(labels)
    }

    /// A label's strings and their sizes in the resting (unhovered) look.
    private struct LabelText {
        var name: NSAttributedString, nameHeight: CGFloat, nameWidth: CGFloat = 0
        var size: NSAttributedString?, sizeSize: CGSize = .zero
        /// Where a free-space tag's text may paint (it floats unclipped).
        var bounds: CGRect

        init(_ label: TMLabel, tree: Tree, freeBytes: UInt64) {
            if label.node < 0 {
                // Free-space keeps a small floating tag (it has no frame).
                let text = label.region.width > 130
                    ? String(localized: "Free space  ·  \(Fmt.size(freeBytes))") : String(localized: "Free space")
                name = NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.55),
                ])
                let s = name.size()
                nameHeight = s.height
                bounds = CGRect(x: label.region.minX + 8, y: label.region.minY + 6,
                                width: s.width, height: s.height).insetBy(dx: -2, dy: -2)
                return
            }
            name = Self.name(label, hovered: false)
            let ns = name.size()
            (nameWidth, nameHeight) = (ns.width, ns.height)
            if label.strip.width > 175 {
                let s = Self.size(label, tree: tree, hovered: false)
                size = s
                sizeSize = s.size()
            }
            bounds = label.strip.insetBy(dx: -2, dy: -2)
        }

        static func name(_ label: TMLabel, hovered: Bool) -> NSAttributedString {
            NSAttributedString(string: label.name, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(hovered ? 1.0 : 0.92),
            ])
        }

        static func size(_ label: TMLabel, tree: Tree, hovered: Bool) -> NSAttributedString {
            NSAttributedString(string: Fmt.size(tree.alloc[label.node]), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(hovered ? 0.95 : 0.60),
            ])
        }
    }

    // ---- Overlay state ----

    /// What the overlay shows. It changes only through `syncOverlay()`,
    /// which invalidates exactly the areas that look different, so a
    /// partial redraw never mixes two states.
    private struct Overlay: Equatable {
        var hovered: Int?, label: Int?
        /// Every picked node, and which of them leads.
        ///
        /// A set rather than the one optional this used to be: the map rings
        /// the whole selection, and the primary is stroked thicker so the item
        /// the breadcrumbs describe is identifiable at a glance.
        var picked: [Int] = [], primary: Int?
    }
    private var shown = Overlay()
    private var hoveredLabel: Int? = nil
    /// `model.hovered` as this view last set it. Read instead of the model
    /// so `updateNSView` doesn't subscribe SwiftUI to every hover change.
    private var hoveredNode: Int? = nil

    /// Catch the overlay up with the model (hover, hovered label, selection)
    /// and queue redraws of just what changed (returned for the bench).
    @discardableResult
    func syncOverlay() -> [CGRect] {
        let now = Overlay(hovered: hoveredNode, label: hoveredLabel,
                          picked: model?.picks.members ?? [], primary: model?.picks.primary)
        guard now != shown else { return [] }
        let dirty = dirtyRects(from: shown, to: now)
        for r in dirty { setNeedsDisplay(r) }
        shown = now
        return dirty
    }

    /// Everything that looks different between two overlay states.
    private func dirtyRects(from a: Overlay, to b: Overlay) -> [CGRect] {
        var out: [CGRect] = []
        if a.hovered != b.hovered {
            for h in [a.hovered, b.hovered] {
                guard let h, let r = hoverRects(h) else { continue }
                out += ring(r.leaf, outside: 1, inside: 2)
                if let p = r.parent { out += ring(p, outside: 1, inside: 2) }
            }
        }
        if a.label != b.label {
            for l in [a.label, b.label] {
                guard let l, let i = Scan.label(labels, l) else { continue }
                // The halo straddles region.insetBy(2): 3.5 pt either side.
                out += ring(labels[i].region, outside: 2.5, inside: 6.5)
                out.append(labels[i].strip.insetBy(dx: -1, dy: -1))
            }
        }
        if a.picked != b.picked || a.primary != b.primary {
            // The SYMMETRIC DIFFERENCE, plus the two primaries: only nodes whose
            // ring appearance actually changed are repainted, so adding one item
            // to a 40-item selection redraws two rings rather than forty. The
            // primaries are included unconditionally because a changed primary
            // alters the thickness of a node that may be in both sets.
            let before = Set(a.picked), after = Set(b.picked)
            var changed = before.symmetricDifference(after)
            for p in [a.primary, b.primary] { if let p { changed.insert(p) } }
            for node in changed {
                guard let r = dirRect(node) else { continue }
                out += ring(r, outside: 1, inside: 3)
            }
        }
        return out
    }

    /// The four edge bands of `r`, `outside` beyond it to `inside` within.
    private func ring(_ r: CGRect, outside o: CGFloat, inside i: CGFloat) -> [CGRect] {
        let outer = r.insetBy(dx: -o, dy: -o)
        guard r.width > 2 * i, r.height > 2 * i else { return [outer] }
        return [
            CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: o + i),
            CGRect(x: outer.minX, y: r.maxY - i, width: outer.width, height: o + i),
            CGRect(x: outer.minX, y: outer.minY, width: o + i, height: outer.height),
            CGRect(x: r.maxX - i, y: outer.minY, width: o + i, height: outer.height),
        ]
    }

    // ---- Lookups (one scan per change, not per frame or mouse move) ----

    private var leafMemo: (node: Int, rects: (leaf: CGRect, parent: CGRect?)?)?
    private var dirMemo: [Int: CGRect?] = [:]
    /// Built on the first hit test after a render, not on every resize.
    private var leafIndex: TMLeafIndex?
    /// Folder lookup for points with no file tile under them, built lazily on
    /// the first such test. Shares the grid idea with `leafIndex`; see
    /// `TMDirIndex` for why both exist and why both callers use them.
    private var dirIndex: TMDirIndex?
    /// Every directory rect keyed by node, built on the first rect lookup
    /// after a render. `Scan.dir` walked all rects per lookup, and hover and
    /// selection redraws ask for rects every frame — one O(dirs) build buys
    /// O(1) answers afterwards. Directories only: files stay in the spatial
    /// `leafIndex`, and a per-file map would duplicate `leaves` (megabytes
    /// on million-file scans) for queries a point hit-test already answers.
    private var dirRects: [Int: CGRect]?

    private func resetLookups() {
        leafMemo = nil
        dirMemo = [:]
        leafIndex = nil
        dirIndex = nil
        dirRects = nil
        frameBandsCache = nil
    }

    /// The hovered file's rect and its parent directory's, if on screen.
    ///
    /// Files only: a directory's focus is already shown by the accent
    /// selection ring (`shown.selection` → `dirRect`), and a hovered label by
    /// its own halo, so outlining the whole folder here would just add a
    /// second, noisier box around the one that is already lit.
    private func hoverRects(_ node: Int) -> (leaf: CGRect, parent: CGRect?)? {
        if let m = leafMemo, m.node == node { return m.rects }
        guard let tree = model?.tree, !tree.isDir(node) else { return nil }
        guard let leaf = leafRect(node) else { return nil }
        return remember((leaf, dirRect(Int(tree.parents[node]))), node: node)
    }

    @discardableResult
    private func remember(_ rects: (leaf: CGRect, parent: CGRect?), node: Int) -> (leaf: CGRect, parent: CGRect?)? {
        leafMemo = (node, rects)
        return rects
    }

    /// A file's on-screen rect, or nil when off-screen. Point hit-tests keep
    /// using the spatial `leafIndex`; this map serves `hoverRects`, which
    /// needs a rect for a node the cursor may not be over (e.g. keyboard
    /// focus landing on a file at a screen edge). Linear is fine: `leaves`
    /// holds only tiles drawn on screen, bounded by window size — not by
    /// scan size — so it stays small even on million-file scans.
    private func leafRect(_ node: Int) -> CGRect? {
        for l in leaves where l.node == node { return l.rect }
        return nil
    }

    /// A folder's rect, or for the selection any node's (see `Tree.drawn`).
    private func dirRect(_ node: Int) -> CGRect? {
        if let r = dirMemo[node] { return r }
        let map = ensureDirRects()
        let r = map[node] ?? model?.tree.flatMap { tree in
            tree.isDir(node) ? tree.drawn(node) { map[$0] != nil }.flatMap { map[$0] }
                : leafRect(node)
        }
        // Evict one entry, not the whole map: a hover frame redraws two
        // nodes (file + parent) repeatedly, and a full clear would thrash
        // the same handful of keys every frame.
        if dirMemo.count > 64 { dirMemo.removeValue(forKey: dirMemo.first!.key) }
        dirMemo[node] = r
        return r
    }

    /// Node → rect for every drawn directory, built once per render. The
    /// previous `Scan.dir` walk touched all rects per lookup, and one hover
    /// frame could repeat that for several ancestors.
    private func ensureDirRects() -> [Int: CGRect] {
        if let map = dirRects { return map }
        var map: [Int: CGRect] = [:]
        map.reserveCapacity(rects.count)
        for r in rects where r.isDir { map[r.node] = r.rect }
        dirRects = map
        return map
    }

    // ---- Drawing ----

    override func draw(_ dirtyRect: NSRect) {
        // Redraw only what was invalidated: a mouse move damages a few thin
        // strips, and blitting the whole bitmap (25 MB on a big Retina
        // window) plus every label was most of each hover frame.
        var damaged: UnsafePointer<NSRect>?
        var n = 0
        getRectsBeingDrawn(&damaged, count: &n)
        let dirty = n > 0 && damaged != nil ? Array(UnsafeBufferPointer(start: damaged, count: n)) : [dirtyRect]
        func needs(_ r: CGRect) -> Bool { Scan.intersects(dirty, r) }

        if let bitmap {
            let full = CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height)
            let sx = CGFloat(bitmap.width) / bounds.width, sy = CGFloat(bitmap.height) / bounds.height
            for r in dirty {
                let px = CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy)
                    .integral.intersection(full)
                guard !px.isEmpty, let part = px == full ? bitmap : bitmap.cropping(to: px) else { continue }
                let dst = CGRect(x: px.minX / sx, y: px.minY / sy, width: px.width / sx, height: px.height / sy)
                NSImage(cgImage: part, size: dst.size).draw(
                    in: dst, from: .zero, operation: .copy, fraction: 1,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.none.rawValue]
                )
            }
        }

        guard let model, let tree = model.tree else { return }

        // Label hover boundary FIRST, so strip text always renders above it.
        if let hl = shown.label, let i = Scan.label(labels, hl), case let lab = labels[i],
           needs(lab.region.insetBy(dx: -3, dy: -3)) {
            let rr = lab.region.insetBy(dx: 2, dy: 2)
            let halo = NSBezierPath(rect: rr)
            halo.lineWidth = 7
            NSColor.black.withAlphaComponent(0.55).setStroke()
            halo.stroke()
            let line = NSBezierPath(rect: rr)
            line.lineWidth = 2.5
            NSColor.white.setStroke()
            line.stroke()
        }

        // Title-strip labels: text lives on the directory's frame, never on
        // top of its contents.
        for (label, text) in zip(labels, labelText) where needs(text.bounds) {
            if label.node < 0 {
                text.name.draw(at: CGPoint(x: label.region.minX + 8, y: label.region.minY + 6))
                continue
            }

            let strip = label.strip
            let hovered = label.node == shown.label
            if hovered {
                NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
                NSBezierPath(rect: strip).fill()
            }
            let nameStr = hovered ? LabelText.name(label, hovered: true) : text.name
            var avail = strip.width - 12
            if strip.width > 175 {
                // right-aligned size on roomy strips
                let sizeStr = hovered ? LabelText.size(label, tree: tree, hovered: true) : text.size!
                let sw = hovered ? sizeStr.size() : text.sizeSize
                sizeStr.draw(at: CGPoint(x: strip.maxX - sw.width - 6,
                                         y: strip.midY - sw.height / 2))
                avail -= sw.width + 10
            }
            let nh = text.nameHeight
            if text.nameWidth <= avail {
                // Fits: skip the truncating typesetter (same glyphs, far cheaper).
                nameStr.draw(at: CGPoint(x: strip.minX + 6, y: strip.midY - nh / 2))
            } else {
                nameStr.draw(
                    with: CGRect(x: strip.minX + 6, y: strip.midY - nh / 2,
                                 width: max(0, avail), height: nh),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                )
            }
        }

        // Hover: outline the file and its parent directory.
        if let h = shown.hovered, let r = hoverRects(h) {
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let p = NSBezierPath(rect: r.leaf.insetBy(dx: 0.5, dy: 0.5))
            p.lineWidth = 1
            p.stroke()
            if let pr = r.parent {
                NSColor.white.withAlphaComponent(0.35).setStroke()
                let pp = NSBezierPath(rect: pr.insetBy(dx: 0.5, dy: 0.5))
                pp.lineWidth = 1
                pp.stroke()
            }
        }
        if !highlights.isEmpty {
            // The dirs map is cached with `litRects`, so a highlights change
            // (the didSet above) re-runs only this filter, not an O(n) sweep
            // over every rect.
            if litRects == nil, let tree = model.tree {
                litRects = Scan.lit(rects, leaves, highlights, tree: tree,
                                    dirs: ensureDirRects())
            }
            let lit = litRects ?? []
            if !lit.isEmpty {
                let dim = NSBezierPath(rect: bounds)
                for r in lit { dim.append(NSBezierPath(rect: r)) }
                dim.windingRule = .evenOdd
                NSColor.black.withAlphaComponent(0.55).setFill()
                dim.fill()
                NSColor.controlAccentColor.setStroke()
                for r in lit {
                    let p = NSBezierPath(rect: r)
                    p.lineWidth = 1.5
                    p.stroke()
                }
            }
        }
        // Every picked node, with the primary stroked thicker. Drawn after the
        // dimming pass so a picked tile reads as chosen even while a plan
        // highlights a different area.
        //
        // The selected node's OWN shape only. The rings light a folder's whole
        // subtree because an arc is the folder and the things inside it are
        // separate arcs further out; the map already draws a folder as a framed
        // box holding its children, so outlining every nested rect as well
        // buried the picture under one blue outline per tile. The box says
        // "this folder and everything in it"; the rings need the extra pass
        // because their geometry does not imply containment.
        if !shown.picked.isEmpty {
            NSColor.controlAccentColor.setStroke()
            for node in shown.picked {
                guard let r = dirRect(node) else { continue }
                let p = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
                p.lineWidth = node == shown.primary ? 2.5 : 1.5
                p.stroke()
            }
        }
    }

    // ---- Interaction ----

    override var acceptsFirstResponder: Bool { true }

    /// Arrows should work the moment the window keys, without a prior
    /// click — otherwise the first keypress after opening or after focusing
    /// another control does nothing.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, window?.firstResponder != self {
            window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        let esc = event.keyCode == 53
        let cmdUp = event.modifierFlags.contains(.command) && event.keyCode == 126
        // Delete removes the selected node — Backspace or Forward Delete,
        // Shift for the permanent one. Before the arrow/Return handling so the
        // keys cannot be swallowed by a branch below.
        //
        // The SELECTION, not the hover: the treemap sets `model.hovered` on
        // every mouse move, so keying off the hover would make Delete name
        // whatever the pointer happened to rest on — for an irreversible
        // action that is the wrong item often enough to matter.
        if let kind = RemovalKeys.intent(for: event), let model, let tree = model.tree {
            NodeActions.remove(nodes: model.pickedNodes, kind: kind, tree: tree, model: model)
            return
        }
        // Cmd+A: everything this view draws, in reading order so the primary is
        // the visually last one. The map draws exactly one level, so "everything
        // drawn" IS the level — never recursive, which would tick millions of
        // nodes the user cannot see. That is the same definition the list and the
        // rings use (see `NodeOutlineView.keyDown`), which is why the three can
        // share one reduction and still each select what their own picture shows.
        if event.modifierFlags.contains(.command), event.keyCode == 0, let model {
            let all = readingOrder()
            guard !all.isEmpty else { return }
            model.setSelection(all)
            syncOverlay()
            return
        }
        // Cmd-[ / Cmd-] walk the trail of folders visited. Handled here as well
        // as in the toolbar so the keys work whichever surface has the focus;
        // every surface calls the same two model methods.
        if event.modifierFlags.contains(.command), event.keyCode == 33 || event.keyCode == 30 {
            let moved = event.keyCode == 33 ? model?.goBack() == true : model?.goForward() == true
            if moved {
                // A trail step re-roots the map, so the layout is stale: the
                // same refresh a zoom does, with the local hover dropped since
                // it belonged to the folder being left.
                relayout()
                hoveredNode = model?.hovered
                hoveredLabel = nil
                syncOverlay()
                return
            }
        }
        if esc || cmdUp {
            // Cmd-Up steps out of what is focused — the enclosing folder of a
            // small tile, which no click can reach — and zooms out once the
            // focus is already the folder on screen. Escape stays plain
            // zoom-out, so the older gesture keeps its old meaning.
            let climbed = !esc && model?.selectEnclosingFolder() == true
            if climbed {
                // Order matters: `relayout` (run when the view re-rooted)
                // resets `hoveredNode` from the model, so the local focus is
                // taken *after* it, then the overlay redraws just what moved.
                relayoutIfNeeded()
                hoveredNode = model?.hovered
                hoveredLabel = nil
                if let node = hoveredNode, let tree = model?.tree {
                    toolTip = "\(tree.displayPath(node))\n\(Fmt.size(tree.alloc[node]))"
                }
                syncOverlay()
            } else if let model, let tree = model.tree, model.viewRoot != 0 {
                let p = Int(tree.parents[model.viewRoot])
                model.navigate(to: p == Int(UInt32.max) ? 0 : p)
                relayout()
            }
        } else if 123...126 ~= event.keyCode, !event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.option) {
            // Arrow keys move focus spatially: 123 left, 124 right,
            // 125 down, 126 up. Pure geometry, no a11y work.
            keyboardMove(keyCode: event.keyCode)
        } else if event.keyCode == 36 || event.keyCode == 76 {
            keyboardZoomIn()
        } else {
            super.keyDown(with: event)
        }
    }

    /// On-screen rect for any node: files via `leafRect`, dirs via `dirRect`.
    private func rect(for node: Int) -> CGRect? {
        guard let tree = model?.tree else { return nil }
        return tree.isDir(node) ? dirRect(node) : leafRect(node)
    }

    /// Step hover/selection to the nearest tile in the pressed direction.
    /// Anchor is the current focus — hover if set, else selection, else the
    /// view root — so arrow keys and the mouse never fight: whichever the
    /// user moved last stays the anchor until they touch the other device.
    private func keyboardMove(keyCode: UInt16) {
        guard let model, let tree = model.tree, !rects.isEmpty else { return }
        let dir: CGPoint
        switch keyCode {
        case 123: dir = CGPoint(x: -1, y: 0)
        case 124: dir = CGPoint(x: 1, y: 0)
        case 125: dir = CGPoint(x: 0, y: 1)
        default: dir = CGPoint(x: 0, y: -1) // 126
        }

        // Anchor point: hover first, then selection, then the root tile.
        var anchorNode = model.hovered ?? model.selection ?? model.viewRoot
        // Resolve the anchor to a screen rect (file or dir). Root (node 0)
        // has no tile of its own; zoomed-out ancestors may be off-screen,
        // so climb to the first drawn ancestor or fall back to the root tile.
        var anchor = anchorNode == 0 ? nil : rect(for: anchorNode)
        while anchor == nil, anchorNode != 0 {
            anchorNode = Int(tree.parents[anchorNode])
            anchor = anchorNode == 0 ? rects.first?.rect : rect(for: anchorNode)
        }
        guard let from = anchor ?? rects.first?.rect else { return }
        keyboardFocus(from: CGPoint(x: from.midX, y: from.midY), direction: dir, tree: tree, model: model)
    }

    /// Pick the tile whose center best combines forward progress along
    /// `direction` with closeness to the anchor's perpendicular line.
    private func keyboardFocus(from origin: CGPoint, direction: CGPoint, tree: Tree, model: ScanModel) {
        // Score every on-screen tile: projection along the direction minus
        // the perpendicular offset, normalized by view size. Files and dirs
        // compete together; the best tile wins.
        let w = max(1, bounds.width), h = max(1, bounds.height)
        var best: (node: Int, score: CGFloat)?
        func consider(_ r: TMRect) {
            let dx = r.rect.midX - origin.x, dy = r.rect.midY - origin.y
            let along = dx * direction.x + dy * direction.y
            guard along > 1 else { return } // must actually move somewhere
            let side = abs(dx * direction.y - dy * direction.x)
            let score = along / w - side / max(w, h)
            if best == nil || score > best!.score { best = (r.node, score) }
        }
        for r in rects { consider(r) }
        // Files need their parent dir drawn to be on screen.
        let dirs = ensureDirRects()
        for l in leaves where dirs[Int(tree.parents[l.node])] != nil { consider(l) }
        guard let winner = best?.node else { return }
        // Keyboard focus has no pointer on a strip, so drop any label halo
        // the mouse left behind before this focus takes over.
        hoveredLabel = nil
        focus(winner, tree: tree, model: model)
        // Keep the newly focused tile on screen if it scrolled out.
        if let r = rect(for: winner), !bounds.contains(r) {
            // Walk up to the smallest drawn ancestor that contains it.
            var p = Int(tree.parents[winner])
            while p != Int(UInt32.max), dirRect(p) == nil { p = Int(tree.parents[p]) }
            if p != Int(UInt32.max), p != model.viewRoot, tree.isDir(p) {
                // Focus mechanics, not a visit: the arrow key asked to move the
                // focus, and re-rooting is only how the map keeps it visible.
                // Recording it would make "back" retrace the focus.
                model.rootForFocus(on: p)
                relayout()
            }
        }
    }

    /// Make `node` the focus: the model's hover and selection, this view's own
    /// hover state, the tooltip and the overlay.
    ///
    /// One owner for all of it, because the overlay reads this view's
    /// `hoveredNode` rather than the model's — a site that set only
    /// `model.hovered` drew no outline (the keyboard bug fixed in 0c4ae1d).
    /// Click, right-click and the keyboard all come through here now, so a
    /// new one cannot reintroduce that split.
    ///
    /// The label halo is only dropped when it belongs to a different node:
    /// clicking a title strip keeps it (the pointer really is on that strip),
    /// while keyboard focus clears it, since there is no pointer there.
    /// `nil` clears the focus: clicking empty space means "nothing picked".
    /// One owner for the focused node, so a clearing click and a picking click
    /// cannot leave the overlay in different states.
    private func focus(_ node: Int?, tree: Tree, model: ScanModel) {
        guard let node else {
            model.selection = nil
            hoveredNode = nil
            hoveredLabel = nil
            toolTip = nil
            syncOverlay()
            return
        }
        focusNode(node, tree: tree, model: model)
    }

    private func focusNode(_ node: Int, tree: Tree, model: ScanModel) {
        model.hovered = node
        model.selection = node
        hoveredNode = node
        if hoveredLabel != node { hoveredLabel = nil }
        toolTip = "\(tree.displayPath(node))\n\(Fmt.size(tree.alloc[node]))"
        syncOverlay()
    }

    /// Return zooms into the focused directory. On a file there is nothing
    /// to zoom into — keyboard move already selected it — so this no-ops.
    private func keyboardZoomIn() {
        guard let model, let tree = model.tree else { return }
        let target = model.hovered ?? model.selection ?? model.viewRoot
        guard target != 0, tree.isDir(target) else { return }
        // Zoom to the focused dir itself when drawn, else to the nearest
        // drawn ancestor (e.g. focus came from a label strip).
        var p = target
        while p != 0, dirRect(p) == nil { p = Int(tree.parents[p]) }
        guard p != 0 || dirRect(0) != nil else { return }
        if p != model.viewRoot {
            model.navigate(to: p)
            relayout()
        }
    }

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private func hit(_ point: CGPoint) -> TMRect? {
        // Files are disjoint; smallest matching leaf wins.
        if leafIndex == nil { leafIndex = TMLeafIndex(leaves: leaves, size: lastSize) }
        return leafIndex!.hit(point, leaves: leaves)
    }

    /// Superseded by `folder(at:)` and `TMDirIndex`, which answer the same
    /// question from a grid cell instead of scanning every rect — and which the
    /// HOVER path can therefore afford to call too. The comment this replaces
    /// said "one pass per click, never per frame"; that was exactly why hover
    /// could not use it, and why hover came to disagree with click about a
    /// folder's own border. Retired rather than kept: two lookups answering one
    /// question is how the two drifted apart in the first place.

    /// What a click at `point` picks, in paint order: a title strip (it paints
    /// above its own folder), then the same resolver `hover(at:)` uses.
    ///
    /// **`resolve` is the single owner of "which node is under this point".**
    /// This function used to have its own frame lookup — `frame(at:)`, a
    /// first-match linear scan over every rect — while `hover` walked the
    /// tile's ancestry through `frameBands()`. The two orders disagreed wherever
    /// an unheaded folder's box sits exactly on a child folder's box: measured
    /// on such a fixture, 3,192 of 281,600 sampled points gave `pick = 1` and
    /// `hover = 6`, so the user clicked one folder while the highlight and ⌘↑
    /// named a different one (audit UI-1). Two owners of one question is the
    /// whole bug; the resolver is O(depth) and already handles the no-tile case.
    ///
    /// Internal, like `hover(at:)`, so the click geometry is exercised
    /// directly instead of through a synthesized event.
    func pick(at point: CGPoint, slop: CGFloat = 0) -> Int? {
        if let lab = Scan.hit(labelHits, point, slop: slop) { return lab }
        return resolve(point, leaf: hit(point))
    }

    override func mouseMoved(with event: NSEvent) {
        hover(at: convert(event.locationInWindow, from: nil))
    }

    @discardableResult
    func hover(at p: CGPoint) -> [CGRect] {
        let lab = Scan.hit(labelHits, p)
        hoveredLabel = lab
        // One resolver, shared with `pick`: a point's node must not depend on
        // which of the two asked. It used to be `lab ?? leaf?.node` — files only
        // — on the premise that a directory's focus is already shown by its
        // accent ring. That premise holds only for a folder wide enough to earn
        // a title strip: a narrower one has no label, and its separation frame is
        // the only pixel that is visibly the folder's, so hovering that border
        // focused a file INSIDE it (or nothing at all, where no file sits under
        // the frame) while clicking it selected the folder. ⌘↑ ("select the
        // folder holding the focused item") then climbed from the wrong node on
        // precisely the tile that has no other handle.
        let leaf = lab == nil ? hit(p) : nil
        let node = lab ?? resolve(p, leaf: leaf)
        if let leaf, leafMemo?.node != leaf.node {
            // Saves the lookup when drawing; the parent dir rect resolves
            // through the cached dirs map inside `dirRect`.
            remember((leaf.rect, dirRect(Int(model?.tree?.parents[leaf.node] ?? 0))), node: leaf.node)
        }
        if node != hoveredNode {
            hoveredNode = node
            model?.hovered = node
            if let node, let tree = model?.tree {
                toolTip = "\(tree.displayPath(node))\n\(Fmt.size(tree.alloc[node]))"
            } else {
                toolTip = nil
            }
        }
        return syncOverlay()
    }

    /// The node at `p` when no title strip covers it: the same answer `pick`
    /// gives, because the two must not disagree.
    ///
    /// Order mirrors `pick` exactly — a folder's separation frame (painted over
    /// the children), then the file tile, then the folder box underneath. The
    /// frame is resolved through the leaf's ancestry (O(depth), so the
    /// mouse-move path never scans every rect) and falls back to the indexed
    /// folder lookup when no file sits under the point at all.
    private func resolve(_ p: CGPoint, leaf: TMRect?) -> Int? {
        guard let tree = model?.tree else { return leaf?.node }
        if let leaf {
            // The frame belongs to an ancestor of the tile under the pointer.
            let bands = frameBands()
            var framed: Int?
            for candidate in tree.ancestry(leaf.node).dropLast() {
                guard let band = bands[candidate], band > 0,
                      let box = ensureDirRects()[candidate], box.contains(p)
                else { continue }
                if !box.insetBy(dx: band, dy: band).contains(p) { framed = candidate }
            }
            if let framed { return framed }
            return leaf.node
        }
        // No file tile here: the point is on a folder's own border, or in the
        // bare box of a folder whose children do not reach it.
        return folder(at: p)
    }

    /// The deepest drawn folder containing `p`, via the grid index.
    private func folder(at p: CGPoint) -> Int? {
        if dirIndex == nil { dirIndex = TMDirIndex(rects: rects, size: lastSize) }
        return dirIndex?.hit(p, rects: rects)?.node
    }

    /// Frame width per drawn folder, built once per render.
    ///
    /// `TMRect.band` is what `onFrame` reads, but a linear search of `rects` per
    /// ancestor per mouse move is the scan this avoids. One dictionary built
    /// alongside `dirRects` costs a single pass per layout change.
    private var frameBandsCache: [Int: CGFloat]?
    private func frameBands() -> [Int: CGFloat] {
        if let frameBandsCache { return frameBandsCache }
        var map: [Int: CGFloat] = [:]
        map.reserveCapacity(rects.count)
        for r in rects where r.isDir && r.band > 0 { map[r.node] = r.band }
        frameBandsCache = map
        return map
    }

    override func mouseExited(with event: NSEvent) {
        model?.hovered = nil
        hoveredNode = nil
        hoveredLabel = nil
        syncOverlay()
    }

    /// Every node the map draws at the level on screen, in the order it reads.
    ///
    /// A thin call into `TreemapRenderer.readingOrder`, which OWNS this rule
    /// because it is the code that decides what is drawn and at what depth. The
    /// view used to rebuild the list here from `rects + leaves + labels`, and
    /// because those arrays hold EVERY depth — `Layout.draw` recurses into a
    /// folder too small for a title strip — a Shift+range built as a slice of
    /// the result swept in grandchildren of a folder the user never pointed at.
    /// Ask the renderer for the level, rather than approximating its geometry
    /// from its output.
    ///
    /// No depth is passed in because the renderer's depth is already relative to
    /// the view root: it draws that root at 0 and its children at 1, so the level
    /// on screen is draw-depth 1 at every zoom.
    func readingOrder() -> [Int] {
        guard let model else { return [] }
        return TreemapRenderer.readingOrder(
            rects: rects, leaves: leaves, labels: labels, root: model.viewRoot
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard let model, let tree = model.tree else { return }
        if event.clickCount == 2 {
            // A folder label or tile zooms into it; a file into its parent.
            // The 2 pt slop only for the double-click: a strip's text can sit
            // a hair outside its bar, and zoom is where that last came from.
            guard let node = pick(at: p, slop: 2) else { return }
            let target = tree.isDir(node) ? node : Int(tree.parents[node])
            if target != Int(UInt32.max), tree.isDir(target), target != model.viewRoot {
                model.navigate(to: target)
                relayout()
            }
        } else {
            // Any tile is selectable, folders included: without this a folder
            // drawn as a solid block picked nothing, which also left "move to
            // the folder holding this" with no focus to climb from.
            guard let node = pick(at: p), node != model.viewRoot else {
                // Empty space: a plain click clears, but a modified click is an
                // additive gesture and clearing on it would throw away the
                // selection the user is in the middle of building.
                //
                // `node != model.viewRoot` is what makes this branch reachable at
                // all. `pick` ends in `folder(at:)`, which returns the deepest
                // drawn folder containing the point, and the view root is drawn
                // as the window-wide box — so ANY pixel not covered by a child
                // resolves to the root, and `pick` never returns nil. Measured
                // over a 300×200 canvas: 0 of 239,001 points returned nil, and on
                // a fixture with real holes 728 points resolved to node 0 (audit
                // UI-4). The whole-disk root was being selected by a click the
                // documentation calls "clears the selection", and `crumbPath`
                // then re-anchored on it.
                //
                // Treating the view root as empty space is the same rule
                // `extendSelection` below already applies, which is what the
                // comment there describes.
                if event.modifierFlags.intersection([.command, .shift]).isEmpty {
                    focus(nil, tree: tree, model: model)
                }
                return
            }
            switch SelectionSet.ClickIntent(event) {
            case .toggle:
                // ⌘+click: add, or remove when already picked. A hover is not
                // moved here — the hover follows the pointer, and the selection
                // is what the ring shows.
                model.toggleSelection(node)
            case .extend:
                // ⇧+click, and ⌘⇧+click, extend the selection to a FOLDER.
                //
                // The range is expressed in folders, because a folder stands for
                // everything inside it: shift-clicking a file means "extend to the
                // folder holding it", which is what the selection can actually
                // say. (A file's own tile cannot be a range endpoint — the
                // antichain rule would drop it the moment its folder is included,
                // so a file endpoint produced a range that silently collapsed.)
                //
                // A click that lands on a GAP resolves to the folder being viewed
                // (the root). That is not a folder the user can select — it is the
                // map itself — so the gesture does nothing rather than quietly
                // selecting the scan root and replacing the anchor, which is what
                // made shift+click "act weird": the next shift+click then ranged
                // from the wrong place.
                //
                // The whole gesture is `model.extendSelection`, which owns the
                // folder normalisation, the view-root refusal, the range and the
                // off-map anchor. The tail used to be copied here and in the
                // rings, which is how the two views drifted and how the off-map
                // branch came to describe the opposite of what it did.
                model.extendSelection(to: node, order: readingOrder())
            case .replace:
                focus(node, tree: tree, model: model)
            }
            syncOverlay()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard let model, let tree = model.tree, let node = pick(at: p) else { return }
        // Right-clicking a tile INSIDE the selection keeps the whole selection —
        // the user sees several ringed and the menu is how they act on all of
        // them, so replacing it with this one node would silently discard the
        // rest before the menu even appeared. One outside is a deliberate change
        // of target, so it focuses that node alone.
        if !model.picks.covers(node, in: tree) {
            focus(node, tree: tree, model: model)
        } else {
            // The hover still follows the pointer: only the selection is kept.
            hoveredNode = node
            model.hovered = node
        }
        NodeMenu.popUp(node: node, tree: tree, model: model, with: event, for: self)
    }
}

/// Scans over the layout arrays, nonisolated on purpose: a closure written
/// in the MainActor view checks its executor on every call, which made one
/// pass over 40k directory rects cost milliseconds per mouse move.
nonisolated private enum Scan {
    /// Each node's rect: files from `leaves`, folders from `rects`, and a
    /// folder merged into its parent's "A ▸ B" box lights that box.
    static func lit(_ rects: [TMRect], _ leaves: [TMRect], _ nodes: [Int], tree: Tree, dirs: [Int: CGRect]) -> [CGRect] {
        let wanted = Set(nodes)
        var out = Set<Int>()
        var files: [CGRect] = []
        for node in wanted where tree.isDir(node) {
            if let shown = tree.drawn(node, isDrawn: { dirs[$0] != nil }) { out.insert(shown) }
        }
        if wanted.contains(where: { !tree.isDir($0) }) {
            files = leaves.filter { wanted.contains($0.node) }.map(\.rect)
        }
        // A box inside another lit one would be dimmed again by the even-odd fill.
        let all = out.compactMap { dirs[$0] } + files
        let outer = all.enumerated().filter { i, r in
            !all.enumerated().contains { j, o in j != i && o.contains(r) && (o != r || j < i) }
        }
        return outer.map { $0.element.insetBy(dx: 0.5, dy: 0.5) }
    }

    static func label(_ labels: [TMLabel], _ node: Int) -> Int? {
        labels.firstIndex { $0.node == node }
    }

    static func hits(_ labels: [TMLabel]) -> [(rect: CGRect, node: Int)] {
        labels.filter { $0.node >= 0 }.map { ($0.strip, $0.node) }
    }

    static func hit(_ hits: [(rect: CGRect, node: Int)], _ p: CGPoint, slop: CGFloat = 0) -> Int? {
        slop == 0 ? hits.first { $0.rect.contains(p) }?.node
            : hits.first { $0.rect.insetBy(dx: -slop, dy: -slop).contains(p) }?.node
    }

    static func intersects(_ rects: [CGRect], _ r: CGRect) -> Bool {
        rects.contains { $0.intersects(r) }
    }
}

/// How a node is removed, once the user has asked for it.
///
/// One vocabulary for both routes — the context menu and the Delete keys — so a
/// shortcut cannot mean something gentler or harsher than the menu row that
/// names it. Trash is reversible and permanent deletion is not, which is the
/// only difference that matters to `NodeActions.remove`.
enum RemovalKind {
    /// Move it to the Trash: the user can put it back until they empty it.
    case trash
    /// Delete it permanently: no Trash, no way back.
    case permanent
}

/// The node actions the context menu and the Delete keys share.
///
/// The shortest path from a node menu row to the thing it does. The two views
/// that catch the Delete keys and the menu that draws the rows both call this,
/// so "Move to Trash" and Delete cannot drift apart, and the irreversible
/// route cannot be reachable from one surface and not another.
@MainActor
enum NodeActions {
    /// Ask, then remove every node in `nodes` — the whole gesture, not just the
    /// confirmation.
    ///
    /// Callers pass the *selection*, never the hover. A hover is a passive
    /// pointer state the user never committed to: acting on it means a stray
    /// Delete while the mouse crosses the map names whatever happened to be
    /// underneath, and one Enter on the confirmation deletes it. The model's
    /// selection is the pick the user actually made — by click, by arrow key or
    /// by a list row — so the confirmation always describes something the screen
    /// already shows as chosen. An empty list does nothing.
    ///
    /// The paths are resolved and de-overlapped ONCE, before the dialog, so the
    /// count and byte total the user is shown are exactly the set that is acted
    /// on: recomputing them after the confirmation could describe a different
    /// batch if the tree changed while the modal was up.
    static func remove(nodes: [Int], kind: RemovalKind, tree: Tree, model: ScanModel) {
        // Node 0 is the scan itself — the whole disk or the chosen folder. The
        // engine refuses to detach it (nothing would be left to draw), so it is
        // filtered out here rather than failing into the void. Every other node
        // is dropped too when it is no longer attached: an in-place removal the
        // view has not caught up with leaves ids naming a detached subtree.
        let usable = nodes.filter { $0 != 0 && tree.isAttached($0) }
        if nodes.contains(0) { inform(String(localized: "Cannot remove the scan root")) }
        guard !usable.isEmpty else { return }

        // Defensive: the invariant already guarantees no member contains
        // another, so this is normally the identity. It is checked anyway
        // because the cost of being wrong is not symmetric — a nested pair would
        // move a folder and then report its child as a failure, having acted on
        // a path that no longer exists.
        let targets = SelectionSet.outermost(usable, in: tree)
        let items = targets.map { (node: $0, path: tree.path($0), name: tree.name($0)) }
        switch kind {
        case .trash: confirmAndTrash(items, model: model)
        case .permanent: confirmAndErase(items, model: model)
        }
    }

    /// What a batch confirmation names: how many items, and what they weigh.
    ///
    /// The count is of ITEMS, not folders: a multi-selection mixes files and
    /// folders, and "Move 3 folders to the Trash?" over three files would be
    /// plainly wrong. The total is the tree's own allocated bytes for the picked
    /// nodes — the same figure the map and the status bar show — so the dialog
    /// cannot disagree with the screen.
    private static func summary(_ items: [(node: Int, path: String, name: String)],
                                tree: Tree) -> (count: String, bytes: UInt64) {
        // `addingReportingOverflow`, because subtree totals are sums of sums: a
        // pathological tree (or an engine bug) that already overflowed one
        // folder's figure would trap the app here, in a dialog, instead of
        // showing a wrong-but-alive number. This is the one byte sum that runs
        // on a user gesture (audit UI-9).
        let total = items.reduce(UInt64(0)) { acc, item in
            let (sum, overflowed) = acc.addingReportingOverflow(tree.alloc[item.node])
            return overflowed ? UInt64.max : sum
        }
        // `String(items.count)`, not the Int itself: an Int interpolation builds
        // the key "%lld items", and the tables define "%@ items" — every
        // translation silently fell back to English. A String interpolation
        // produces "%@", which is the key that exists (and what the l10n checker
        // verifies, since it normalises every interpolation to "%@").
        let count = items.count == 1
            ? String(localized: "1 item")
            : String(localized: "\(String(items.count)) items")
        return (count, total)
    }

    /// Move to the Trash, after a confirmation naming the whole batch.
    ///
    /// Through `Trash.trash`, the one trash owner, so every surface reports a
    /// removal the same way. `.userDirect`, NOT the guard: the alert just
    /// answered is the authorization. The guard's "inside your home folder"
    /// rule belongs to README "## AI cleanup" — it bounds what a *planner* may
    /// nominate, because a planner writes a plan from a scan summary and
    /// AppleTree then acts on paths it never showed the user. Here the user
    /// selected specific items — or pressed Delete on the selection — and named
    /// them in this dialog, and the app's own scan targets are mostly outside
    /// `$HOME` (`/Applications`, a whole drive). Running the planner's policy
    /// here refused `/Applications/Java 8 Update 491.app` with "Outside your
    /// home folder" — a disk-space tool that cannot empty /Applications is not
    /// doing its job.
    ///
    /// What DOES still apply: a symlink is judged by where it lands (inside
    /// `Trash.trash`), and every failure is reported rather than swallowed.
    private static func confirmAndTrash(_ items: [(node: Int, path: String, name: String)],
                                       model: ScanModel) {
        guard let tree = model.tree else { return }
        let (count, bytes) = summary(items, tree: tree)
        let alert = NSAlert()
        if items.count == 1 {
            // One item keeps its exact name: "Move "Resources" to Trash?"
            // describes the one thing the user picked better than a count.
            alert.messageText = String(localized: "Move \u{201C}\(items[0].name)\u{201D} to Trash?")
            alert.informativeText = items[0].path
        } else {
            alert.messageText = String(localized: "Move \(count) to the Trash?")
            alert.informativeText = String(localized: "\(Fmt.size(bytes)) in \(count). You can put them back until you empty the Trash.")
        }
        alert.addButton(withTitle: String(localized: "Move to Trash"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let paths = items.map(\.path)
        Task { @MainActor in
            let outcomes = await Trash.trash(paths, authority: .userDirect)
            // Forget in place rather than rescanning: the engine cuts each
            // node's link where it sits, so every other id keeps its meaning and
            // the zoom, the selection and the size totals stay consistent.
            var failures: [String] = []
            for outcome in outcomes {
                if outcome.moved {
                    model.forgetPath(outcome.source)
                } else if outcome.reason == String(localized: "Already gone") {
                    // Nothing left on disk, so nothing to report — but the node
                    // still has to leave the map. Its path is gone, and the tree
                    // was built from an earlier scan, so the map would otherwise
                    // keep showing bytes that no longer exist and count them in
                    // every total. Forgetting is what makes the picture match
                    // the disk; there is no failure to name.
                    model.forgetPath(outcome.source)
                } else if let reason = outcome.reason {
                    failures.append("\((outcome.source as NSString).lastPathComponent): \(reason)")
                }
            }
            reportFailures(failures, title: String(localized: "Some folders couldn't be moved"))
        }
    }

    /// Delete permanently, after a confirmation that says so.
    ///
    /// The alert carries its own verb ("Delete Permanently", never "OK"): an
    /// irreversible step must not be confirmed by a button that reads as
    /// agreement to something else.
    private static func confirmAndErase(_ items: [(node: Int, path: String, name: String)],
                                        model: ScanModel) {
        guard let tree = model.tree else { return }
        let (count, bytes) = summary(items, tree: tree)
        let alert = NSAlert()
        alert.alertStyle = .warning
        if items.count == 1 {
            alert.messageText = String(localized: "Delete \u{201C}\(items[0].name)\u{201D} permanently?")
            alert.informativeText = String(localized: "It does not go to the Trash. This cannot be undone.")
        } else {
            alert.messageText = String(localized: "Delete \(count) permanently?")
            alert.informativeText = String(localized: "\(Fmt.size(bytes)) in \(count). This does not go to the Trash, and cannot be undone.")
        }
        alert.addButton(withTitle: String(localized: "Delete Permanently"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let paths = items.map(\.path)
        Task { @MainActor in
            var failures: [String] = []
            for path in paths {
                if let failure = await Erase.erase(path) {
                    failures.append("\((path as NSString).lastPathComponent): \(failure)")
                } else {
                    // Gone permanently, and forgotten the same in-place way as a
                    // trash, so the map, the list and the totals agree at once.
                    model.forgetPath(path)
                }
            }
            // Its own title: nothing was "moved" on this route, and a failure
            // notice that names the wrong gesture sends the user looking in the
            // Trash for something that never went there.
            reportFailures(failures, title: String(localized: "Some items couldn't be deleted"))
        }
    }

    /// Show why a removal did not happen, listing every failure.
    ///
    /// One dialog for the batch, not one per item: a user who selected 30 files
    /// and lost 3 to permissions needs the three named once, not 30 modals.
    /// `title` is passed in because the two routes fail differently — a Trash
    /// move that did not happen, a delete that did not.
    private static func reportFailures(_ failures: [String], title: String) {
        guard !failures.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        // Bounded so a 500-item failure cannot produce a dialog taller than the
        // screen; the count still tells the user the true scale.
        let shown = failures.prefix(12).joined(separator: "\n")
        alert.informativeText = failures.count > 12
            ? shown + "\n" + String(localized: "…and \(String(failures.count - 12)) more")
            : shown
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    /// A warning the user has to acknowledge, with no path to lead with.
    private static func inform(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}

/// The AppKit hook that reads a mouse click's modifiers into a `ClickIntent`.
///
/// Lives beside `RemovalKeys` rather than in `Selection.swift`, because that
/// file imports only Foundation so the selection algebra stays testable without
/// AppKit; this is the one place that must know about `NSEvent`. Both views call
/// it, so a second reading of the same flags cannot reintroduce the precedence
/// bug it exists to fix: the map and the rings used to test `.command` before
/// `.shift`, which made ⌘⇧+click toggle the item under the pointer instead of
/// extending a range to the folder holding it.
extension SelectionSet.ClickIntent {
    /// The selection gesture a click event asks for.
    init(_ event: NSEvent) {
        self.init(shift: event.modifierFlags.contains(.shift),
                  command: event.modifierFlags.contains(.command))
    }
}

/// The AppKit hook every surface that takes the Delete keys shares.
///
/// Delete and Backspace mean "remove what is selected", Shift with either means
/// "delete it permanently". One owner decides that, because the two key codes and
/// their shifted forms are easy to get subtly different in a second view: the
/// list, the map and the rings must read the same keystroke the same way.
enum RemovalKeys {
    /// The key codes AppKit sends for the two delete keys every Mac keyboard
    /// has: Backspace and Forward Delete.
    private static let backspace: UInt16 = 51
    private static let forwardDelete: UInt16 = 117

    /// Only the modifiers that express a *held intent* are read; the rest are
    /// hardware or keyboard state and must not veto the gesture:
    ///
    /// - `.function` is set for the arrow/function key row, and Forward Delete
    ///   reports it. On every Mac laptop Fn+Backspace *is* Forward Delete, so
    ///   refusing a flagged event would break the only way to reach that key
    ///   without a full-size keyboard.
    /// - `.numericPad` is set by the numeric keypad, which is not a modifier a
    ///   user means to combine here.
    /// - `.capsLock` is a sticky state: Delete must go on working while Caps
    ///   Lock is on, exactly as every other shortcut does.
    private static let intent: NSEvent.ModifierFlags = [.shift, .command, .option, .control]

    /// The removal the event asks for, or nil when it is not a delete key or a
    /// modifier that means something else is in play.
    ///
    /// Deliberately strict about the modifiers it does read: the set must be
    /// *exactly* Shift or nothing at all. Option-Delete on macOS deletes the
    /// word behind the caret and Command-Delete deletes a line, so treating any
    /// delete key with "Shift somewhere in the flags" as a removal would turn an
    /// editing gesture into an irreversible delete.
    static func intent(for event: NSEvent) -> RemovalKind? {
        guard event.keyCode == backspace || event.keyCode == forwardDelete else { return nil }
        switch event.modifierFlags.intersection(intent) {
        case []: return .trash
        case [.shift]: return .permanent
        default: return nil
        }
    }
}

/// Right-click menu for a file or folder, shared by the treemap, the rings
/// and the directory list.
///
/// Actions go through the node, not a copied path: "select the enclosing
/// folder" and both removal confirmations need the scan model, and every
/// surface that shows a node must offer the same menu (a right-click that
/// works in the map but not in the list reads as a bug).
final class NodeMenu: NSObject {
    private static let shared = NodeMenu()

    /// The menu for one node. Built by the one owner so the map, the rings
    /// and the list cannot offer different actions for the same item, and so
    /// an action list change lands everywhere at once.
    static func menu(node: Int, tree: Tree, model: ScanModel) -> NSMenu {
        let menu = NSMenu()
        let parent = Int(tree.parents[node])
        let canClimb = parent != Int(UInt32.max) && tree.isDir(parent)
        // Only node 0 has no parent, and removing it would delete the scan
        // root itself: the engine refuses it, so the rows say so instead of
        // offering an action that can only fail.
        let canRemove = node != 0

        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = shared
            item.representedObject = Context(node: node, tree: tree, model: model)
            item.isEnabled = enabled
            menu.addItem(item)
        }

        add(String(localized: "Reveal in Finder"), #selector(revealInFinder(_:)))
        add(String(localized: "Copy Path"), #selector(copyPath(_:)))
        menu.addItem(.separator())
        // The escape hatch for a tile too small to click: it moves the focus
        // to the folder that holds this node, which is then one click away.
        add(String(localized: "Select Enclosing Folder"), #selector(selectEnclosingFolder(_:)),
            enabled: canClimb)
        menu.addItem(.separator())
        add(String(localized: "Move to Trash"), #selector(moveToTrash(_:)), enabled: canRemove)
        // The irreversible one, below its reversible sibling and after a
        // separator of its own: it must not sit where a stray click on the row
        // above lands.
        menu.addItem(.separator())
        add(String(localized: "Delete Permanently"), #selector(deleteForGood(_:)), enabled: canRemove)
        return menu
    }

    static func popUp(node: Int, tree: Tree, model: ScanModel, with event: NSEvent, for view: NSView) {
        NSMenu.popUpContextMenu(menu(node: node, tree: tree, model: model), with: event, for: view)
    }

    /// Everything an action needs; carried per menu item so one shared
    /// `NodeMenu` instance serves every view and node.
    private struct Context {
        let node: Int
        let tree: Tree
        let model: ScanModel
    }

    private static func context(_ sender: NSMenuItem) -> Context? {
        sender.representedObject as? Context
    }

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        guard let c = Self.context(sender) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: c.tree.path(c.node))])
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        guard let c = Self.context(sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c.tree.path(c.node), forType: .string)
    }

    @objc private func selectEnclosingFolder(_ sender: NSMenuItem) {
        guard let c = Self.context(sender) else { return }
        c.model.selectEnclosingFolder(of: c.node)
    }

    @objc private func moveToTrash(_ sender: NSMenuItem) {
        guard let c = Self.context(sender) else { return }
        // The confirmation, the trash owner and the in-place forget all live
        // in `NodeActions`, because the Delete key runs the same gesture.
        targeted(c, kind: .trash)
    }

    @objc private func deleteForGood(_ sender: NSMenuItem) {
        guard let c = Self.context(sender) else { return }
        targeted(c, kind: .permanent)
    }

    /// What a menu row acts on: the whole selection when the clicked node is
    /// part of it, otherwise just the clicked node.
    ///
    /// Right-clicking inside a multi-selection must not silently act on one item
    /// — the user sees several ringed and the menu is the way to act on them.
    /// Right-clicking something *outside* it is a deliberate change of target,
    /// so it acts on that node alone rather than the previous selection.
    private func targeted(_ c: Context, kind: RemovalKind) {
        let nodes = c.model.picks.covers(c.node, in: c.tree) ? c.model.pickedNodes : [c.node]
        NodeActions.remove(nodes: nodes, kind: kind, tree: c.tree, model: c.model)
    }
}

struct TreemapView: NSViewRepresentable {
    let model: ScanModel

    func makeNSView(context: Context) -> TreemapNSView {
        let v = TreemapNSView()
        v.model = model
        return v
    }

    func updateNSView(_ view: TreemapNSView, context: Context) {
        view.model = model
        view.relayoutIfNeeded()
        view.syncOverlay() // e.g. a selection made in the list
        let lit = model.agentRun?.highlights(in: model.tree) ?? []
        if lit != view.highlights {
            view.highlights = lit
            view.needsDisplay = true
        }
    }
}
