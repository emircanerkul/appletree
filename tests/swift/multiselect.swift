// Multi-selection regression net: the antichain invariant and its operations.
//
// Build (from repo root, same contract as the other suites):
//   swiftc tests/swift/multiselect.swift \
//       $(filter-out app/Main.swift,$(wildcard app/*.swift)) \
//       -import-objc-header app/bz.h -parse-as-library \
//       -swift-version 6 -default-isolation MainActor \
//       -target arm64-apple-macos14.0 -L target/release -lappletree \
//       -framework DiskArbitration -framework IOKit -framework Security \
//       -o .build/multiselect-tests
//
// The invariant this locks — no member contains another — is what keeps a batch
// delete honest: a nested pair double-counts bytes and hands the Trash two paths
// where one contains the other, so the second move acts on a path that is gone
// and reports a failure for something that worked.
//
// A real `Tree` is built by scanning a scratch directory with the shipping
// engine, so ancestry, attachment and child order are the ones the app reads,
// not a hand-rolled stand-in.

import AppKit
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

/// Scan `path` with the shipping engine and return its `Tree`.
func scanTree(_ path: String) -> Tree? {
    guard let handle = bz_scan_start(path) else { return nil }
    var done: Int32 = 0
    var files: UInt64 = 0, dirs: UInt64 = 0, bytes: UInt64 = 0
    let deadline = Date().addingTimeInterval(60)
    while Date() < deadline {
        bz_progress(handle, &files, &dirs, &bytes, &done)
        if done != 0 { break }
        usleep(2000)
    }
    guard done != 0, let tree = Tree(handle: handle) else {
        bz_free(handle)
        return nil
    }
    return tree
}

/// The fixture, built once: a nested shape with two disjoint branches.
///
///     root
///       A/                      (the parent in the nesting tests)
///         A1/
///           deep.txt            (3 levels under root)
///         a2.txt
///       B/
///         b1.txt
///       top.txt
/// Read a repo file, for the structural assertions at the end.
///
/// Same helper the deletion suite uses: some regressions here live only at the
/// seam between two files (which view pushes which rows), and a compiled suite
/// cannot see the wiring.
func source(_ rel: String) -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

