import Foundation

/// A multi-selection of tree nodes, and the ONE place its invariant lives.
///
/// ## The invariant
///
/// No member is an ancestor or descendant of another member. The set is an
/// *antichain*: picking a folder and a file inside it can never both be true.
///
/// This is not tidiness — it is what keeps the destructive actions honest. A
/// batch delete sums the bytes of what it is about to remove, and a nested pair
/// would count the child's bytes inside the parent's, reporting more space than
/// the disk can give back. It would also hand the Trash two paths where one
/// contains the other, so the second move acts on a path that no longer exists
/// and reports a spurious failure.
///
/// The rule the user sees is "the most recent click wins": picking `X` drops
/// every picked node that is an ancestor or descendant of `X`, then adds `X`.
/// So clicking a file and then its folder leaves the folder selected, and
/// clicking a folder and then a file inside it leaves the file — in both cases
/// the thing clicked last is the thing selected, and the set stays an antichain.
///
/// Every writer goes through this type. No view enforces the invariant, which is
/// what makes it hold: a fourth view added later cannot forget a rule it never
/// had to know about.
///
/// ## Identity
///
/// Nodes are integer ids into one scan's flat arrays — cheap to store and O(1)
/// to test while painting. That identity is scoped to ONE tree: a rescan
/// renumbers every id (see `Cleanup`'s header for the bug that caused when
/// ticks were kept across one), so `ScanModel` clears the selection whenever the
/// tree is replaced and calls `validate` whenever the tree is edited in place.
nonisolated struct SelectionSet: Equatable {
    /// The last node picked: the anchor for a range, and what the breadcrumbs
    /// and the status bar describe. Also the "leader" ring in the views.
    ///
    /// Kept separate from `members` because "which one am I talking about" and
    /// "which ones are selected" are different questions: a range selection of
    /// 40 items still has exactly one anchor, and that anchor is where the next
    /// Shift+click extends from.
    private(set) var primary: Int?

    /// Members in the order they were added. Order is kept because a range
    /// extends from the anchor and a status line reads better in pick order;
    /// `index` is what makes membership O(1).
    private(set) var members: [Int] = []

    /// Membership test, so painting a frame never scans `members`.
    private var index: Set<Int> = []

    init() {}

    var isEmpty: Bool { members.isEmpty }
    var count: Int { members.count }
    func contains(_ node: Int) -> Bool { index.contains(node) }

    /// Whether any member is an ancestor of `node`, or is `node` itself.
    ///
    /// The query a right-click menu needs: acting on a node that already sits
    /// inside the selection should act on the whole selection, and this is how
    /// it tells that case apart from acting on an unrelated node.
    func covers(_ node: Int, in tree: Tree) -> Bool {
        index.contains(node) || containsAncestor(of: node, in: tree)
    }

    /// Whether a member strictly *contains* `node`.
    func containsAncestor(of node: Int, in tree: Tree) -> Bool {
        for candidate in tree.ancestry(node).dropLast() where index.contains(candidate) {
            return true
        }
        return false
    }

    // MARK: - Writers

    /// Make `node` the whole selection — a plain click.
    ///
    /// `nil` clears it, which is what clicking empty space means.
    mutating func replace(with node: Int?) {
        members = node.map { [$0] } ?? []
        index = Set(members)
        primary = node
    }

    /// Cmd+click: add `node`, or remove it when it is already picked.
    ///
    /// Removing the primary hands the anchor to the most recently added
    /// survivor, so a range after an un-pick still extends from somewhere the
    /// user can see — rather than from a node that is no longer selected.
    mutating func toggle(_ node: Int, in tree: Tree) {
        if index.contains(node) {
            members.removeAll { $0 == node }
            index.remove(node)
            if primary == node { primary = members.last }
            return
        }
        addDroppingKin(node, in: tree)
    }

    /// Shift+click or Cmd+A: make these the selection.
    ///
    /// Reduced to the OUTERMOST items: a range that covers a folder and files
    /// inside it selects the folder, not the folder plus its contents. That is
    /// what a range over visible rows or tiles means to the person dragging it —
    /// they swept the folder and the things under it, and the folder already
    /// stands for all of them.
    ///
    /// The anchor is honoured only when it is still a member. A caller passes
    /// one so a range keeps the end the user did *not* click (otherwise a second
    /// Shift+click would re-range from the new free end and creep), but the
    /// anchor may have been reduced away — selecting a folder sweeps the file
    /// the range started on out of the set — and a primary that is not a member
    /// would describe an item nothing highlights. An empty set has no primary.
    ///
    /// A caller whose anchor is genuinely NOT part of the new set — the anchor
    /// has no tile on the map, so no range can reach it — must not come here and
    /// hope: this writer will discard it, and `TreemapNSView.mouseDown` did
    /// exactly that while its comment promised the opposite. That case goes
    /// through `extend(to:anchor:order:in:)`, which carries the anchor as a
    /// member the way the list already carries the picks it cannot show.
    mutating func set(_ nodes: [Int], anchor: Int? = nil, in tree: Tree) {
        let outer = Self.outermost(nodes, in: tree)
        members = outer
        index = Set(outer)
        primary = anchor.flatMap { outer.contains($0) ? $0 : nil } ?? outer.last
    }

    /// Shift+click: extend to `target`, ranging over the order the CALLER draws.
    ///
    /// The one owner of the gesture, because its four parts must agree or the
    /// view silently does something else — and they were previously copied into
    /// the map and the rings by hand, where a fix applied to one did not reach
    /// the other, and a comment in one described behaviour the code did not have:
    ///
    ///   1. The endpoint is normalised to a FOLDER. A folder stands for
    ///      everything inside it, so a file's tile cannot be a range endpoint —
    ///      the antichain rule drops the file the moment its folder is included,
    ///      and the swept tiles silently vanished.
    ///   2. The endpoint may not be the view root. That is the map itself, not a
    ///      selectable folder: a click in a GAP resolves to it, because the gaps
    ///      between tiles belong to the viewed folder's box. Selecting it would
    ///      replace the anchor and make every later range start in the wrong
    ///      place, which is what made Shift+click read as "acting weird".
    ///   3. With an anchor that has a place in `order`, the range is the slice
    ///      between the two, and the anchor stays the end the user did NOT click
    ///      so a second Shift+click re-ranges instead of creeping.
    ///   4. With an anchor that has NO place in `order` — it was picked in the
    ///      list, it is a file the renderer skips (zero bytes are drawn nowhere),
    ///      or the map has zoomed away from it — the anchor is CARRIED, and only
    ///      then is the target picked. Discarding it instead made the gesture a
    ///      plain click that quietly re-anchored on a node the user never chose.
    ///
    /// Both endpoints are expressed on the SURFACE the caller draws, and that is
    /// what `order` is: the nodes addressable at the level on screen. A primary
    /// picked in the LIST can sit several levels below the folder the map shows,
    /// so `surfaceProjection` maps it to the tile that represents it there — the
    /// range the user can actually see. Ranging from the anchor's own id instead
    /// would name a node absent from `order` (no range at all) or, if `order`
    /// held every depth as an earlier version did, span the level AND everything
    /// under it, which is the escape this gesture was fixed for.
    ///
    /// Carrying the anchor in case 4 is the rule the directory list already
    /// follows for the picks it cannot render: a selection change in one view
    /// must not discard what another view — or an unreachable node — holds. It
    /// is not a violation of the antichain invariant: `outermost` only drops a
    /// node when a LISTED ancestor is present, and the target was reduced
    /// against the carried anchor, so neither contains the other.
    ///
    /// Returns whether the selection changed, so a caller can skip a redraw.
    @discardableResult
    mutating func extend(to node: Int, order: [Int], in tree: Tree) -> Bool {
        guard let anchor = primary else {
            // Nothing is selected: this click is the anchor, reduced like any
            // other one so a swept folder cannot bring its children with it.
            set([node], in: tree)
            return true
        }
        // Both ends are expressed on the surface the caller draws. The target is
        // already a folder; the anchor is projected onto `order`, so an anchor
        // below the surface ranges from that surface's own tile rather than from
        // a deep index, and an anchor with no place there at all falls through.
        let from = Self.surfaceProjection(of: anchor, order: order, in: tree)
        if let to = order.firstIndex(of: node), let from, let at = order.firstIndex(of: from) {
            let range = at <= to ? Array(order[at...to]) : Array(order[to...at])
            set(range, anchor: from, in: tree)
            return true
        }
        // The anchor is not on this surface: keep it, and add the target to it.
        // `set` cannot express this — it would drop the anchor as a non-member —
        // so the carry is stated here, once, for every view.
        let outer = Self.outermost([anchor, node], in: tree)
        // The anchor is kept as the primary only when it SURVIVED the reduction.
        // A target that CONTAINS the anchor — a file inside the folder now being
        // swept to — must still win, or the set would hold a folder and a file
        // inside it, count those bytes twice, and leave a primary that describes
        // an item nothing highlights. That is the one rule every writer here
        // obeys, and it is why the carry is a member-level decision, not a flag.
        let kept = outer.contains(anchor) ? anchor : outer.last
        guard outer != members || kept != primary else { return false }
        members = outer
        index = Set(outer)
        primary = kept
        return true
    }

    /// The folder a Shift+click endpoint means: itself when it is a folder,
    /// else the folder holding it. Nil when there is no folder to name — the
    /// scan root has no parent (the `UInt32.max` sentinel).
    ///
    /// One owner, because the map and the rings must read the same click the
    /// same way, and a file endpoint is not a thing this selection can express.
    static func folderEndpoint(for node: Int, in tree: Tree) -> Int? {
        let target = tree.isDir(node) ? node : Int(tree.parents[node])
        return target == Int(UInt32.max) ? nil : target
    }

    /// What a click's modifier keys ask for.
    ///
    /// One owner, because the map and the rings each used to test `.command`
    /// BEFORE `.shift` — so ⌘⇧+click fell into the toggle branch and Shift never
    /// ran. The list did not have the bug only because AppKit owns its rows, and
    /// AppKit's own table semantics are the reference this must match:
    ///
    ///     ⇧        range, REPLACING the selection
    ///     ⌘        toggle one item
    ///     ⌘⇧       range, EXTENDING the selection
    ///
    /// The precedence is therefore Shift first, not Command first: `⌘⇧` is a
    /// range gesture, and treating Command as the outer test silently degrades
    /// it to a toggle of the item under the pointer — which is exactly the
    /// report "it keeps selecting the specific item I click, not the folder".
    ///
    /// Deliberately takes plain Bools rather than `NSEvent.ModifierFlags`: this
    /// file imports only Foundation, so the whole selection algebra stays
    /// testable without AppKit, and the one place that knows about events
    /// (`RemovalKeys`' neighbour in the view layer) does the extraction.
    ///
    /// `.option` and `.control` are not read. Control+click is the platform's
    /// secondary click, so it arrives at `rightMouseDown` and never reaches a
    /// selection branch; reading it here would be dead code that looks
    /// meaningful. `.capsLock`, `.function` and `.numericPad` are hardware or
    /// sticky state and must not veto a gesture.
    enum ClickIntent: Equatable {
        /// No additive modifier: this click replaces the selection.
        case replace
        /// ⌘ alone: toggle this one item.
        case toggle
        /// ⇧, with or without ⌘: extend a range from the current anchor.
        case extend

        /// Shift wins over Command on purpose — see the type's note.
        init(shift: Bool, command: Bool) {
            if shift { self = .extend }
            else if command { self = .toggle }
            else { self = .replace }
        }
    }

    /// Where `node` appears on a surface that draws `order`, or nil when it has
    /// no place there at all.
    ///
    /// The range gesture's endpoints must both be expressible on the surface the
    /// user is pointing at. A node BELOW that surface is represented by the
    /// surface's own tile that contains it: a deep file picked in the list, then
    /// a Shift+click in the map, ranges from the map tile standing for the folder
    /// holding that file — the level range the user can see. Ranging from the
    /// file's own index instead is impossible (it is not in `order`) and ranging
    /// from its raw id would span the level PLUS everything under it, which is
    /// the escape this whole gesture was fixed for.
    ///
    /// Shallowest match wins, because `ancestry` is root-first: the first
    /// ancestor present in `order` is the surface's representative, not a deeper
    /// node that happens to share the array.
    static func surfaceProjection(of node: Int, order: [Int], in tree: Tree) -> Int? {
        let onSurface = Set(order)
        guard !onSurface.isEmpty else { return nil }
        for candidate in tree.ancestry(node) where onSurface.contains(candidate) { return candidate }
        return nil
    }

    /// Drop every member, and the anchor with them.
    mutating func clear() {
        members = []
        index = []
        primary = nil
    }

    /// Forget members whose node no longer hangs off the root.
    ///
    /// Called after an in-place removal. `Tree.removeNode` detaches a whole
    /// subtree by cutting one link, so a removed folder's descendants stop
    /// being attached without being individually touched — checking attachment
    /// therefore drops the removed node and everything that was under it in one
    /// pass, with no second tree walk.
    mutating func validate(in tree: Tree) {
        guard !members.isEmpty else { return }
        let kept = members.filter { tree.isAttached($0) }
        guard kept.count != members.count else { return }
        members = kept
        index = Set(kept)
        if let p = primary, !tree.isAttached(p) { primary = kept.last }
    }

    /// Every DRAWN node a selection should light up.
    ///
    /// A picked folder stands for everything inside it — that is what a Delete
    /// removes and what the byte total counts — so the picture must say what the
    /// action will do. Outlining only the folder's own shape left a selected
    /// parent looking like a single arc while its whole subtree was about to go,
    /// and made Cmd+A read as "only the first ring is selected".
    ///
    /// `candidates` is what the view actually draws, which is bounded by the
    /// window rather than by the scan. The test walks each candidate's ancestry
    /// and checks it against the picked set, so the cost is
    /// `O(drawn × depth)` — independent of how many items are selected, which
    /// matters because Cmd+A can select thousands of folders at once.
    static func litShapes(picked: [Int], candidates: [Int], in tree: Tree) -> [Int] {
        guard !picked.isEmpty, !candidates.isEmpty else { return [] }
        let index = Set(picked)
        return candidates.filter { candidate in
            index.contains(candidate)
                || tree.ancestry(candidate).dropLast().contains(where: { index.contains($0) })
        }
    }

    /// Whether `outer` is a strict ancestor of `inner`.
    static func contains(_ outer: Int, _ inner: Int, in tree: Tree) -> Bool {
        outer != inner && tree.ancestry(inner).dropLast().contains(outer)
    }

    // MARK: - Collapsed parents

    /// Whether a member lies strictly inside `folder`, i.e. the folder is
    /// collapsed over a pick and has to say so.
    ///
    /// The list shows a collapsed folder as one row, so a selection inside it
    /// would be invisible: the row has to look partly chosen, because collapsing
    /// hides a pick without cancelling it. Delete still removes it, and the
    /// byte total still counts it.
    func holdsPick(inside folder: Int, in tree: Tree) -> Bool {
        members.contains { $0 != folder && tree.ancestry($0).dropLast().contains(folder) }
    }

    /// The members that live inside `folder` (strictly), shallowest first.
    ///
    /// What the list expands to when a pick has to become visible again.
    func picks(inside folder: Int, in tree: Tree) -> [Int] {
        members.filter { $0 != folder && tree.ancestry($0).dropLast().contains(folder) }
    }

    /// The members with any that contains another removed, for an action that
    /// must not act on a path twice.
    ///
    /// Defensive, not load-bearing: the invariant already guarantees an
    /// antichain, so this returns `members` unchanged in every reachable state.
    /// It exists because the cost of being wrong is not symmetric — a duplicated
    /// containment would delete a folder and then report its child as a failure,
    /// so the action checks rather than trusting an invariant it cannot see.
    func containmentDeduped(in tree: Tree) -> [Int] {
        Self.outermost(members, in: tree)
    }

    // MARK: - The two rules, in one place

    /// Add `node`, dropping every member it contains or is contained by.
    ///
    /// The "most recent click wins" rule, and the only writer that can move the
    /// set away from `replace`. Both directions are needed: picking a parent
    /// must drop selected children (or the parent's bytes double-count them),
    /// and picking a child must drop a selected parent (or the parent would be
    /// reported as selected while the ring sits on something inside it).
    ///
    /// A single pass suffices because the set is already an antichain: no two
    /// members contain each other, so for any member `m` at least one of these
    /// holds — `m` is an ancestor of `node`, `m` is a descendant of `node`, or
    /// they are unrelated — and dropping every member where the first two hold
    /// cannot break a relationship between two survivors.
    private mutating func addDroppingKin(_ node: Int, in tree: Tree) {
        let chain = Set(tree.ancestry(node))
        members.removeAll { other in
            other != node && (chain.contains(other) || tree.ancestry(other).contains(node))
        }
        index = Set(members)
        members.append(node)
        index.insert(node)
        primary = node
    }

    /// Reduce a list of nodes to those that no other listed node contains.
    ///
    /// Outermost wins: the folder, not the folder plus what is inside it. Ties
    /// and duplicates are dropped, and the caller's order is preserved so the
    /// result reads in pick order.
    ///
    /// Shallowest first, so an ancestor is always already kept when its
    /// descendant is considered — one pass, no fixpoint. Depth and ancestry are
    /// each computed once per node rather than per comparison: Cmd+A on a wide
    /// folder runs this over every child, and re-walking ancestry inside a sort
    /// comparator would be `O(n log n)` walks for an answer that needs `n`.
    static func outermost(_ nodes: [Int], in tree: Tree) -> [Int] {
        var seen = Set<Int>()
        let unique = nodes.filter { seen.insert($0).inserted }
        guard unique.count > 1 else { return unique }

        // One ancestry walk per node, kept in ORDER for the containment tests:
        // `ancestry` returns root-first, so `dropLast()` drops the node itself
        // and leaves exactly its ancestors. A `Set` here would be a bug — the
        // ordering is what makes "who contains whom" answerable, and `dropLast`
        // on an unordered set removes an arbitrary element instead.
        var chains: [Int: [Int]] = [:]
        chains.reserveCapacity(unique.count)
        for node in unique { chains[node] = tree.ancestry(node) }

        var kept: [Int] = []
        var keptSet = Set<Int>()
        for node in unique.sorted(by: { (chains[$0]?.count ?? 0) < (chains[$1]?.count ?? 0) }) {
            let ancestors = (chains[node] ?? []).dropLast()
            if !ancestors.contains(where: { keptSet.contains($0) }) {
                kept.append(node)
                keptSet.insert(node)
            }
        }
        // Back to the caller's order: depth order is an implementation detail.
        return unique.filter { keptSet.contains($0) }
    }
}
