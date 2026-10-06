import AppKit
import QuartzCore
import SwiftUI

/// One arc of the ring chart. Angles run clockwise from 12 o'clock.
nonisolated struct SBSegment {
    /// Tree node, or -1 for free space and -2 for a folder's smaller items.
    var node: Int
    var ring: Int
    var start: Double
    var end: Double
    var bytes: UInt64
    /// How many items a smaller-items arc stands for.
    var count: Int
    var color: TypeColor.RGB
}

/// DaisyDisk-style rings: the view root sits in the middle, each ring out is
/// one level deeper. Rendered once into a bitmap per layout change; hover,
/// selection and the centre label are drawn over it per frame.
final class SunburstNSView: NSView {
    var model: ScanModel? {
        didSet { if model !== oldValue { relayout() } }
    }

    /// Folders an agent plan would remove: lit while the rest dims.
    var highlights: [Int] = [] { didSet { if highlights != oldValue { litSegments = nil } } }

    private var segments: [SBSegment] = []
    private var segmentPaths: [CGPath] = []
    /// Layout visits each ring in angular order, despite interleaving rings.
    private var segmentsByRing: [[Int]] = []
    private var litSegments: [Int]?
    /// Ring edges in points: radii[0] is the centre disc, ring k spans
    /// radii[k]..<radii[k + 1].
    private var radii: [CGFloat] = []
    private var center: CGPoint = .zero
    private var bitmap: CGImage?
    private var lastSize: CGSize = .zero
    private var lastRoot: Int = -1
    private var lastTreeID: ObjectIdentifier?
    /// In-place removals keep the same `Tree` object, so identity cannot signal
    /// them; this is the counter that can (see `ScanModel.treeRevision`).
    private var lastRevision = -1
    private var lastShowFree = false
    private var hoveredSegment: Int?
    private var hoveringCenter = false
    private var sizeFont: NSFont?
    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let detailFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        relayoutIfNeeded()
    }

    func relayoutIfNeeded() {
        guard let model, let tree = model.tree else { return }
        if bounds.size != lastSize || model.viewRoot != lastRoot || ObjectIdentifier(tree) != lastTreeID
            || model.treeRevision != lastRevision
            || model.showFreeSpace != lastShowFree {
            // Zooming crossfades; resizing and rescans just redraw.
            let zoomed = lastTreeID == ObjectIdentifier(tree) && model.viewRoot != lastRoot
            relayout()
            // Not during SwiftUI's update pass: this writes to the model.
            DispatchQueue.main.async { [weak self] in self?.refreshHover() }
            if zoomed {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.18
                layer?.add(fade, forKey: "zoom")
            }
        }
    }

    func relayout() {
        hoveredSegment = nil
        guard let model, let tree = model.tree, bounds.width > 40, bounds.height > 40 else {
            segments = []; segmentPaths = []; segmentsByRing = []; radii = []
            litSegments = nil; hoveringCenter = false; bitmap = nil
            lastSize = .zero
            needsDisplay = true
            return
        }
        lastSize = bounds.size
        lastRoot = model.viewRoot
        lastTreeID = ObjectIdentifier(tree)
        lastRevision = model.treeRevision
        lastShowFree = model.showFreeSpace

        center = CGPoint(x: bounds.midX, y: bounds.midY)
        radii = Self.ringRadii(outer: min(bounds.width, bounds.height) / 2 - 18)
        let started = Date()
        segments = Self.layout(
            tree: tree, root: model.viewRoot, radii: radii,
            freeBytes: model.showFreeSpace && model.viewRoot == 0 ? model.freeBytes : 0
        )
        segmentPaths = segments.map { arcPath(ring: $0.ring, start: $0.start, end: $0.end) }
        segmentsByRing = Array(repeating: [], count: radii.count - 1)
        for i in segments.indices { segmentsByRing[segments[i].ring].append(i) }
        litSegments = nil
        let laidOut = Date()
        bitmap = render()
        if ProcessInfo.processInfo.environment["BZ_TIMING"] != nil {
            NSLog("BZ rings: %d arcs, layout %.1f ms, paint %.1f ms", segments.count,
                  laidOut.timeIntervalSince(started) * 1000, -laidOut.timeIntervalSinceNow * 1000)
        }
        needsDisplay = true
    }

    // ---- Layout ----

    nonisolated private enum Style {
        static let background: CGFloat = 0.086
        static let centerFill: CGFloat = 0.135
        /// Centre disc as a share of the outer radius.
        static let hole: CGFloat = 0.27
        /// Each ring is this much thinner than the one inside it.
        static let taper: CGFloat = 0.87
        /// Hue of the arc at 12 o'clock; hues then run round the circle.
        static let hueStart = 0.56
    }

    /// Edges of the centre disc and every ring. Fewer, fatter rings in a
    /// small window so the outer ones stay readable.
    ///
    /// Internal so the arc geometry can be exercised against the real radii
    /// instead of a test-local copy that could silently drift.
    nonisolated static func ringRadii(outer: CGFloat) -> [CGFloat] {
        let outer = max(outer, 40)
        let rings = max(4, min(8, Int(outer / 42)))
        let hole = outer * Style.hole
        var weights: [CGFloat] = []
        var w: CGFloat = 1
        for _ in 0..<rings { weights.append(w); w *= Style.taper }
        let unit = (outer - hole) / weights.reduce(0, +)
        var radii = [hole]
        for w in weights { radii.append(radii.last! + w * unit) }
        return radii
    }

    nonisolated private static func hsb(_ h: Double, _ s: Double, _ v: Double) -> TypeColor.RGB {
        let c = NSColor(calibratedHue: CGFloat(h - h.rounded(.down)), saturation: CGFloat(s),
                        brightness: CGFloat(v), alpha: 1).usingColorSpace(.deviceRGB)!
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    /// Folders take their hue from where they sit on the circle and fade out
    /// with depth; files are grey, like DaisyDisk.
    nonisolated private static func color(isDir: Bool, ring: Int, mid: Double) -> TypeColor.RGB {
        let d = Double(ring)
        if isDir {
            return hsb(Style.hueStart + mid / (2 * .pi), max(0.42, 0.72 - 0.045 * d), min(0.95, 0.86 + 0.014 * d))
        }
        return hsb(Style.hueStart + mid / (2 * .pi), 0.06, min(0.74, 0.58 + 0.025 * d))
    }

    /// Lays out every arc big enough to see. Children too thin to draw are
    /// gathered into one grey "smaller items" arc at the end of their folder.
    ///
    /// An arc's span follows `ShareWeight`, not raw bytes, so a sibling too
    /// small to hit still gets a readable, clickable wedge. The blend applies
    /// at every level, so it nests. Each segment keeps its real `bytes`, so
    /// the tooltip, the centre label and its share percentage stay truthful —
    /// the drawn width is the only thing that differs.
    ///
    /// Internal, like `TreemapView.pick(at:)`, so the arc geometry can be
    /// exercised directly instead of through a synthesized event: the
    /// regression it guards (a sibling too thin to hit) is invisible to a
    /// typecheck and needs no window on screen to reproduce.
    nonisolated static func layout(tree: Tree, root: Int, radii: [CGFloat], freeBytes: UInt64) -> [SBSegment] {
        var out: [SBSegment] = []
        let rings = radii.count - 1
        // Thinnest arc per ring: about 2 pt along its inner edge.
        let minAngle = (0..<rings).map { max(0.003, 2 / Double(radii[$0])) }

        func place(_ dir: Int, ring: Int, start: Double, span: Double) {
            guard ring < rings, span >= minAngle[ring] else { return }
            let parentTotal = tree.alloc[dir]
            let kids = tree.children(dir)
            // The divisor is the siblings that carry bytes — exactly the set the
            // treemap blends and the set that can be drawn. Children reporting 0
            // bytes stay out of both, so they cannot dilute a real sibling's
            // floor, and `Σ share` still lands on the folder's span.
            var siblings = 0
            for k in kids where tree.alloc[Int(k)] > 0 { siblings += 1 }
            var a = start
            var shown = 0
            for k in kids {
                let node = Int(k)
                let bytes = tree.alloc[node]
                let share: Double
                if siblings > 1 {
                    // `weight` is ≥ the pool's per-sibling floor, so a sibling
                    // with bytes always keeps a real share here.
                    share = ShareWeight.share(bytes: bytes, siblings: siblings, parentTotal: parentTotal)
                } else {
                    // One such sibling, or none: strict bytes, so a lone file
                    // fills its folder and the free-space split stays exact.
                    share = parentTotal > 0 ? Double(bytes) / Double(parentTotal) : 0
                }
                let s = span * share
                // Sorted largest first: once one is too thin, all the rest are.
                if s < minAngle[ring] { break }
                let isDir = tree.isDir(node)
                out.append(SBSegment(node: node, ring: ring, start: a, end: a + s, bytes: bytes, count: 1,
                                     color: color(isDir: isDir, ring: ring, mid: a + s / 2)))
                if isDir { place(node, ring: ring + 1, start: a, span: s) }
                a += s
                shown += 1
            }
            if shown < kids.count {
                // The tail is the siblings left undrawn. Its bytes stay the
                // true total of that tail, which is what the tooltip and the
                // "N smaller items" label report; its span is whatever of the
                // folder is left, so the ring still tiles and the free-space
                // split is untouched. Summing only when the arc is big enough
                // to draw keeps the tail walk off the layout's hot path.
                let rest = start + span - a
                if rest >= minAngle[ring] {
                    var bytes: UInt64 = 0
                    for k in kids[shown...] { bytes += tree.alloc[Int(k)] }
                    out.append(SBSegment(node: -2, ring: ring, start: a, end: start + span, bytes: bytes,
                                         count: kids.count - shown, color: (0.30, 0.30, 0.32)))
                }
            }
        }

        let used = Double(tree.alloc[root])
        let full = 2 * Double.pi
        if freeBytes > 0 {
            let usedSpan = full * used / (used + Double(freeBytes))
            place(root, ring: 0, start: 0, span: usedSpan)
            out.append(SBSegment(node: -1, ring: 0, start: usedSpan, end: full, bytes: freeBytes, count: 0,
                                 color: (0.16, 0.16, 0.18)))
        } else {
            place(root, ring: 0, start: 0, span: full)
        }
        return out
    }

    // ---- Drawing ----

    /// Screen angle for a clockwise-from-12 angle (the view is flipped).
    private static func screenAngle(_ a: Double) -> CGFloat { CGFloat(a - .pi / 2) }

    private func arcPath(ring: Int, start: Double, end: Double, outerRing: Int? = nil) -> CGPath {
        let r0 = radii[ring], r1 = radii[(outerRing ?? ring) + 1]
        let p = CGMutablePath()
        let a0 = Self.screenAngle(start), a1 = Self.screenAngle(end)
        if end - start >= 2 * .pi - 1e-9 {
            p.addEllipse(in: CGRect(x: center.x - r1, y: center.y - r1, width: 2 * r1, height: 2 * r1))
            p.addEllipse(in: CGRect(x: center.x - r0, y: center.y - r0, width: 2 * r0, height: 2 * r0))
            return p
        }
        p.addArc(center: center, radius: r1, startAngle: a0, endAngle: a1, clockwise: false)
        p.addArc(center: center, radius: r0, startAngle: a1, endAngle: a0, clockwise: true)
        p.closeSubpath()
        return p
    }

    /// The arc plus everything outside it: a folder and all its contents.
    private func wedgePath(_ s: SBSegment) -> CGPath {
        arcPath(ring: s.ring, start: s.start, end: s.end, outerRing: s.node >= 0 && model?.tree?.isDir(s.node) == true
                ? radii.count - 2 : s.ring)
    }

    /// Immutable paths may be read by several independent raster contexts.
    nonisolated private struct RasterScene: @unchecked Sendable {
        let segments: [SBSegment]
        let paths: [CGPath]
        let rings: [CGPath]
        let stroke: CGPath
        let outline: CGPath?
        let radii: [CGFloat]
        let center: CGPoint
        let bounds: CGRect
    }

    /// Each worker exclusively owns its context and disjoint bitmap rows.
    nonisolated private struct RasterBand: @unchecked Sendable {
        let context: CGContext
    }

    private func render() -> CGImage? {
        let scale = window?.backingScaleFactor ?? 2
        let pw = max(1, Int((bounds.width * scale).rounded()))
        let ph = max(1, Int((bounds.height * scale).rounded()))
        guard let ctx = CGContext(
            data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        let ringPaths = (0..<(radii.count - 1)).map { _ in CGMutablePath() }
        let stroke = CGMutablePath()
        for (i, s) in segments.enumerated() {
            ringPaths[s.ring].addPath(segmentPaths[i])
            stroke.addPath(segmentPaths[i])
        }
        // Expand Retina hairlines once with the original unclipped transform.
        // At 1x Quartz aligns strokes differently from filled outlines, so keep
        // its original serial stroke there and for small scenes.
        var outline: CGPath?
        if scale == 2, segments.count >= 24 {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(ph))
            ctx.scaleBy(x: scale, y: -scale)
            ctx.setLineWidth(1)
            ctx.setLineJoin(.round)
            ctx.addPath(stroke)
            ctx.replacePathWithStrokedPath()
            outline = ctx.path
            ctx.beginPath()
            ctx.restoreGState()
        }
        let scene = RasterScene(segments: segments, paths: segmentPaths, rings: ringPaths,
                                stroke: stroke, outline: outline, radii: radii, center: center, bounds: bounds)
        // Quartz's gradient rounding changes with the clip bounds. Render
        // those once in the original context, then split the costly stroke.
        Self.paintBase(scene, in: ctx, scale: scale)
        ctx.flush()
        let count = outline == nil ? 1 : max(1, min(ProcessInfo.processInfo.activeProcessorCount, ph / 128))
        guard count > 1, let pixels = ctx.data else {
            Self.paintEdges(scene, in: ctx)
            return ctx.makeImage()
        }
        var bands: [RasterBand] = []
        for band in 0..<count {
            let row = ph * band / count
            let height = ph * (band + 1) / count - row
            guard let context = CGContext(data: pixels,
                                          width: pw, height: ph, bitsPerComponent: 8,
                                          bytesPerRow: ctx.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                Self.paintEdges(scene, in: ctx)
                return ctx.makeImage()
            }
            // Keep the original device coordinates for path rasterization;
            // clip writes to disjoint rows.
            context.clip(to: CGRect(x: 0, y: ph - row - height, width: pw, height: height))
            context.translateBy(x: 0, y: CGFloat(ph))
            context.scaleBy(x: scale, y: -scale)
            bands.append(RasterBand(context: context))
        }
        let workers = bands
        DispatchQueue.concurrentPerform(iterations: workers.count) { i in
            let band = workers[i]
            Self.paintEdges(scene, in: band.context)
            band.context.flush()
        }
        return ctx.makeImage()
    }

    nonisolated private static func paintBase(_ scene: RasterScene, in ctx: CGContext, scale: CGFloat) {
        let bounds = scene.bounds, center = scene.center, radii = scene.radii
        // Draw in view points, y down, like the view itself.
        ctx.translateBy(x: 0, y: CGFloat(ctx.height))
        ctx.scaleBy(x: scale, y: -scale)
        let bg = Style.background
        ctx.setFillColor(CGColor(red: bg, green: bg, blue: bg, alpha: 1))
        ctx.fill(bounds)

        for (i, s) in scene.segments.enumerated() {
            ctx.addPath(scene.paths[i])
            ctx.setFillColor(CGColor(red: s.color.r, green: s.color.g, blue: s.color.b, alpha: 1))
            ctx.fillPath()
        }

        // Soft depth: each arc darkens a little towards its outer edge.
        let space = CGColorSpaceCreateDeviceRGB()
        if let shade = CGGradient(colorsSpace: space, colors: [
            CGColor(gray: 1, alpha: 1), CGColor(gray: 0.80, alpha: 1),
        ] as CFArray, locations: [0, 1]) {
            ctx.saveGState()
            ctx.setBlendMode(.multiply)
            for (k, arcs) in scene.rings.enumerated() where !arcs.isEmpty {
                ctx.saveGState()
                ctx.addPath(arcs)
                ctx.clip()
                ctx.drawRadialGradient(shade, startCenter: center, startRadius: radii[k],
                                       endCenter: center, endRadius: radii[k + 1], options: [])
                ctx.restoreGState()
            }
            ctx.restoreGState()
        }
    }

    nonisolated private static func paintEdges(_ scene: RasterScene, in ctx: CGContext) {
        let bg = Style.background, center = scene.center, radii = scene.radii
        // Hairline gaps between arcs, in the background colour.
        if let outline = scene.outline {
            ctx.setFillColor(CGColor(red: bg, green: bg, blue: bg, alpha: 1))
            ctx.addPath(outline)
            ctx.fillPath()
        } else {
            ctx.setStrokeColor(CGColor(red: bg, green: bg, blue: bg, alpha: 1))
            ctx.setLineWidth(1)
            ctx.setLineJoin(.round)
            ctx.addPath(scene.stroke)
            ctx.strokePath()
        }

        // Centre disc: the folder being shown.
        let r = radii[0] - 3
        let c = Style.centerFill
        ctx.setFillColor(CGColor(red: c, green: c, blue: c + 0.01, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let bitmap else {
            NSColor(calibratedWhite: Style.background, alpha: 1).setFill()
            bounds.fill()
            return
        }
        NSImage(cgImage: bitmap, size: bounds.size).draw(
            in: bounds, from: .zero, operation: .copy, fraction: 1,
            respectFlipped: true, hints: nil
        )
        guard let model, let tree = model.tree, let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Read the selection once per frame: it is a value snapshot, so a model
        // change mid-draw cannot leave half the arcs stroked with the old set.
        let picks = model.picks.members
        let primaryPick = model.picks.primary

        if !highlights.isEmpty {
            if litSegments == nil {
                // Folders deeper than the rings light the arc that holds them.
                let drawn = Dictionary(segments.indices.map { (segments[$0].node, $0) }) { a, _ in a }
                let wanted = Set(highlights.compactMap { node in tree.drawn(node) { drawn[$0] != nil } })
                litSegments = segments.indices.filter { wanted.contains(segments[$0].node) }
            }
            let lit = litSegments ?? []
            if !lit.isEmpty {
                let dim = CGMutablePath()
                dim.addRect(bounds)
                for i in lit { dim.addPath(wedgePath(segments[i])) }
                ctx.addPath(dim)
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
                ctx.fillPath(using: .evenOdd)
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
                ctx.setLineWidth(1.5)
                for i in lit { ctx.addPath(wedgePath(segments[i])) }
                ctx.strokePath()
            }
        }

        if let i = hoveredSegment, i < segments.count {
            let s = segments[i]
            ctx.addPath(wedgePath(s))
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.16).cgColor)
            ctx.fillPath()
            ctx.addPath(segmentPaths[i])
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokePath()
        }

        // Every picked arc, the primary stroked thicker. A node deeper than the
        // rings lights the arc that holds it (`tree.drawn`), so a file selected
        // in the list is still visible here.
        if !picks.isEmpty {
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            let drawn = Dictionary(segments.indices.map { (segments[$0].node, $0) }) { a, _ in a }
            // A picked folder lights its whole subtree, not just its own arc:
            // that is what a Delete removes and what the byte total counts, so
            // the picture agrees with the action. Without this, Cmd+A lit only
            // the innermost ring and a selected parent looked like one arc while
            // everything inside it was about to go.
            for i in litSegmentsForSelection(tree: tree, drawn: drawn) {
                // The primary is stroked thicker; a subtree lit BY the primary
                // keeps the thicker weight too, so the lead item's reach reads
                // as one shape rather than a thin fringe around a bold arc.
                let node = segments[i].node
                let isPrimary = node == primaryPick
                    || (primaryPick.map { SelectionSet.contains($0, node, in: tree) } ?? false)
                ctx.addPath(segmentPaths[i])
                ctx.setLineWidth(isPrimary ? 2.5 : 1.5)
                ctx.strokePath()
            }
        }

        if hoveringCenter && model.viewRoot != 0 {
            let r = radii[0] - 3
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.07).cgColor)
            ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        }
        drawCenterLabel(tree: tree, model: model)
    }

    /// Name, size and share of whatever is under the pointer, else the folder
    /// being shown.
    private func drawCenterLabel(tree: Tree, model: ScanModel) {
        let title: String
        let size: UInt64
        var detail: String?
        let rootBytes = max(tree.alloc[model.viewRoot], 1)
        if let i = hoveredSegment, i < segments.count {
            let s = segments[i]
            size = s.bytes
            switch s.node {
            case -1: title = String(localized: "Free space")
            case -2: title = String(localized: "\(Fmt.num(UInt64(s.count))) smaller items")
            default:
                title = tree.name(s.node)
                detail = String(format: "%.1f%%", 100 * Double(s.bytes) / Double(rootBytes))
            }
        } else if hoveringCenter && model.viewRoot != 0 {
            let p = Int(tree.parents[model.viewRoot])
            title = String(localized: "Back to \(p == 0 || p == Int(UInt32.max) ? rootName(model) : tree.name(p))")
            size = tree.alloc[p == Int(UInt32.max) ? 0 : p]
        } else {
            title = model.viewRoot == 0 ? rootName(model) : tree.name(model.viewRoot)
            size = tree.alloc[model.viewRoot]
            detail = String(localized: "\(Fmt.num(UInt64(tree.nFiles[model.viewRoot]))) files")
        }

        let width = (radii[0] - 12) * 1.7
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingMiddle
        // A new rounded font every frame had AppKit look up a font instance
        // (disk included) on each hover; it only changes with the window size.
        let sizePt = min(26, max(15, radii[0] / 4.2))
        if sizeFont?.pointSize != sizePt { sizeFont = NSFont.systemFont(ofSize: sizePt, weight: .semibold).rounded() }
        let lines: [NSAttributedString] = [
            NSAttributedString(string: title, attributes: [
                .font: Self.titleFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.72),
                .paragraphStyle: para,
            ]),
            NSAttributedString(string: Fmt.size(size), attributes: [
                .font: sizeFont!,
                .foregroundColor: NSColor.white,
                .paragraphStyle: para,
            ]),
        ] + (detail.map { [NSAttributedString(string: $0, attributes: [
            .font: Self.detailFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.45),
            .paragraphStyle: para,
        ])] } ?? [])
        let heights = lines.map { ceil($0.size().height) }
        var y = center.y - (heights.reduce(0, +) + 2 * CGFloat(lines.count - 1)) / 2
        for (line, h) in zip(lines, heights) {
            line.draw(with: CGRect(x: center.x - width / 2, y: y, width: width, height: h),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y += h + 2
        }
    }

    private func rootName(_ model: ScanModel) -> String { model.displayRootName }

    // ---- Interaction ----

    override var acceptsFirstResponder: Bool { true }

    private enum Hit { case center, segment(Int) }

    private func hit(_ p: CGPoint) -> Hit? {
        guard radii.count > 1 else { return nil }
        let dx = Double(p.x - center.x), dy = Double(p.y - center.y)
        let r = CGFloat((dx * dx + dy * dy).squareRoot())
        if r < radii[0] { return .center }
        guard let ring = (0..<(radii.count - 1)).first(where: { r < radii[$0 + 1] }) else { return nil }
        var a = atan2(dy, dx) + .pi / 2
        if a < 0 { a += 2 * .pi }
        let indices = segmentsByRing[ring]
        var lo = 0, hi = indices.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if segments[indices[mid]].end <= a { lo = mid + 1 } else { hi = mid }
        }
        guard lo < indices.count, a >= segments[indices[lo]].start else { return nil }
        return .segment(indices[lo])
    }

    override func keyDown(with event: NSEvent) {
        let esc = event.keyCode == 53
        let cmdUp = event.modifierFlags.contains(.command) && event.keyCode == 126
        // Delete removes the SELECTED node — Backspace or Forward Delete,
        // Shift for the permanent one. The selection, not the hover: the rings
        // track the pointer as it crosses an arc, and an irreversible action
        // must name what the user committed to, not what the mouse is over.
        if let kind = RemovalKeys.intent(for: event), let model, let tree = model.tree {
            NodeActions.remove(nodes: model.pickedNodes, kind: kind, tree: tree, model: model)
            return
        }
        // Cmd+A: everything this view draws, in ring order. The rings draw one
        // ring's worth per depth, so "everything drawn" IS the level — the same
        // definition the map and the list use (see `NodeOutlineView.keyDown`),
        // which is what lets all three share one reduction.
        if event.modifierFlags.contains(.command), event.keyCode == 0, let model {
            let all = ringOrder()
            guard !all.isEmpty else { return }
            model.setSelection(all)
            needsDisplay = true
            return
        }
        // Cmd-[ / Cmd-] walk the trail of folders visited, as in the treemap.
        // Every surface calls the same two model methods, so the pair cannot
        // mean something different depending on which view has the focus.
        if event.modifierFlags.contains(.command), event.keyCode == 33 || event.keyCode == 30 {
            let moved = event.keyCode == 33 ? model?.goBack() == true : model?.goForward() == true
            if moved {
                hoveredSegment = nil
                relayoutIfNeeded()
                needsDisplay = true
                return
            }
        }
        // Cmd-Up climbs out of the selection first (the same "up" the treemap
        // offers); Escape keeps its plain zoom-out meaning.
        if !esc && cmdUp, model?.selectEnclosingFolder() == true {
            // A climb that only moves the selection changes no layout, so
            // `relayoutIfNeeded` would draw nothing: the ring is outlined
            // from `model.selection` in `draw`, so redraw directly. The local
            // hover is dropped with it — its arc is not what is focused now.
            hoveredSegment = nil
            relayoutIfNeeded()
            needsDisplay = true
            return
        }
        if esc || cmdUp, zoomOut() { return }
        super.keyDown(with: event)
    }

    @discardableResult
    private func zoomOut() -> Bool {
        guard let model, let tree = model.tree, model.viewRoot != 0 else { return false }
        let p = Int(tree.parents[model.viewRoot])
        model.navigate(to: p == Int(UInt32.max) ? 0 : p)
        relayoutIfNeeded()
        return true
    }

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    /// Hover the arc at `p`, exactly as `mouseMoved` does; returns the node now
    /// hovered, or nil.
    ///
    /// Internal, like `TreemapNSView.hover(at:)`, so the arc geometry — and in
    /// particular whether hover and click agree about a folder — is exercised
    /// directly instead of through a synthesized event. A regression here is
    /// invisible to a typecheck and needs no window on screen to reproduce.
    @discardableResult
    func hover(at point: CGPoint) -> Int? {
        updateHover(at: point)
        return model?.hovered
    }

    /// Drop the hover, so the next `hover(at:)` is a real transition.
    ///
    /// `updateHover` returns early when the segment is unchanged, so a probe
    /// that cannot clear the state would measure a stale value.
    func clearHover() {
        hoveredSegment = nil
        hoveringCenter = false
        model?.hovered = nil
    }

    /// After a zoom the arcs move under a still pointer.
    private func refreshHover() {
        guard let window else { return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(p) {
            hoveredSegment = -1 // force an update
            updateHover(at: p)
        } else if model?.hovered != nil {
            model?.hovered = nil
        }
    }

    private func updateHover(at point: CGPoint) {
        let found = hit(point)
        var seg: Int?
        var onCenter = false
        switch found {
        case .center: onCenter = true
        case let .segment(i): seg = i
        case nil: break
        }
        guard seg != hoveredSegment || onCenter != hoveringCenter else { return }
        hoveredSegment = seg
        hoveringCenter = onCenter
        let node = seg.map { segments[$0].node }.flatMap { $0 >= 0 ? $0 : nil }
        model?.hovered = node
        if let node, let tree = model?.tree {
            toolTip = "\(tree.displayPath(node))\n\(Fmt.size(tree.alloc[node]))"
        } else {
            toolTip = nil
        }
        NSCursor.pointingHand.set()
        if seg == nil && !(onCenter && model?.viewRoot != 0) { NSCursor.arrow.set() }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredSegment = nil
        hoveringCenter = false
        model?.hovered = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    /// DaisyDisk clicks: a folder zooms in, the centre zooms back out, a
    /// file is selected.
    /// The arcs to stroke for the current selection.
    ///
    /// The decision is `SelectionSet.litShapes` — one owner of "what a selection
    /// lights" for every view — with this view's drawn arcs as the candidates.
    /// A file deeper than the rings lights the arc that holds it, which is the
    /// same rule the centre label uses.
    private func litSegmentsForSelection(tree: Tree, drawn: [Int: Int]) -> [Int] {
        let picks = model?.picks.members ?? []
        guard !picks.isEmpty else { return [] }
        // A pick deeper than the rings is attributed to the arc that holds it,
        // so it competes as that arc rather than disappearing.
        let attributed = picks.map { node in
            tree.drawn(node, isDrawn: { drawn[$0] != nil }) ?? node
        }
        let lit = Set(SelectionSet.litShapes(picked: attributed,
                                             candidates: Array(drawn.keys), in: tree))
        return segments.indices.filter { lit.contains(segments[$0].node) }
    }

    /// Drawn nodes in the order the rings read: innermost ring first, and
    /// clockwise within a ring. Shift+click needs a sequence the user can
    /// predict, and this is the one the picture implies.
    func ringOrder() -> [Int] {
        // One arc per node, and the `node >= 0` filter drops the free-space arc.
        // The dedupe is insurance: a node repeated here would make Shift+range
        // select it twice and `set` would then pick an arbitrary instance.
        var seen = Set<Int>()
        return segments
            .filter { $0.node >= 0 && seen.insert($0.node).inserted }
            .sorted { a, b in
                if a.ring != b.ring { return a.ring < b.ring }
                return a.start < b.start
            }
            .map(\.node)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // The second click of a double-click would land on the zoomed chart
        // and zoom again.
        guard event.clickCount == 1, let model, let tree = model.tree else { return }
        switch hit(convert(event.locationInWindow, from: nil)) {
        case .center:
            // The centre is the zoom-out target; a modified click there is not a
            // selection gesture, so it stays zoom-out.
            zoomOut()
        case let .segment(i):
            let node = segments[i].node
            guard node >= 0 else { return }
            switch SelectionSet.ClickIntent(event) {
            case .toggle:
                model.toggleSelection(node)
                needsDisplay = true
            case .extend:
                // ⇧ and ⌘⇧ extend to a FOLDER, the same rule as the map — and now
                // the same CODE: `model.extendSelection` owns the folder
                // normalisation, the view-root refusal, the ring-order range and
                // the anchor that has no arc here. The copied tail this replaces
                // is how the two views' behaviour drifted apart.
                //
                // The arc for the folder being viewed is the ring's own centre
                // region, not a segment, so a click there never reaches this
                // branch; the model refuses the view root regardless.
                model.extendSelection(to: node, order: ringOrder())
                needsDisplay = true
            case .replace:
                if tree.isDir(node) && !tree.children(node).isEmpty {
                    model.navigate(to: node)
                    relayoutIfNeeded()
                } else {
                    model.select(node)
                    needsDisplay = true
                }
            }
        case nil:
            // Empty space: a plain click clears; a modified one is additive and
            // must not throw the selection away.
            if SelectionSet.ClickIntent(event) == .replace {
                model.select(nil)
                needsDisplay = true
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let model, let tree = model.tree,
              case let .segment(i) = hit(convert(event.locationInWindow, from: nil)),
              segments[i].node >= 0
        else { return }
        // Right-clicking an arc inside the selection keeps the whole selection
        // (the menu then acts on all of it); one outside focuses that arc first,
        // so the menu and the highlight cannot disagree.
        if !model.picks.covers(segments[i].node, in: tree) {
            model.select(segments[i].node)
        }
        needsDisplay = true
        NodeMenu.popUp(node: segments[i].node, tree: tree, model: model, with: event, for: self)
    }
}

private extension NSFont {
    func rounded() -> NSFont {
        guard let d = fontDescriptor.withDesign(.rounded) else { return self }
        return NSFont(descriptor: d, size: pointSize) ?? self
    }
}

struct SunburstView: NSViewRepresentable {
    let model: ScanModel

    func makeNSView(context: Context) -> SunburstNSView {
        let v = SunburstNSView()
        v.model = model
        return v
    }

    func updateNSView(_ view: SunburstNSView, context: Context) {
        view.model = model
        view.relayoutIfNeeded()
        let lit = model.agentRun?.highlights(in: model.tree) ?? []
        if lit != view.highlights {
            view.highlights = lit
            view.needsDisplay = true
        }
        // A pick in the list outlines its arc here.
        _ = model.selection
        view.needsDisplay = true
    }
}