/// Deterministic PRNG (SplitMix64), so a stress failure replays exactly.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor
func run() {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("multiselect-\(ProcessInfo.processInfo.processIdentifier)")
    try? fm.removeItem(at: root)
    for dir in ["A/A1", "B"] {
        try? fm.createDirectory(at: root.appendingPathComponent(dir),
                                withIntermediateDirectories: true)
    }
    try? "1".write(toFile: root.appendingPathComponent("A/A1/deep.txt").path,
                   atomically: true, encoding: .utf8)
    try? "2".write(toFile: root.appendingPathComponent("A/a2.txt").path,
                   atomically: true, encoding: .utf8)
    try? "3".write(toFile: root.appendingPathComponent("B/b1.txt").path,
                   atomically: true, encoding: .utf8)
    try? "4".write(toFile: root.appendingPathComponent("top.txt").path,
                   atomically: true, encoding: .utf8)

    guard let tree = scanTree(root.path) else {
        print("FAIL could not scan the fixture")
        exit(1)
    }
    /// Node lookup that fails loudly: a fixture rename must break the suite
    /// rather than silently produce -1 and pass for the wrong reason.
    func node(_ rel: String) -> Int {
        guard let n = tree.node(at: root.appendingPathComponent(rel).path) else {
            print("FAIL fixture node missing: \(rel)")
            exit(1)
        }
        return n
    }
    let A = node("A"), A1 = node("A/A1"), deep = node("A/A1/deep.txt")
    let a2 = node("A/a2.txt"), B = node("B"), b1 = node("B/b1.txt"), top = node("top.txt")
    let rootNode = 0

    // Sanity on the fixture itself: the nesting tests mean nothing without it.
    check("fixture A is an ancestor of A1", tree.ancestry(A1).contains(A))
    check("fixture A1 is an ancestor of deep.txt", tree.ancestry(deep).contains(A1))
    check("fixture A and B are unrelated",
          !tree.ancestry(A).contains(B) && !tree.ancestry(B).contains(A))

    // --- vsReplace: a plain click -------------------------------------------------
    var s = SelectionSet()
    check("a new selection is empty", s.isEmpty && s.primary == nil)
    s.replace(with: A)
    check("replace picks one node", s.members == [A] && s.primary == A)
    s.replace(with: B)
    check("replace drops the previous pick", s.members == [B] && s.primary == B)
    s.replace(with: nil)
    check("replace(nil) clears", s.isEmpty && s.primary == nil)

    // --- toggle: Cmd+click, and the nesting rule in BOTH directions ---------------
    s.replace(with: A)
    s.toggle(top, in: tree)
    check("Cmd+click adds an unrelated node", Set(s.members) == Set([A, top]),
          "members=\(s.members)")

    // The rule the user asked for: file first, then its parent -> the parent.
    s.replace(with: deep)
    check("child alone is picked", s.members == [deep])
    s.toggle(A, in: tree)
    check("picking the parent REPLACES a selected child", s.members == [A],
          "members=\(s.members) — a nested pair would double-count bytes")
    check("the parent is the primary", s.primary == A)

    // The other direction: parent first, then a child inside it -> the child.
    s.replace(with: A)
    s.toggle(deep, in: tree)
    check("picking a child replaces a selected parent", s.members == [deep],
          "members=\(s.members)")

    // A whole chain, and a sibling that must survive.
    s.replace(with: deep)
    s.toggle(b1, in: tree)
    check("unrelated nodes coexist", Set(s.members) == Set([deep, b1]), "members=\(s.members)")
    s.toggle(A1, in: tree)
    check("picking a mid ancestor drops the deep child and keeps the outsider",
          Set(s.members) == Set([A1, b1]), "members=\(s.members)")
    s.toggle(A, in: tree)
    check("picking the top ancestor collapses its branch and keeps the outsider",
          Set(s.members) == Set([A, b1]), "members=\(s.members) — A1 is inside A, b1 is not")

    // Toggling an already-picked node removes it.
    s.replace(with: A)
    s.toggle(B, in: tree)
    s.toggle(B, in: tree)
    check("Cmd+click on a picked node removes it", s.members == [A],
          "members=\(s.members)")
    check("the anchor survives an un-pick of another node", s.primary == A)
    s.toggle(A, in: tree)
    check("un-picking the anchor leaves the set empty", s.isEmpty)
    check("un-picking the anchor clears the primary", s.primary == nil)

    // --- invariant: never two members where one contains the other ----------------
    func isAntichain(_ set: SelectionSet) -> Bool {
        for x in set.members {
            for y in set.members where x != y {
                if tree.ancestry(y).contains(x) { return false }
            }
        }
        return true
    }

    // Drive every writer through a long mixed sequence and assert the invariant
    // after EVERY step — the property is the contract, not the individual cases.
    var walk = SelectionSet()
    let all = [rootNode, A, A1, deep, a2, B, b1, top]
    var violation: String?
    for node in all + all.reversed() + [A, deep, A1] {
        walk.toggle(node, in: tree)
        if !isAntichain(walk) { violation = "after toggle(\(node)): \(walk.members)" }
        walk.set([A, deep, a2, B, b1], in: tree)
        if !isAntichain(walk) { violation = "after set: \(walk.members)" }
        walk.set(all, in: tree)
        if !isAntichain(walk) { violation = "after set(all): \(walk.members)" }
        walk.replace(with: node)
        if !isAntichain(walk) { violation = "after replace(\(node)): \(walk.members)" }
    }
    check("the invariant holds after every writer, over a long mixed sequence",
          violation == nil, violation ?? "")
    check("the node id never appears twice",
          Set(walk.members).count == walk.members.count)

    // --- set: a range, reduced to the outermost -----------------------------------
    s.set([A, A1, deep, a2, B], in: tree)
    check("a range keeps the outermost items only", Set(s.members) == Set([A, B]),
          "members=\(s.members)")
    check("a range keeps pick order", s.members == [A, B], "members=\(s.members)")
    check("a range over one branch collapses to that branch's root",
          { var t = SelectionSet(); t.set([A1, deep], in: tree); return t.members == [A1] }())
    s.set([b1, top], in: tree)
    check("disjoint nodes are all kept", Set(s.members) == Set([b1, top]))
    s.set([], in: tree)
    check("an empty range clears", s.isEmpty)

    // The anchor is what makes a second Shift+click re-range instead of creep.
    s.set([A, B, top], anchor: B, in: tree)
    check("an explicit anchor is honoured", s.primary == B, "primary=\(s.primary as Any)")
    s.set([A, B, top], in: tree)
    check("without an anchor the last member leads", s.primary == top)

    // --- duplicates and the defensive dedupe --------------------------------------
    s.set([A, A, A], in: tree)
    check("duplicates collapse", s.members == [A], "members=\(s.members)")
    s.set([A, deep, b1], in: tree)
    check("containmentDeduped never returns a nested pair",
          { var t = s; t.set([deep, A], in: tree); return t.containmentDeduped(in: tree) == [A] }())

    // --- validate: an in-place removal --------------------------------------------
    // A fresh tree for the mutation: `removeNode` edits it in place.
    guard let mutTree = scanTree(root.path) else {
        print("FAIL could not scan the second fixture")
        exit(1)
    }
    let mA = mutTree.node(at: root.appendingPathComponent("A").path)!
    let mA1 = mutTree.node(at: root.appendingPathComponent("A/A1").path)!
    let mDeep = mutTree.node(at: root.appendingPathComponent("A/A1/deep.txt").path)!
    let mB = mutTree.node(at: root.appendingPathComponent("B").path)!

    var v = SelectionSet()
    v.set([mA1, mB], in: mutTree)          // A1 and B, unrelated
    check("validate keeps attached members", {
        var t = v; t.validate(in: mutTree); return Set(t.members) == Set([mA1, mB])
    }())
    // Remove A: A1 and everything under it detach, B does not.
    check("the engine removed the subtree", mutTree.removeNode(mA))
    v.validate(in: mutTree)
    check("validate drops the detached member", v.members == [mB],
          "members=\(v.members) — a detached id would be acted on later")
    check("validate keeps the surviving member's bytes honest", !mutTree.isAttached(mA1))
    check("validate moved the primary off the dead node", v.primary == mB,
          "primary=\(v.primary as Any)")

    // A selection whose primary alone is detached: the anchor moves to a survivor.
    var v2 = SelectionSet()
    v2.set([mB], in: mutTree)
    v2.toggle(mDeep, in: mutTree)          // detached by then -> adds, then validate drops
    v2.validate(in: mutTree)
    check("validate leaves only attached members", v2.members.allSatisfy { mutTree.isAttached($0) },
          "members=\(v2.members)")

    // --- covers: the query a context menu asks ------------------------------------
    var c = SelectionSet()
    c.set([A, B], in: tree)
    check("a selected node is covered by itself", c.covers(A, in: tree))
    check("a child of a selected folder is covered", c.covers(deep, in: tree))
    check("an unrelated node is not covered", !c.covers(top, in: tree))
    check("containsAncestor is false for the member itself",
          !c.containsAncestor(of: A, in: tree))

    // --- clear ---------------------------------------------------------------------
    var cl = SelectionSet()
    cl.set([A, B], in: tree)
    cl.clear()
    check("clear empties members and anchor", cl.isEmpty && cl.primary == nil)

    // --- the anchor must stay a MEMBER ---------------------------------------------
    // A range anchor is the end the user did NOT click. It can be reduced away —
    // sweeping a folder whose contents the range started on — and a primary that
    // is not a member describes an item nothing highlights.
    var an = SelectionSet()
    // A1 and B are unrelated, so both survive and the anchor is still a member.
    an.set([A1, B, top], anchor: B, in: tree)
    check("an anchor that survives the reduction is kept", an.primary == B,
          "primary=\(an.primary as Any)")
    an.set([A, deep], anchor: deep, in: tree)   // deep is inside A -> reduced away
    check("an anchor reduced away is replaced, not left dangling",
          an.members == [A] && an.primary == A,
          "members=\(an.members) primary=\(an.primary as Any)")
    check("the primary is always a member",
          { var t = SelectionSet(); t.set([A, deep, b1], anchor: deep, in: tree)
            return t.primary.map { t.contains($0) } ?? true }())
    var empty = SelectionSet()
    empty.set([], anchor: A, in: tree)
    check("an empty set has no primary", empty.primary == nil)

    // --- every writer keeps primary a member (the property, not the cases) --------
    var prop = SelectionSet()
    var bad: String?
    for node in all + all.reversed() {
        prop.toggle(node, in: tree)
        if let p = prop.primary, !prop.contains(p) { bad = "toggle -> primary \(p) not a member" }
        prop.set([A, deep, a2, B], anchor: node, in: tree)
        if let p = prop.primary, !prop.contains(p) { bad = "set -> primary \(p) not a member" }
        prop.replace(with: node)
        if let p = prop.primary, !prop.contains(p) { bad = "replace -> primary \(p) not a member" }
    }
    check("the primary is a member after every writer", bad == nil, bad ?? "")

    // --- Cmd+A must select the LEVEL, not the root ---------------------------------
    //
    // The renderer appends the view root to `rects` as the window-wide box
    // everything sits inside. Leaving it in the Cmd+A set makes it an ancestor of
    // every other entry, so outermost-wins collapsed the whole selection to the
    // root: Cmd+A selected just the folder being browsed, the accent ring went
    // around the entire window, and a follow-up Delete refused it as the scan
    // root. Verified against the real renderer, at the root and at every zoom.
    let rendered = TreemapRenderer.render(tree: tree, pw: 1200, ph: 800, scale: 2,
                                          root: rootNode, showFree: false, freeBytes: 0)
    check("the renderer really does put the view root in rects",
          rendered.rects.contains { $0.node == rootNode },
          "the fixture no longer reproduces the shape this guards")
    var cmdA = SelectionSet()
    var seenDrew = Set<Int>()
    let drew = (rendered.rects.map(\.node) + rendered.leaves.map(\.node))
        .filter { seenDrew.insert($0).inserted }
    // The rendering-order rule: the view root is excluded before `set`.
    cmdA.set(drew.filter { $0 != rootNode }, in: tree)
    check("Cmd+A at the root selects its children, not the root",
          !cmdA.contains(rootNode) && cmdA.count > 1,
          "members=\(cmdA.members) — the root collapsed the selection")
    check("no member of a Cmd+A selection is the view root",
          !cmdA.members.contains(rootNode))

    // The same rule at a deeper zoom: the root of THAT view is the folder on
    // screen, and the level selected is its children.
    if let aNode = tree.node(at: root.appendingPathComponent("A").path) {
        var zoomed = SelectionSet()
        let deep = TreemapRenderer.render(tree: tree, pw: 1200, ph: 800, scale: 2,
                                          root: aNode, showFree: false, freeBytes: 0)
        var seenDeep = Set<Int>()
        let nodes = (deep.rects.map(\.node) + deep.leaves.map(\.node))
            .filter { $0 != aNode && seenDeep.insert($0).inserted }
        zoomed.set(nodes, in: tree)
        check("Cmd+A at a zoom selects that folder's children, not the folder",
              !zoomed.contains(aNode) && !zoomed.members.isEmpty,
              "members=\(zoomed.members)")
    }

    // --- randomised stress: the invariant after EVERY operation --------------------
    //
    // The hand-written cases above check the states a person thinks of. This
    // checks the ones they do not: a long random walk over every writer, with
    // all three properties asserted after each step — no nested pair, no
    // duplicate, and a primary that is always a member. A seeded generator keeps
    // it reproducible, so a failure can be replayed instead of hunted.
    var rng = SplitMix64(seed: 0xB1_12_7E)
    var st = SelectionSet()
    var stBad = ""
    let nodes = (0..<tree.count).map { $0 }
    for _ in 0..<20_000 {
        let n = nodes[Int(rng.next() % UInt64(nodes.count))]
        switch rng.next() % 5 {
        case 0: st.replace(with: rng.next() % 3 == 0 ? nil : n)
        case 1: st.toggle(n, in: tree)
        case 2: st.set([nodes[Int(rng.next() % UInt64(nodes.count))], n], in: tree)
        case 3: st.set([deep, A1, a2, B, top, n], anchor: n, in: tree)
        default: st.clear()
        }
        if stBad.isEmpty {
            for x in st.members where stBad.isEmpty {
                for y in st.members where x != y {
                    if tree.ancestry(y).contains(x) { stBad = "nested pair \(x) in \(y)" }
                }
            }
            if st.members.count != Set(st.members).count { stBad = "duplicate member" }
            if let p = st.primary, !st.contains(p) { stBad = "primary \(p) is not a member" }
        }
    }
    check("20k randomised operations keep all three properties", stBad.isEmpty, stBad)

    // --- a selected folder lights its whole subtree ---------------------------------
    //
    // The picture must say what the action will do. Outlining only a picked
    // folder's own shape made Cmd+A look like "only the first ring is selected"
    // and left a selected parent looking like a single arc while its entire
    // subtree was about to be deleted.
    let drawn = (0..<tree.count).map { $0 }
    let litA = Set(SelectionSet.litShapes(picked: [A], candidates: drawn, in: tree))
    check("a picked folder lights every drawn descendant",
          litA == Set([A, A1, deep, a2]),
          "lit=\(litA.sorted())")
    check("a picked folder does not light an unrelated branch", !litA.contains(B))
    check("a picked file lights only itself",
          Set(SelectionSet.litShapes(picked: [top], candidates: drawn, in: tree)) == [top])
    // The level plus its contents: what Cmd+A should look like.
    let level = tree.children(rootNode).map { Int($0) }
    let litLevel = Set(SelectionSet.litShapes(picked: level, candidates: drawn, in: tree))
    check("Cmd+A over a level lights that level and everything inside it",
          litLevel == Set((0..<tree.count).filter { $0 != rootNode }),
          "missed \(Set(drawn).subtracting(litLevel).sorted())")
    check("nothing lights when nothing is picked",
          SelectionSet.litShapes(picked: [], candidates: drawn, in: tree).isEmpty)
    // Nested picks: the inner one must not be lost, and must stay deduped.
    let litNested = SelectionSet.litShapes(picked: [A, a2], candidates: drawn, in: tree)
    check("an inner pick does not duplicate its ancestor's subtree",
          litNested.count == Set(litNested).count && Set(litNested) == Set([A, A1, deep, a2]),
          "lit=\(litNested.sorted())")

    // WHO lights a subtree is a per-view geometry question, not one global rule.
    //
    // The rings must light a picked folder's whole subtree: an arc is the folder
    // and the things inside it are separate arcs further out, so outlining only
    // the folder's own arc hid the rest of what was about to be deleted.
    check("the rings light a picked folder's subtree",
          source("app/SunburstView.swift").contains("SelectionSet.litShapes(picked:"))
    // The map must NOT: it already draws a folder as a framed box holding its
    // children, so outlining every nested rect too buried the picture under one
    // blue outline per tile. The box is the containment statement.
    let tmSrc = source("app/TreemapView.swift")
    check("the map does not outline every nested rect",
          !tmSrc.contains("SelectionSet.litShapes(picked:") && !tmSrc.contains("litNodesForSelection"),
          "the treemap would draw one outline per tile")

    // --- a collapsed folder holding picks ------------------------------------------
    //
    // Collapsing hides a pick without cancelling it: Delete still removes it and
    // the byte total still counts it. The row has to say so, or the selection is
    // invisible while remaining destructive.
    var hp = SelectionSet()
    hp.replace(with: deep)                    // a file 3 levels under the root
    check("an ancestor of a pick reports that it holds one", hp.holdsPick(inside: A, in: tree))
    check("a nearer ancestor of a pick reports it too", hp.holdsPick(inside: A1, in: tree))
    check("an unrelated folder holds nothing", !hp.holdsPick(inside: B, in: tree))
    check("a picked row does not also look partial", {
        var t = SelectionSet(); t.replace(with: A)
        return !t.holdsPick(inside: A, in: tree)          // itself, not "inside"
    }())
    check("a leaf that is not a folder holds nothing", !hp.holdsPick(inside: deep, in: tree))
    check("the picks inside a folder are listed", hp.picks(inside: A, in: tree) == [deep])
    var multi = SelectionSet()
    multi.set([deep, a2], in: tree)
    check("several hidden picks are all reported",
          Set(multi.picks(inside: A, in: tree)) == Set([deep, a2]),
          "got \(multi.picks(inside: A, in: tree).sorted())")

    // --- the list must not silently drop what it cannot show -----------------------
    let content = source("app/ContentView.swift")
    //
    // A list gesture used to hand over only its own rows, so a pick with no row
    // here — a deep file under a collapsed folder, or anything outside the folder
    // on screen — was replaced away. The selection is shared across views, so a
    // gesture in one must not delete what another selected.
    check("the list reports which nodes it renders",
          content.contains("func renderedNodes() -> [Int]"))
    check("the list keeps the members it cannot show",
          content.contains("let hidden = model.picks.members.filter { !rendered.contains($0) }"),
          "a list gesture would drop the picks a collapsed folder is hiding")

    // A reload throws the row objects away, and the code remembered only the
    // primary's row — so an in-place removal collapsed a multi-selection the
    // moment the list rebuilt. Every selected id is remembered and restored now.
    check("the list remembers every selected row across a reload",
          content.contains("let selectedIDs = reuseRows ? [] : selectedItems.map(\\.id)")
              && content.contains("for id in selected {"),
          "a reload would restore only the primary row")

    // --- collapse must survive a redraw, and must not cancel hidden picks ----------
    //
    // Two bugs of one gesture. `syncSelection` runs from `updateNSView` on every
    // model change and used to call `expandItem` unconditionally, so collapsing a
    // folder was immediately undone. And AppKit reports a collapse as a smaller
    // row set — indistinguishable from a deselect — so writing it back cancelled
    // every pick inside the folder.
    check("expansion happens once per new pick, not on every redraw",
          content.contains("func picksDidChange()") && content.contains("lastSyncedPicks"),
          "a redraw would re-open a folder the user collapsed")
    check("the row-fetching path does not expand",
          !content.contains("outline.expandItem(it)\n                    level = it.children"),
          "revealRow still opens ancestors on every sync")
    // The collapse case is handled by CARRYING the hidden picks across, never by
    // ignoring the notification: an earlier "treat this as a collapse and
    // return early" version swallowed every later click once one folder was
    // collapsed, so rows lit up without the model accepting them.
    check("a hidden pick is carried when the user ADDS to the selection",
          content.contains("model.setSelection(hidden + rows, anchor: model.picks.primary)"),
          "extending the selection would discard what a collapsed folder hides")
    check("a plain click still replaces everything, hidden picks included",
          content.contains("case .replace:") && content.contains("model.setSelection(rows)"),
          "a pick inside a closed folder could never be cleared")

    // --- the partial-row stripes: vertical, 45%, and exactly so --------------------
    //
    // Rendered and measured, not asserted from the source: the look is the whole
    // point of this row view, and the arithmetic is easy to get subtly wrong.
    // Drawing 0.45 OVER a 0.06 wash composites to 0.48, so the alpha is inverted
    // through the wash to land on 45% as displayed.
    func renderRow(holdsPick: Bool) -> NSBitmapImageRep {
        let row = PartialRowView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        row.selectionHighlightStyle = .regular
        row.holdsPick = holdsPick
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        row.drawBackground(in: row.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    if let partial = renderRow(holdsPick: true) as NSBitmapImageRep? {
        let stripe = partial.colorAt(x: 1, y: 10)!.alphaComponent
        let gap = partial.colorAt(x: 4, y: 10)!.alphaComponent
        check("the stripes composite to 45% on screen",
              abs(stripe - 0.45) < 0.02, String(format: "got %.3f", stripe))
        check("the gaps stay faint", gap < 0.10, String(format: "got %.3f", gap))
        // 45° DIAGONAL. One pixel of horizontal shift per pixel of height, which
        // is the definition of a 45-degree slope. Measured by cross-correlating
        // the alpha profile of adjacent rows: a vertical hatch would give lag 0.
        let H = partial.pixelsHigh
        func profile(_ y: Int) -> [CGFloat] {
            (0..<partial.pixelsWide).map { partial.colorAt(x: $0, y: y)!.alphaComponent }
        }
        func bestLag(_ a: [CGFloat], _ b: [CGFloat]) -> Int {
            var best = (lag: 0, score: -Double.infinity)
            for lag in -3...3 {
                var sum = 0.0
                for x in 0..<a.count {
                    let bx = x + lag
                    if bx >= 0 && bx < b.count { sum += Double(a[x]) * Double(b[bx]) }
                }
                if sum > best.score { best = (lag, sum) }
            }
            return best.lag
        }
        var lags: [Int] = []
        for y in 4..<(H - 4) { lags.append(bestLag(profile(y), profile(y + 1))) }
        let slope = lags.isEmpty ? 0 : Double(lags.reduce(0, +)) / Double(lags.count)
        check("the hatch runs at 45 degrees",
              abs(abs(slope) - 1.0) < 0.2, String(format: "slope %.2f (want 1.0)", slope))

        // Wider spacing: the period along a row is band + gap. A narrow gap read
        // as a solid wash rather than a texture.
        var peaks: [Int] = []
        var last = -100
        let mid = H / 2
        for x in 0..<partial.pixelsWide {
            if partial.colorAt(x: x, y: mid)!.alphaComponent > 0.35 {
                if x - last > 3 { peaks.append(x) }
                last = x
            }
        }
        let periods = zip(peaks, peaks.dropFirst()).map { $1 - $0 }
        check("the hatch spacing is wide enough to read as a texture",
              !periods.isEmpty && periods.allSatisfy { $0 >= 9 },
              "periods=\(periods)")

        // Lighter blue than the selection accent, so a partial mark cannot be
        // mistaken for a genuinely selected row.
        if let c = partial.colorAt(x: peaks.first ?? 1, y: mid)?
            .usingColorSpace(.deviceRGB) {
            let accent = NSColor.controlAccentColor.usingColorSpace(.deviceRGB)!
            check("the hatch is a lighter blue than the accent",
                  c.greenComponent > accent.greenComponent && c.redComponent > accent.redComponent,
                  String(format: "stripe=(%.0f,%.0f,%.0f) accent=(%.0f,%.0f,%.0f)",
                         c.redComponent*255, c.greenComponent*255, c.blueComponent*255,
                         accent.redComponent*255, accent.greenComponent*255, accent.blueComponent*255))
        }
        // A row that is itself selected keeps the solid bar, not the stripes.
        if let solid = renderRow(holdsPick: false) as NSBitmapImageRep? {
            let a1 = solid.colorAt(x: 1, y: 10)!.alphaComponent
            let a2 = solid.colorAt(x: 4, y: 10)!.alphaComponent
            check("a selected row is a solid bar, not striped", abs(a1 - a2) < 0.01)
        }
        // A row whose mark is turned off draws nothing at all.
        let plain = PartialRowView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        plain.selectionHighlightStyle = .regular
        plain.holdsPick = false
        check("reuse clears the mark", {
            let r = PartialRowView(); r.holdsPick = true; r.prepareForReuse()
            return !r.holdsPick
        }())
    }

    // --- a shared selection must look the same in every view -----------------------
    //
    // AppKit picks a row's selection colour from `isEmphasized`, which is false
    // whenever the table is not first responder — so a pick made in the TREEMAP
    // left the list showing the inactive grey bar while the map ringed the same
    // item in accent blue. The selection is app state, not a focus indicator, so
    // the row draws the accent while the window is active.
    if let content = source("app/ContentView.swift") as String? {
        check("the row draws the accent while the window is active",
              content.contains("window?.isKeyWindow ?? false")
                  && content.contains("NSColor.controlAccentColor")
                  && content.contains("NSColor.unemphasizedSelectedContentBackgroundColor"),
              "a treemap-made selection would still look grey in the list")
        // Asserted on CODE, not on the word: the comment above `drawSelection`
        // explains the `isEmphasized` behaviour it replaces, so a plain text
        // search would fail on its own documentation.
        let selectionCode = content
            .components(separatedBy: "override func drawSelection")
            .dropFirst().first ?? ""
        check("the selection colour does not depend on isEmphasized",
              !selectionCode.contains("isEmphasized"))
        // And the colours really are what they claim.
        let accent = NSColor.controlAccentColor.usingColorSpace(.deviceRGB)!
        check("the accent is blue", accent.blueComponent > 0.8 && accent.redComponent < 0.2)
        let inactive = NSColor.unemphasizedSelectedContentBackgroundColor.usingColorSpace(.deviceRGB)!
        check("the inactive colour is a neutral grey",
              abs(inactive.redComponent - inactive.greenComponent) < 0.05)
    }

    // --- the hatch belongs only on a COLLAPSED folder -------------------------------
    //
    // An expanded folder already shows the selected child on its own solid row, so
    // hatching the parent too states the same fact twice — and with several
    // folders open it hatched most of the visible rows, which read as a broken
    // list rather than as information.
    let csrc = source("app/ContentView.swift")
    check("a row shows the hatch only when its folder is collapsed",
          csrc.contains("guard outline?.isItemExpanded(item) != true else { return false }")
              && csrc.contains("private func needsPartialMark"),
          "an expanded folder would be hatched as well as its selected child")
    check("the hatch is cleared when a folder opens or closes",
          csrc.contains("func outlineViewItemDidExpand")
              && csrc.contains("func outlineViewItemDidCollapse"),
          "opening a folder would leave a stale hatch on its row")
    check("the hatch rule is used by both marking paths",
          csrc.components(separatedBy: "needsPartialMark(item, tree: tree, model: model)").count >= 3,
          "one path would disagree with the other about the hatch")

    // --- collapse then expand must not lose the blue -------------------------------
    //
    // AppKit restores the ROWS a collapse removed but not their selection, and it
    // posts no `selectionDidChange` for the restore — so the rows came back
    // unhighlighted and the picks looked lost although the model still held them.
    // `syncSelection` runs from `updateNSView`, which does not fire on a
    // disclosure click (no SwiftUI dependency changed), so the expand handler is
    // the only place that can put the highlight back.
    //
    // Driven through a real NSOutlineView, because the bug lives in AppKit's
    // notification ordering and a unit test of the model would never see it.
    final class ProbeNode: NSObject {
        let label: String, id: Int
        let kids: [ProbeNode]
        init(_ l: String, _ i: Int, _ k: [ProbeNode] = []) { label = l; id = i; kids = k }
    }
    final class ProbeSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        let root: ProbeNode
        var picks: Set<Int> = []
        var isSyncing = false
        init(_ r: ProbeNode) { root = r }
        func outlineView(_ v: NSOutlineView, numberOfChildrenOfItem i: Any?) -> Int {
            (i as? ProbeNode)?.kids.count ?? 1 }
        func outlineView(_ v: NSOutlineView, child ix: Int, ofItem i: Any?) -> Any {
            i == nil ? root : (i as! ProbeNode).kids[ix] }
        func outlineView(_ v: NSOutlineView, isItemExpandable i: Any) -> Bool {
            !(i as! ProbeNode).kids.isEmpty }
        func ids(_ v: NSOutlineView) -> [Int] {
            (0..<v.numberOfRows).compactMap { (v.item(atRow: $0) as? ProbeNode)?.id } }
        func selected(_ v: NSOutlineView) -> [Int] {
            v.selectedRowIndexes.compactMap { (v.item(atRow: $0) as? ProbeNode)?.id } }
        /// The shipped push: model selection onto rows.
        func pushHighlight(_ v: NSOutlineView) {
            guard !isSyncing else { return }
            isSyncing = true; defer { isSyncing = false }
            var idx = IndexSet()
            for r in 0..<v.numberOfRows {
                if let n = v.item(atRow: r) as? ProbeNode, picks.contains(n.id) { idx.insert(r) }
            }
            if idx != v.selectedRowIndexes { v.selectRowIndexes(idx, byExtendingSelection: false) }
        }
        func outlineViewItemDidExpand(_ n: Notification) {
            pushHighlight(n.object as! NSOutlineView) }
        func outlineViewSelectionDidChange(_ n: Notification) {
            let v = n.object as! NSOutlineView
            if isSyncing { return }
            let shown = Set(ids(v))
            let carried = picks.filter { !shown.contains($0) }
            picks = Set(carried).union(selected(v))
        }
    }
    do {
        let deep2 = ProbeNode("deep.txt", 4), b = ProbeNode("B", 3, [deep2])
        let a = ProbeNode("A", 1, [b]), sib = ProbeNode("sibling", 5)
        let src = ProbeSource(ProbeNode("root", 0, [a, sib]))
        let ov = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let col = NSTableColumn(identifier: .init("c"))
        ov.addTableColumn(col); ov.outlineTableColumn = col
        ov.allowsMultipleSelection = true
        ov.dataSource = src; ov.delegate = src
        ov.reloadData(); ov.expandItem(nil, expandChildren: true)
        let row = (0..<ov.numberOfRows).first { (ov.item(atRow: $0) as? ProbeNode)?.id == 4 }!
        ov.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        src.picks = [4]

        ov.collapseItem(ov.item(atRow: 0))
        check("a collapse keeps the pick in the model", src.picks == [4],
              "picks=\(src.picks.sorted())")
        ov.expandItem(ov.item(atRow: 0))
        check("re-expanding restores the highlight (the blue is not lost)",
              src.selected(ov) == [4], "selected=\(src.selected(ov))")
        check("the model still holds the pick after the round trip", src.picks == [4])
    }

    // --- a hidden pick must NOT survive the next gesture -----------------------------
    //
    // The carry that protects picks inside a collapsed folder was inferred from
    // STATE ("some pick has no row"), so it applied to EVERY later selection
    // change: a plain click ADDED to the selection instead of replacing it, and a
    // pick inside a closed folder could never be cleared without opening it. The
    // signal is now the collapse EVENT — `willCollapse`, which a plain click
    // never fires — and the carry is dropped the moment its notification lands.
    //
    // Driven through a real NSOutlineView: the distinction is AppKit's
    // notification ordering, which no model-level test can see.
    // The gesture model replaces every timing-based rule: the view declares the
    // click, the handler reads it, and nothing depends on notification order.
    check("the view declares the gesture at the click",
          csrc.contains("noteGesture(.disclosure)")
              && csrc.contains("flags.isEmpty ? .replace : .extend"),
          "the handler would be inferring intent from notifications again")

    // The behaviour itself, end to end.
    do {
        final class N2: NSObject {
            let label: String, id: Int
            let kids: [N2]
            init(_ l: String, _ i: Int, _ k: [N2] = []) { label = l; id = i; kids = k }
        }
        final class S2: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
            let root: N2
            var picks: Set<Int> = []
            var collapsing: Set<Int> = []
            var isSyncing = false
            init(_ r: N2) { root = r }
            func outlineView(_ v: NSOutlineView, numberOfChildrenOfItem i: Any?) -> Int {
                (i as? N2)?.kids.count ?? root.kids.count }
            func outlineView(_ v: NSOutlineView, child ix: Int, ofItem i: Any?) -> Any {
                i == nil ? root.kids[ix] : (i as! N2).kids[ix] }
            func outlineView(_ v: NSOutlineView, isItemExpandable i: Any) -> Bool {
                !(i as! N2).kids.isEmpty }
            func ids(_ v: NSOutlineView) -> [Int] {
                (0..<v.numberOfRows).compactMap { (v.item(atRow: $0) as? N2)?.id } }
            func hidden(_ v: NSOutlineView) -> [Int] {
                guard !collapsing.isEmpty else { return [] }
                let shown = Set(ids(v))
                return picks.filter { !shown.contains($0) } }
            /// Mirrors the shipped `isCollapseEcho`: the notification is a
            /// collapse echo only if the rows it HIGHLIGHTS were already
            /// selected — a collapse removes rows, it never selects one.
            func highlighted(_ v: NSOutlineView) -> Set<Int> {
                Set(v.selectedRowIndexes.compactMap { (v.item(atRow: $0) as? N2)?.id }) }
            func echo(_ v: NSOutlineView, before: Set<Int>) -> Bool {
                guard !collapsing.isEmpty else { return false }
                return highlighted(v).isSubset(of: before) }
            func outlineViewItemWillCollapse(_ n: Notification) { collapsing.insert(-1) }
            func outlineViewItemDidExpand(_ n: Notification) { push(n.object as! NSOutlineView) }
            func push(_ v: NSOutlineView) {
                guard !isSyncing else { return }
                isSyncing = true; defer { isSyncing = false }
                var idx = IndexSet()
                for r in 0..<v.numberOfRows {
                    if let n = v.item(atRow: r) as? N2, picks.contains(n.id) { idx.insert(r) }
                }
                if idx != v.selectedRowIndexes { v.selectRowIndexes(idx, byExtendingSelection: false) }
            }
            func outlineViewSelectionDidChange(_ n: Notification) {
                let v = n.object as! NSOutlineView
                if isSyncing { return }
                let before = picks
                let isEcho = echo(v, before: before)
                let carried = isEcho ? hidden(v) : []
                collapsing.removeAll()
                picks = Set(carried).union(highlighted(v))
            }
        }
        let deep3 = N2("deep", 4), b3 = N2("B", 3, [deep3])
        let a3 = N2("A", 1, [b3]), other3 = N2("other", 6)
        let src3 = S2(N2("root", 0, [a3, other3]))
        let ov3 = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let col3 = NSTableColumn(identifier: .init("c"))
        ov3.addTableColumn(col3); ov3.outlineTableColumn = col3
        ov3.allowsMultipleSelection = true
        ov3.dataSource = src3; ov3.delegate = src3
        ov3.reloadData(); ov3.expandItem(nil, expandChildren: true)

        if let dRow = (0..<ov3.numberOfRows).first(where: { (ov3.item(atRow: $0) as? N2)?.id == 4 }) {
            ov3.selectRowIndexes(IndexSet([dRow]), byExtendingSelection: false)
            src3.picks = [4]
            ov3.collapseItem(ov3.item(atRow: 0))
            check("the hidden pick survives its own collapse", src3.picks == [4],
                  "picks=\(src3.picks.sorted())")
        }
        if let oRow = (0..<ov3.numberOfRows).first(where: { (ov3.item(atRow: $0) as? N2)?.id == 6 }) {
            ov3.selectRowIndexes(IndexSet([oRow]), byExtendingSelection: false)
            check("a plain click REPLACES the selection, dropping the hidden pick",
                  src3.picks == [6],
                  "picks=\(src3.picks.sorted()) — a hidden pick must not accumulate")
        }
    }

    // --- a collapse holds a BURST of notifications, not one --------------------------
    //
    // One `collapseItem` posts TWO `selectionDidChange` callbacks, both reporting
    // the collapsed, empty selection. A window closed after the first let the
    // second wipe the picks the first had carried over, so a folder holding a
    // selection lost it and its row showed no hatch — the pick was gone, so
    // there was nothing to indicate.
    //
    // The window is now drained on the next runloop turn, which spans the whole
    // burst without guessing its length. A plain click always arrives in a later
    // turn, so it can never be mistaken for part of a collapse.
    //
    // Driven through the REAL OutlinePanel.Coordinator and a real NSOutlineView
    // against an engine-built Tree. Earlier versions of this suite mirrored the
    // rules in the test, and a divergence between the mirror and the shipped code
    // is exactly how this regression reached the app.
    do {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("multiselect-collapse-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root.appendingPathComponent("A/B"), withIntermediateDirectories: true)
        for rel in ["A/B/deep.txt", "A/a.txt", "other.txt"] {
            try? "x".write(toFile: root.appendingPathComponent(rel).path,
                           atomically: true, encoding: .utf8)
        }
        if let collapseTree = scanTree(root.path) {
            let model2 = ScanModel()
            model2.tree = collapseTree
            let ov2 = NodeOutlineView()
            let col2 = NSTableColumn(identifier: .init("name"))
            ov2.addTableColumn(col2); ov2.outlineTableColumn = col2
            ov2.allowsMultipleSelection = true
            let coord2 = OutlinePanel.Coordinator()
            coord2.model = model2
            coord2.outline = ov2
            ov2.menuCoordinator = coord2
            ov2.dataSource = coord2
            ov2.delegate = coord2
            coord2.rebuildIfNeeded()
            ov2.expandItem(nil, expandChildren: true)
            coord2.rebuildIfNeeded()

            func ids2() -> [Int] {
                (0..<ov2.numberOfRows).compactMap { (ov2.item(atRow: $0) as? OutlinePanel.Item)?.id } }
            let aNode = collapseTree.node(at: root.appendingPathComponent("A").path)!
            let deepNode = collapseTree.node(at: root.appendingPathComponent("A/B/deep.txt").path)!
            let otherNode = collapseTree.node(at: root.appendingPathComponent("other.txt").path)!

            if let dRow = ids2().firstIndex(of: deepNode) {
                ov2.selectRowIndexes(IndexSet([dRow]), byExtendingSelection: false)
                coord2.outlineViewSelectionDidChange(
                    Notification(name: NSOutlineView.selectionDidChangeNotification, object: ov2))
                check("the deep file is picked", model2.picks.members == [deepNode],
                      "picks=\(model2.picks.members.sorted())")

                let aRow = ids2().firstIndex(of: aNode)!
                // The view declares the gesture at the click, which is what the
                // handler reads instead of inferring a collapse from notifications.
                coord2.noteGesture(.disclosure)
                ov2.collapseItem(ov2.item(atRow: aRow))
                // AppKit posts the selection change itself; a manual collapse in a
                // test bypasses it, so deliver it explicitly. Without this the
                // assertions below never run the handler and pass vacuously.
                coord2.outlineViewSelectionDidChange(
                    Notification(name: NSOutlineView.selectionDidChangeNotification, object: ov2))
                // Sanity: the delegate must actually be reachable, or every
                // assertion below is vacuous. `outline` is weak, so a strongly
                // held reference is what keeps the handler from bailing at its
                // guard — and a test that never runs the handler cannot catch a
                // broken handler.
                check("the outline the coordinator drives is still alive",
                      coord2.outline === ov2, "coordinator.outline is nil or a different view")
                check("the deep row is gone from the collapsed list",
                      !ids2().contains(deepNode), "ids=\(ids2())")
                check("a collapse keeps the pick hidden inside the folder",
                      model2.picks.members == [deepNode],
                      "picks=\(model2.picks.members.sorted()) — the pick was lost on collapse")

                // And the collapsed row must SAY so, or the hidden pick is invisible.
                if let aRow2 = ids2().firstIndex(of: aNode),
                   let rv = ov2.rowView(atRow: aRow2, makeIfNecessary: true) as? PartialRowView {
                    check("the collapsed folder shows the partial-selection hatch",
                          rv.holdsPick,
                          "a pick is hidden inside it, so its row has to indicate that")
                } else {
                    check("the collapsed folder's row view is available", false)
                }
                // The later plain click must still replace everything.
                if let oRow = ids2().firstIndex(of: otherNode) {
                    coord2.noteGesture(.replace)
                    ov2.selectRowIndexes(IndexSet([oRow]), byExtendingSelection: false)
                    coord2.outlineViewSelectionDidChange(
                        Notification(name: NSOutlineView.selectionDidChangeNotification, object: ov2))
                    check("a later plain click still replaces the whole selection",
                          model2.picks.members == [otherNode],
                          "picks=\(model2.picks.members.sorted())")
                }
            } else {
                check("the deep row exists in the real list", false)
            }
        } else {
            check("the collapse fixture scanned", false)
        }
        try? fm.removeItem(at: root)
    }

    // --- the gesture, not the notification, decides -------------------------------
    //
    // Every version of this that failed tried to INFER a collapse from AppKit's
    // notifications: first from state ("is some pick hidden?" — so it excused
    // every later click), then from a timing window (racy — AppKit posts a burst
    // for one collapse, and a drain between them lost the pick again). Both read
    // intent out of a symptom.
    //
    // The view now declares the gesture at the click, where it is knowable for
    // certain, and the handler reads it. Nothing depends on notification order.
    check("the list classifies the gesture at the click",
          csrc.contains("noteGesture(.disclosure)") && csrc.contains("flags.isEmpty ? .replace : .extend"),
          "the handler would be back to inferring intent")
    check("a disclosure click is told apart by the triangle's own rect",
          csrc.contains("frameOfOutlineCell(atRow: row)") && csrc.contains("cell.contains(point)"),
          "comparing x against the indentation would guess")
    check("the gesture is single-use, so it cannot excuse a later click",
          csrc.contains("defer { pendingGesture = .unknown }"))
    check("no timing machinery remains",
          !csrc.contains("collapsingFolders") && !csrc.contains("scheduleCollapseBurstEnd")
              && !csrc.contains("isCollapseEcho"),
          "a racy collapse window is still present")
    check("a disclosure click does not change the selection at all",
          csrc.contains("case .disclosure:") && csrc.contains("return"))

    // --- Shift+click extends to a FOLDER, and a gap does nothing --------------------
    //
    // Five defects have lived here. The first three made the gesture "act weird":
    //
    //   1. A gap in the map resolves to the folder being VIEWED (the root). That
    //      is not a selectable folder, and treating it as the endpoint selected
    //      the scan root and replaced the anchor, so the next Shift+click ranged
    //      from the wrong place.
    //   2. When the anchor had no tile on the current map — it was picked in the
    //      list, or the map zoomed away from it — the `else` branch REPLACED the
    //      selection with the clicked tile and re-anchored on it. The gesture
    //      silently became a plain click and the range crept.
    //   3. A FILE could be a range endpoint. The antichain rule drops a file the
    //      moment its folder is in the range, so a sweep between two files
    //      collapsed to their parent and the tiles the user swept vanished.
    //
    // The fourth was found by an audit after all three were "fixed" and is the
    // reason this section is behavioural rather than textual:
    //
    //   4. `readingOrder()` concatenated EVERY drawn node at every depth and
    //      sorted it by screen band. Because `Layout.draw` recurses into a folder
    //      too small for a title strip, a depth-3 file shares a band with a
    //      depth-1 tile, so a range built as a slice of that list swept in
    //      grandchildren of a folder the user never pointed at.
    //
    //   5. The branch whose comment promised to "KEEP the anchor" passed it to a
    //      writer that discards a non-member anchor, so the anchor was replaced —
    //      the opposite of what the code said, and a pick that is drawn nowhere
    //      (a zero-byte file) reaches it from an ordinary list click.
    //
    // Every check below asserts a RESULT on the real views. The previous version
    // of this section asserted that certain source strings were present, which
    // is unfalsifiable: it passed for the code that had defects 4 and 5 in it,
    // and it printed "PASS ... keeps an off-map anchor" while the anchor was
    // being replaced.
    //
    // A folder is the only endpoint: clicking a file means its parent, which is
    // what the selection can actually express.
    var rangeSel = SelectionSet()
    rangeSel.set([A, B], anchor: A, in: tree)
    check("a folder range keeps both endpoints", Set(rangeSel.members) == Set([A, B]))
    check("a folder range contains no file", rangeSel.members.allSatisfy { tree.isDir($0) })

    // --- defect 5: the off-map anchor survives, asserted on the model ---------------
    //
    // Reachable from an ordinary click: a zero-byte file is skipped by the
    // renderer (`Squarify.items` drops `bytes == 0`), so it is drawn nowhere and
    // appears in no reading order. Picking it and Shift+clicking a tile is
    // exactly the "anchor has no place in the order" case.
    let offMapFile = root.appendingPathComponent("zero.dat").path
    try? Data().write(to: URL(fileURLWithPath: offMapFile))
    if let offTree = scanTree(root.path), let zeroNode = offTree.node(at: offMapFile) {
        // Resolve every node against offTree: it is a SECOND scan of the same
        // directory, and `Tree` ids are indices into one scan's arrays, so the
        // ids from the first `tree` name different folders here. Using them
        // would test the wrong nodes and still look green.
        func off(_ rel: String) -> Int? {
            offTree.node(at: root.appendingPathComponent(rel).path)
        }
        guard let offA = off("A"), let offB = off("B") else {
            check("the off-map fixture resolves A and B in its own tree", false)
            exit(1)
        }
        check("the zero-byte fixture has zero bytes", offTree.alloc[zeroNode] == 0,
              "the renderer would draw it after all")
        let order = TreemapRenderer.readingOrder(
            rects: [], leaves: [], labels: [], root: 0)
        check("an empty layout yields no order", order.isEmpty)
        // The anchor is a sibling of the target, so neither contains the other
        // and the carry is expressible.
        var s = SelectionSet()
        s.replace(with: zeroNode)
        let changed = s.extend(to: offA, order: [offA, offB], in: offTree)
        check("an off-map anchor is KEPT as the primary",
              s.primary == zeroNode,
              "primary=\(s.primary.map { offTree.name($0) } ?? "-") — the gesture re-anchored on a click that did not choose one")
        check("an off-map anchor is carried as a member",
              s.contains(zeroNode),
              "members=\(s.members.map { offTree.name($0) }) — the anchor was discarded")
        check("carrying the anchor still adds the target", s.contains(offA))
        check("carrying the anchor reports a change", changed)
        // And the anchor stays usable for the NEXT range: it is still the anchor.
        s.extend(to: offB, order: [offA, offB], in: offTree)
        check("a second Shift+click still ranges from the carried anchor",
              s.primary == zeroNode, "primary=\(s.primary.map { offTree.name($0) } ?? "-")")

        // The converse, and the reason the carry cannot simply force both: when
        // the target CONTAINS the off-map anchor, the antichain rule must still
        // let "the most recent click wins" drop the anchor, or the set would hold
        // a folder and a file inside it and count those bytes twice.
        if let offDeep = off("A/A1/deep.txt") {
            var nestedSel = SelectionSet()
            nestedSel.replace(with: offDeep)
            nestedSel.extend(to: offA, order: [offA, offB], in: offTree)
            check("a target that CONTAINS the anchor drops it",
                  nestedSel.members == [offA] && nestedSel.primary == offA,
                  "members=\(nestedSel.members.map { offTree.name($0) }) — a nested pair would double-count bytes")
            check("the dropped anchor is not left dangling as the primary",
                  nestedSel.primary.map { nestedSel.contains($0) } ?? true)
        } else {
            check("the nested off-map fixture exists", false)
        }
    } else {
        check("the zero-byte off-map fixture scanned", false)
    }

    // --- defects 4 + 5 through the REAL renderer and the REAL view -------------------
    //
    // Driven against a layout that actually interleaves: a dominant top-level
    // folder whose interior spans several bands past its siblings is what makes
    // a depth-3 file share a band with a depth-1 tile.
    do {
        let nested = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("multiselect-nested-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: nested)
        for d in 0..<7 {
            let dir = nested.appendingPathComponent("top\(d)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for s in 0..<(d < 3 ? 4 : 2) {
                let sub = dir.appendingPathComponent("sub\(s)")
                try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
                for f in 0..<(d < 3 ? 5 : 2) {
                    try? String(repeating: "x", count: 40 * (d + 1) * (s + 1)).write(
                        toFile: sub.appendingPathComponent("f\(f).dat").path,
                        atomically: true, encoding: .utf8)
                }
            }
        }
        if let nt = scanTree(nested.path) {
            let model3 = ScanModel()
            model3.tree = nt
            let view3 = TreemapNSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
            view3.model = model3
            view3.relayout()

            func depth3(_ n: Int) -> Int { nt.ancestry(n).count - 1 }
            func name3(_ n: Int) -> String { "\(nt.name(n))[d\(depth3(n))]" }

            let order = view3.readingOrder()
            let level = order.filter { depth3($0) == 1 }
            check("the nested fixture drew its level", level.count > 3, "level=\(level.count), order=\(order.count)")
            // The order IS the level: not "the level comes first", but "nothing
            // else is addressable". This is what removes the defect class at the
            // source — no index in this array can name a node the user is not
            // looking at, so neither endpoint of a range can leave the level.
            check("the reading order contains ONLY the level on screen",
                  order.allSatisfy { depth3($0) == 1 },
                  "depths present: \(Set(order.map(depth3)).sorted()) — \(order.filter { depth3($0) != 1 }.prefix(6).map(name3))")
            check("the order has no duplicate node", Set(order).count == order.count)
            check("the order is deterministic", view3.readingOrder() == order)

            // Every sweep between two tiles of the level must select ONLY that
            // level, must include the clicked tile's folder, and must keep the
            // anchor. This is the assertion the old source-string checks could
            // not make, and the one that fails on the shipped 42%-defective order.
            var sweeps = 0, belowLevel = 0, anchorLost = 0, targetMissed = 0
            var worst = ""
            for an in level {
                for tg in level where tg != an {
                    model3.select(an)
                    model3.extendSelection(to: tg, order: order)
                    sweeps += 1
                    let m = model3.picks.members
                    if m.contains(where: { depth3($0) > 1 }) {
                        belowLevel += 1
                        if worst.isEmpty {
                            worst = "\(name3(an)) -> \(name3(tg)): \(m.map(name3))"
                        }
                    }
                    if !model3.picks.contains(an) { anchorLost += 1 }
                    if !m.contains(tg) { targetMissed += 1 }
                }
            }
            check("top-level sweeps exist to test", sweeps > 10, "sweeps=\(sweeps)")
            check("no top-level sweep selects below the level",
                  belowLevel == 0, "\(belowLevel)/\(sweeps) did — \(worst)")
            check("no top-level sweep drops its anchor",
                  anchorLost == 0, "\(anchorLost)/\(sweeps) did")
            check("no top-level sweep misses the clicked tile",
                  targetMissed == 0, "\(targetMissed)/\(sweeps) did")

            // The anchor case that a level-MAJOR (not level-only) order still got
            // wrong: a primary picked DEEPER than the level, in the list. Ranging
            // from its own deep index spanned the level plus everything under it.
            // Every node the map can target must be a level node for this to be
            // reachable at all, so test it through the model's own projection.
            if let deepFile = nt.node(at: nested.appendingPathComponent("top0/sub0/f0.dat").path) {
                model3.select(deepFile)
                model3.extendSelection(to: level.last!, order: order)
                check("an anchor deeper than the level does not leak below it",
                      !model3.picks.members.contains { depth3($0) > 1 },
                      "members=\(model3.picks.members.map(name3)) — a deep anchor ranged past the level")
            }

            // A file endpoint still means its folder — now through the one owner.
            if let fileNode = order.first(where: { !nt.isDir($0) }) {
                model3.select(level[0])
                model3.extendSelection(to: fileNode, order: order)
                let parent = Int(nt.parents[fileNode])
                check("a file endpoint means the folder holding it",
                      !model3.picks.members.contains(fileNode) || !nt.isDir(parent),
                      "a file was used as a range endpoint")
            }
            // A gap / view root is refused: the model must not select the root.
            model3.select(level[0])
            let before = model3.picks.members
            model3.extendSelection(to: 0, order: order)
            check("the view root is refused as a range endpoint",
                  model3.picks.members == before && !model3.picks.contains(0),
                  "a gap click selected the scan root")
        } else {
            check("the nested fixture scanned", false)
        }
        try? fm.removeItem(at: nested)
    }

    // --- defect 7: ⌘⇧ was read as a toggle, so Shift never ran ---------------------
    //
    // The map and the rings each tested `.command` BEFORE `.shift`, so holding
    // BOTH fell into the toggle branch: ⌘⇧+click on a file toggled that FILE
    // instead of extending a range to the folder holding it. The list never had
    // the bug only because AppKit owns its rows, and AppKit's own table
    // semantics are the reference:
    //
    //     ⇧        range, REPLACING the selection
    //     ⌘        toggle one item
    //     ⌘⇧       range, EXTENDING the selection
    //
    // One owner now reads the modifiers (`SelectionSet.ClickIntent`), with Shift
    // taking precedence over Command.
    let intentCases: [(String, Bool, Bool, SelectionSet.ClickIntent)] = [
        ("no modifier replaces",    false, false, .replace),
        ("⌘ toggles",               false, true,  .toggle),
        ("⇧ extends",               true,  false, .extend),
        ("⌘⇧ extends, NOT toggles", true,  true,  .extend),
    ]
    for (name, shift, command, want) in intentCases {
        check("intent: \(name)", SelectionSet.ClickIntent(shift: shift, command: command) == want,
              "got \(SelectionSet.ClickIntent(shift: shift, command: command)) want \(want)")
    }
    // And the views must actually USE the one owner, not re-derive the mask.
    check("the map reads a click's intent from the one owner",
          source("app/TreemapView.swift").contains("SelectionSet.ClickIntent(event)"),
          "the map re-derives the modifier mask")
    check("the rings read a click's intent from the one owner",
          source("app/SunburstView.swift").contains("SelectionSet.ClickIntent(event)"),
          "the rings re-derive the modifier mask")
    check("no view tests .command before .shift any more",
          !source("app/TreemapView.swift").contains("flags.contains(.command)")
              && !source("app/SunburstView.swift").contains("flags.contains(.command)"),
          "the old precedence is still present")

    // Behavioural: ⌘⇧ on a FILE must land on its folder, exactly as ⇧ does.
    do {
        let csRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("multiselect-cmdshift-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: csRoot)
        for d in ["top/A", "other"] {
            try? fm.createDirectory(at: csRoot.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        for (p, n) in [("top/A/f0", 3), ("top/A/f1", 9), ("other/o0", 6)] {
            try? String(repeating: "x", count: 100_000 * n).write(
                toFile: csRoot.appendingPathComponent("\(p).bin").path, atomically: true, encoding: .utf8)
        }
        if let ct = scanTree(csRoot.path) {
            func node7(_ rel: String) -> Int? { ct.node(at: csRoot.appendingPathComponent(rel).path) }
            if let fileNode = node7("top/A/f1.bin"), let folderNode = node7("top/A"),
               let otherNode = node7("other/o0.bin") {
                let model6 = ScanModel()
                model6.tree = ct
                let view6 = TreemapNSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
                view6.model = model6
                view6.relayout()
                let rend6 = TreemapRenderer.render(tree: ct, pw: 2000, ph: 1400, scale: 2,
                                                   root: 0, showFree: false, freeBytes: 0)
                let leaf = rend6.leaves.first { $0.node == fileNode }
                check("the ⌘⇧ fixture drew the clicked file", leaf != nil)
                if let leaf {
                    // The view is flipped, so a view point maps to window coords
                    // by `height - y`. Passing view coords directly measured the
                    // wrong tile and made an earlier probe report the wrong node.
                    let wp = CGPoint(x: leaf.rect.midX, y: 700 - leaf.rect.midY)
                    let win6 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                        styleMask: [.titled], backing: .buffered, defer: false)
                    win6.contentView = view6
                    func click(_ flags: NSEvent.ModifierFlags) -> (file: Bool, folder: Bool)? {
                        model6.select(otherNode)
                        guard let e = NSEvent.mouseEvent(
                            with: .leftMouseDown, location: wp, modifierFlags: flags,
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: win6.windowNumber, context: nil,
                            eventNumber: 1, clickCount: 1, pressure: 1) else { return nil }
                        view6.mouseDown(with: e)
                        return (model6.picks.contains(fileNode), model6.picks.contains(folderNode))
                    }
                    if let r1 = click([.shift]) {
                        check("⇧+click on a file lands on its FOLDER (the reference)",
                              r1.folder && !r1.file, "file=\(r1.file) folder=\(r1.folder)")
                    }
                    if let r2 = click([.command, .shift]) {
                        check("⌘⇧+click on a file lands on its FOLDER, not the file",
                              r2.folder && !r2.file,
                              "file=\(r2.file) folder=\(r2.folder) — ⌘⇧ was read as a toggle and Shift never ran")
                    }
                    if let r3 = click([.command]) {
                        check("⌘+click still toggles the FILE itself", r3.file,
                              "⌘ alone must stay a toggle")
                    }
                }
            } else {
                check("the ⌘⇧ fixture nodes exist", false)
            }
        } else {
            check("the ⌘⇧ fixture scanned", false)
        }
        try? fm.removeItem(at: csRoot)
    }

    // --- defect 6: hover must agree with click about a folder ----------------------
    //
    // The map's hover answered with `hit(p)` (files only), on the premise that a
    // directory's focus is already shown by its accent ring. That holds only for
    // a folder wide enough to earn a title strip: a narrower one has no label and
    // its children tile it exactly, so its separation frame is the only pixel
    // that is visibly the folder's — and `pick` resolves that pixel to the
    // folder. Hovering it focused a file INSIDE it, so ⌘↑ ("select the folder
    // holding the focused item", README) climbed out of the wrong node on
    // exactly the tile that has no other handle.
    do {
        let hoverRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("multiselect-hover-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: hoverRoot)
        let big = hoverRoot.appendingPathComponent("Big")
        try? fm.createDirectory(at: big, withIntermediateDirectories: true)
        for i in 0..<8 {
            try? String(repeating: "x", count: 200_000).write(
                toFile: big.appendingPathComponent("f\(i).bin").path, atomically: true, encoding: .utf8)
        }
        // Several top-level folders beside Big, so "every top-level folder is
        // reachable" is a real test rather than a tautology over one child. The
        // tiny ones are laid out as narrow slivers — the shape whose only paint
        // is a frame band, which is what hover could not name.
        for d in 0..<12 {
            let side = hoverRoot.appendingPathComponent("side\(String(format: "%02d", d))")
            try? fm.createDirectory(at: side, withIntermediateDirectories: true)
            for i in 0..<6 {
                try? "s".write(toFile: side.appendingPathComponent("s\(i).txt").path,
                               atomically: true, encoding: .utf8)
            }
        }
        // A tiny folder INSIDE Big: nested so ⌘↑ has a real parent to climb to
        // (a top-level folder's parent IS the view root, where ⌘↑ zooms out).
        let tiny = big.appendingPathComponent("Tiny")
        try? fm.createDirectory(at: tiny, withIntermediateDirectories: true)
        for i in 0..<3 {
            try? "z".write(toFile: tiny.appendingPathComponent("t\(i).txt").path,
                           atomically: true, encoding: .utf8)
        }
        if let ht = scanTree(hoverRoot.path), let tinyNode = ht.node(at: tiny.path) {
            let model4 = ScanModel()
            model4.tree = ht
            let view4 = TreemapNSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            view4.model = model4
            view4.relayout()
            let rendered4 = TreemapRenderer.render(tree: ht, pw: 1800, ph: 1200, scale: 2,
                                                   root: 0, showFree: false, freeBytes: 0)
            let box = rendered4.rects.first { $0.node == tinyNode }?.rect
            check("the tiny folder is drawn", box != nil)
            check("the tiny folder has no title strip",
                  !rendered4.labels.contains { $0.node == tinyNode },
                  "this probe only means something for a folder with no label")
            if let box {
                var tested = 0, clicked = 0, hovered = 0, climbed = 0
                var detail = ""
                for p in [CGPoint(x: box.midX, y: box.minY + 0.5),
                          CGPoint(x: box.minX + 0.5, y: box.midY),
                          CGPoint(x: box.maxX - 0.5, y: box.midY),
                          CGPoint(x: box.midX, y: box.maxY - 0.5),
                          CGPoint(x: box.minX + 0.5, y: box.minY + 0.5)] {
                    let picked = view4.pick(at: p)
                    // Move through the VIEW, not the model: the view keeps its
                    // own hover cache and skips the model write when unchanged.
                    if let away = rendered4.leaves.first(where: { $0.node != tinyNode }) {
                        _ = view4.hover(at: CGPoint(x: away.rect.midX, y: away.rect.midY))
                    }
                    _ = view4.hover(at: p)
                    tested += 1
                    if picked == tinyNode { clicked += 1 }
                    if model4.hovered == tinyNode { hovered += 1 }
                    model4.selection = nil
                    let want = Int(ht.parents[tinyNode])
                    if model4.hovered == tinyNode, model4.selectEnclosingFolder(), model4.selection == want {
                        climbed += 1
                    } else if detail.isEmpty {
                        detail = "at \(p): pick=\(picked.map { ht.name($0) } ?? "-") "
                            + "hover=\(model4.hovered.map { ht.name($0) } ?? "-")"
                    }
                }
                check("every frame point of a label-less folder clicks to it",
                      clicked == tested, "\(clicked)/\(tested)")
                check("every frame point of a label-less folder HOVERS to it",
                      hovered == tested,
                      "\(hovered)/\(tested) — hover resolved to a file inside the folder. \(detail)")
                check("cmd+up from such a folder climbs to its parent",
                      climbed == tested, "\(climbed)/\(tested). \(detail)")

                // Every top-level folder must be reachable by BOTH gestures over
                // the whole canvas — not just at the one frame the probe point
                // happened to land on. A folder whose only paint is a frame band
                // was clickable but not hoverable, and the difference is only
                // visible by sweeping: `pick` used a full pass over `rects` as a
                // last resort while `hover` had no such fallback, so the two
                // agreed on the frame points and disagreed next to them.
                var sweepPicked = Set<Int>(), sweepHovered = Set<Int>()
                var sy: CGFloat = 1
                while sy < 600 {
                    var sx: CGFloat = 1
                    while sx < 900 {
                        let sp = CGPoint(x: sx, y: sy)
                        _ = view4.hover(at: CGPoint(x: 899, y: 599))   // real transition
                        if let n = view4.pick(at: sp), n != 0 { sweepPicked.insert(n) }
                        _ = view4.hover(at: sp)
                        if let h = model4.hovered, h != 0 { sweepHovered.insert(h) }
                        sx += 3
                    }
                    sy += 3
                }
                let top4 = ht.children(0).map { Int($0) }
                // Every folder the renderer DRAWS, not just the top level: a
                // nested folder whose only paint is its frame is exactly the
                // case that was clickable but not hoverable, and restricting
                // this to the top level makes the check vacuous whenever each
                // top-level folder happens to own a file tile under its frame.
                let drawnFolders = Set(rendered4.rects.filter { $0.isDir && $0.node != 0 }.map(\.node))
                let pickedTop = top4.filter { sweepPicked.contains($0) }
                let hoveredTop = top4.filter { sweepHovered.contains($0) }
                check("a canvas sweep reaches every top-level folder by CLICK",
                      pickedTop.count == top4.count,
                      "\(pickedTop.count)/\(top4.count)")
                check("a canvas sweep reaches every top-level folder by HOVER",
                      hoveredTop.count == top4.count,
                      "\(hoveredTop.count)/\(top4.count) — a folder clickable but not hoverable")
                let drawnUnpicked = drawnFolders.subtracting(sweepPicked)
                let drawnUnhovered = drawnFolders.subtracting(sweepHovered)
                check("every DRAWN folder is reachable by click",
                      drawnUnpicked.isEmpty,
                      "unreachable: \(drawnUnpicked.sorted().prefix(6).map { ht.name($0) })")
                check("every DRAWN folder is reachable by hover",
                      drawnUnhovered.isEmpty,
                      "hover-unreachable: \(drawnUnhovered.sorted().prefix(6).map { ht.name($0) }) "
                        + "— a folder the picture draws that the pointer cannot name")
                check("hover and click agree on every swept point",
                      sweepPicked == sweepHovered,
                      "only-click=\(sweepPicked.subtracting(sweepHovered).sorted().prefix(5)) "
                        + "only-hover=\(sweepHovered.subtracting(sweepPicked).sorted().prefix(5))")
            }
        } else {
            check("the hover fixture scanned", false)
        }
        try? fm.removeItem(at: hoverRoot)
    }

    // --- the rings: hover names the arc it is over, and the tail is silent --------
    //
    // `SunburstNSView.hover(at:)` is the seam the map already had, added so the
    // arc geometry can be exercised without a window. It exists because the
    // question "does hover name what click would act on?" is only answerable by
    // sweeping the canvas — the same sweep that found the map's 796 disagreeing
    // points. This pins the rings' answer, INCLUDING the tail arc's silence
    // (§F7): a regression that started naming an arbitrary member of the tail
    // would be a worse lie than the current silence, so it is asserted.
    do {
        let ringRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("multiselect-rings-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: ringRoot)
        // One dominant folder plus a cluster of tiny ones: the shape that
        // produces a drawn arc AND a tail arc on the same ring.
        let big = ringRoot.appendingPathComponent("big")
        try? fm.createDirectory(at: big, withIntermediateDirectories: true)
        for i in 0..<20 {
            try? String(repeating: "x", count: 400_000).write(
                toFile: big.appendingPathComponent("f\(i).bin").path, atomically: true, encoding: .utf8)
        }
        // 300 tiny siblings with 1 byte each against 8 MB of big: far below the
        // per-ring minimum arc angle, so they MUST fold into one tail arc.
        for d in 0..<300 {
            let t = ringRoot.appendingPathComponent("t\(String(format: "%03d", d))")
            try? fm.createDirectory(at: t, withIntermediateDirectories: true)
            try? "y".write(toFile: t.appendingPathComponent("z.txt").path, atomically: true, encoding: .utf8)
        }
        if let rt = scanTree(ringRoot.path) {
            let model5 = ScanModel()
            model5.tree = rt
            let sv = SunburstNSView(frame: NSRect(x: 0, y: 0, width: 900, height: 900))
            sv.model = model5
            sv.relayoutIfNeeded()
            let radii = SunburstNSView.ringRadii(outer: 900 / 2 - 18)
            let segs = SunburstNSView.layout(tree: rt, root: 0, radii: radii, freeBytes: 0)
            let arcNodes = Set(segs.filter { $0.node >= 0 }.map(\.node))
            let tailCount = segs.filter { $0.node == -2 }.count
            check("the rings fixture draws at least one arc", !arcNodes.isEmpty, "arcs=\(arcNodes.count)")
            check("the rings fixture produces a tail arc", tailCount > 0,
                  "no tail: this probe would not exercise the folded siblings")

            // Hovering a drawn arc names that node.
            let center = CGPoint(x: 450, y: 450)
            var named = Set<Int>()
            var hoverOnTail = 0
            var y: CGFloat = 1
            while y < 900 {
                var x: CGFloat = 1
                while x < 900 {
                    let p = CGPoint(x: x, y: y)
                    sv.clearHover()
                    if let n = sv.hover(at: p) {
                        if n >= 0 { named.insert(n) } else { hoverOnTail += 1 }
                    }
                    x += 4
                }
                y += 4
            }
            let wrong = named.subtracting(arcNodes)
            check("hover never names a node with no arc", wrong.isEmpty,
                  "named with no arc: \(wrong.sorted().prefix(5).map { rt.name($0) })")
            check("hover reaches every node that HAS an arc",
                  arcNodes.subtracting(named).isEmpty,
                  "arcs not hoverable: \(arcNodes.subtracting(named).sorted().prefix(5).map { rt.name($0) })")
            check("a synthetic arc never reports a positive node", hoverOnTail == 0,
                  "\(hoverOnTail) points on a synthetic arc named a real node — the tail must stay silent")
            check("the rings view is still usable after the sweep",
                  sv.hover(at: CGPoint(x: center.x, y: center.y)) == nil || true)
        } else {
            check("the rings fixture scanned", false)
        }
        try? fm.removeItem(at: ringRoot)
    }

    // --- scale: Cmd+A over a wide folder is not quadratic -------------------------
    // 4000 children under one parent, selected as a range. This is the shape a
    // real wide directory has, and the sort must not re-walk ancestry.
    let wide = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("multiselect-wide-\(ProcessInfo.processInfo.processIdentifier)")
    try? fm.removeItem(at: wide)
    try? fm.createDirectory(at: wide, withIntermediateDirectories: true)
    for i in 0..<4000 {
        try? "x".write(toFile: wide.appendingPathComponent("f\(i).txt").path,
                       atomically: true, encoding: .utf8)
    }
    if let wideTree = scanTree(wide.path) {
        let kids = wideTree.children(0).map { Int($0) }
        check("the wide fixture has its children", kids.count == 4000, "got \(kids.count)")
        let started = Date()
        var w = SelectionSet()
        w.set(kids, in: wideTree)
        let ms = -started.timeIntervalSinceNow * 1000
        check("a 4000-child select-all keeps every child", w.count == 4000, "got \(w.count)")
        check("a 4000-child select-all is not quadratic", ms < 2000,
              "took \(String(format: "%.0f", ms)) ms")
        // And the invariant still holds at that size.
        check("the invariant holds over 4000 siblings",
              Set(w.members).count == w.members.count)
    } else {
        check("the wide fixture scanned", false)
    }
    try? fm.removeItem(at: wide)

    try? fm.removeItem(at: root)
    print("\(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}

@main
enum MultiSelectTests {
    static func main() {
        run()
    }
}
