import Foundation

/// Layout weight for a set of siblings: how much of the parent's area each one
/// is given when the map or the rings lay it out.
///
/// Strictly proportional sizing has one failure mode that the map and the
/// rings both share: a sibling a thousand times smaller than its neighbour
/// rounds to a sliver no pointer can land on. A folder holding a 1.08 GB
/// `usr`, a 766 KB `Developer` and a 4 KB `Info.plist` draws the last two as
/// sub-pixel specks — visible in principle, unclickable in practice.
///
/// The rule here divides the parent's area in two pools:
///
/// * `1 - pooled` follows the bytes, so the picture still reads as "what is
///   big" — this is the pool that carries the meaning.
/// * `pooled` is split *equally* between the siblings, whatever their size.
///   A sibling's guaranteed floor is therefore `pooled / n`, which is what
///   makes the small ones land on a real, clickable area.
///
/// Written out, a sibling's weight is
///
///     w = (1 - pooled) · bytes + pooled · parentTotal / n
///
/// where `n` is how many siblings share the area while carrying bytes. Children
/// reporting 0 bytes are not part of `n` and are not laid out at all: they have
/// nothing to show, and counting them would both dilute every real sibling's
/// floor and (as the first cut of this code did) let the weights sum past the
/// folder's area. Because 0-byte children contribute nothing either way, the
/// weights over the laid-out siblings then sum to exactly `parentTotal`.
///
/// The blend is applied at *every* level, so it nests: a folder is laid out
/// among its own siblings, and its children are laid out among theirs.
///
/// Two properties the callers rely on:
///
/// * **It is only a layout weight.** Nothing displayed — the centre label
///   under the rings, a tile's tooltip, the size column in the directory
///   list — reads it. Those keep reading `Tree.alloc`, so the map shows a
///   truer picture than it draws, and the numbers never lie to make a tile
///   clickable.
/// * **It conserves the parent's used total.** `Σ w = (1 - pooled)·Σbytes +
///   pooled·parentTotal`, and `Σbytes` is `parentTotal` whenever the children
///   account for the folder (the usual case), so the sum is the folder's own
///   total and the used/free split is untouched. A caller measuring shares
///   must pass the same `n` it counts, or the sum is wrong — `make
///   test-mapweights` pins this.
///
/// ## Cost
///
/// O(1) per sibling — two multiplies and a divide, no allocation, no tree
/// walk, no sort. Each caller already visits every child once to read its
/// size, so this adds a constant amount of arithmetic per node and, in
/// particular, does **not** add a pass over a directory's children. That
/// matters: a folder can hold tens of thousands of entries, and the layouts
/// deliberately stop early at the first sibling too thin to draw. A
/// formulation that needed `Σbytes` as a separate pre-pass would walk all of
/// them; reading the parent's own total (`Tree.alloc[dir]`) keeps the *extra*
/// work proportional to what is actually drawn.

nonisolated enum ShareWeight {

    /// Share of the parent's area held back for the equal split. 0.2 gives a
    /// three-sibling folder a ~6.7% floor for each of the two small ones —
    /// comfortably clickable — while the largest still reads as dominant.
    static let pooled = 0.2

    /// Weight of one sibling, in bytes' units, so it can be handed straight to
    /// a layout that expects sizes.
    ///
    /// - Parameters:
    ///   - bytes: the sibling's own allocated bytes.
    ///   - siblings: how many siblings with bytes are laid out beside it,
    ///     including itself. Non-positive is treated as one, so a lone child
    ///     keeps the parent's full area.
    ///   - parentTotal: the parent's allocated bytes — the area being shared.
    ///     Zero yields a zero weight, which the callers treat as "nothing to
    ///     draw" rather than dividing by it.
    static func weight(bytes: UInt64, siblings: Int, parentTotal: UInt64) -> Double {
        let n = siblings > 0 ? Double(siblings) : 1
        let pool = Double(parentTotal) * pooled / n
        return (1 - pooled) * Double(bytes) + pool
    }

    /// The weight as a fraction of `parentTotal`, for callers that reason in
    /// shares rather than in layout units.
    static func share(bytes: UInt64, siblings: Int, parentTotal: UInt64) -> Double {
        guard parentTotal > 0 else { return 0 }
        return weight(bytes: bytes, siblings: siblings, parentTotal: parentTotal) / Double(parentTotal)
    }
}
