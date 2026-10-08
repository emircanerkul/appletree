import AppKit
import Observation

/// A folder that is safe to delete because a tool rebuilds or re-downloads
/// it on demand: package installs, build output, caches.
nonisolated struct CleanupItem: Identifiable, Sendable {
    let node: Int
    let path: String
    let display: String
    let kind: String
    let bytes: UInt64
    var id: Int { node }
}

nonisolated enum Cleanup {
    /// The Rust engine selects candidates for both the panel and JSON CLI.
    /// Swift only supplies presentation paths; rules and labels live in cleanup.rs.
    ///
    /// **The guard filters the list, so the two owners cannot disagree.** The
    /// module contract in `src/cleanup.rs` is that recognition never nominates
    /// what authorization refuses, and Rust approximates that from the tree it
    /// has. This is where the other owner's *answer* is available, so it is
    /// where the contract is enforced rather than merely intended: every
    /// consumer of this list — the panel, the planner prompt
    /// (`AgentPrompt.build(known:)`) and the sizes on the cards — sees only
    /// folders `CleanupGuard` would permit.
    ///
    /// Measured before this: on the app's default whole-disk target, 24 of 57
    /// nominees were refused by the guard, most of them under `/opt` and
    /// `/private/tmp` (outside the home by any measure), and all of them were
    /// handed to the planner as "recognised as rebuildable" (audit SW-4). A
    /// planner card for one of those is created already blocked and can never be
    /// selected, which is the "Move that can only fail" the module doc forbids.
    ///
    /// Filtering here rather than in the prompt keeps one list: a second,
    /// guard-filtered copy for the planner would let the panel and the prompt
    /// drift apart again, which is the shape of the bug being fixed.
    static func find(in tree: Tree) -> [CleanupItem] {
        let home = AppEnvironment.realHome
        return (0..<tree.cleanupCount).compactMap { index in
            let node = Int(tree.cleanupNode(index))
            let path = tree.path(node)
            // The guard is the authority; recognition may not over-offer.
            guard CleanupGuard.blockReason(path: path) == nil else { return nil }
            var display = tree.displayPath(node)
            if display.hasPrefix(home) { display = "~" + display.dropFirst(home.count) }
            return CleanupItem(node: node, path: path, display: display,
                               kind: tree.cleanupDescription(index), bytes: tree.alloc[node])
        }
    }
}

/// What became of ONE source path handed to `Trash.trash`.
///
/// The result is keyed by the *source* path because that is the identity both
/// callers already hold. `trashItem(at:resultingItemURL:)` reports the item's
/// location **inside the Trash**, so a caller that compared those URLs back
/// against its own source paths had two disjoint sets and could never see a
/// success — every folder was reported as failed, including the ones already in
/// the Trash.
nonisolated struct TrashOutcome: Sendable, Equatable {
    /// The path as the caller passed it, standardized for matching.
    let source: String
    /// Where it now sits inside the Trash, for the two-step delete.
    let trashed: URL?
    /// Why it was not moved, when it was not.
    let reason: String?

    var moved: Bool { trashed != nil }
}

/// The one trash pathway: moves each path and reports one outcome per path.
///
/// It carries the *authority* because two different things can decide a path
/// may go, and only one of them is bounded by `CleanupGuard`:
///
/// - A **planner's plan**. `CleanupGuard` re-checks it at action time, since
///   the plan was validated while streaming and minutes may have passed (S2).
///   The guard's rules — inside `$HOME`, never `~/Documents`, never a git
///   repository — are the ones under README "## AI cleanup": they bound what a
///   *planner* may nominate.
/// - **The person using the app.** The confirmation they just answered is the
///   authorization, so the guard does not apply. Applying it here was a bug: it
///   refused to trash `/Applications/Java 8 Update 491.app` with "Outside your
///   home folder", even though the app's own built-in scan targets are mostly
///   outside `$HOME` (`/Applications`, a whole drive) and macOS itself lets you
///   drag any of them to the Trash. A disk-space tool that cannot empty
///   `/Applications` is not doing its job.
nonisolated enum Trash {
    /// Who decided these paths may be moved to the Trash.
    enum Authority: Sendable {
        /// The user picked the path directly — the right-click menu, or a tick
        /// in the Clean Up panel. Their confirmation authorizes it.
        case userDirect
        /// A planner nominated it. The guard re-checks every path.
        case plannerPlan
    }

    /// Whether anything occupies `path` — the link itself counted as a thing.
    ///
    /// `lstat` does not follow the final component, so a symlink to a missing
    /// target is present here (and can be trashed), while a path that genuinely
    /// does not exist is not. `FileManager.fileExists` cannot answer this: it
    /// resolves, so a dangling link looks absent.
    nonisolated static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Move each path to the Trash, reporting one outcome per path.
    ///
    /// A path that is already gone reports "Already gone" rather than being
    /// skipped in silence: a row the user can still tick must never be a
    /// no-op with no explanation.
    static func trash(_ paths: [String], authority: Authority) async -> [TrashOutcome] {
        await Task.detached(priority: .userInitiated) {
            paths.map { path in
                let source = (path as NSString).standardizingPath
                // `lstat`, NOT `fileExists`: the latter resolves the path, so a
                // dangling symlink — a link whose target is gone, exactly the
                // dead thing a disk-space tool is asked to clean up — reads as
                // absent. Reporting "Already gone" then makes the caller treat
                // the item as removed, so the map drops the node and subtracts
                // its bytes while the link is still on disk and `trashItem`
                // would have moved it. Same non-resolving test `Erase` uses.
                guard Trash.exists(source) else {
                    return TrashOutcome(source: source, trashed: nil,
                                        reason: String(localized: "Already gone"))
                }
                if authority == .plannerPlan, let reason = CleanupGuard.blockReason(path: source) {
                    return TrashOutcome(source: source, trashed: nil, reason: reason)
                }
                do {
                    var out: NSURL?
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: source),
                                                      resultingItemURL: &out)
                    return TrashOutcome(source: source, trashed: out as URL?, reason: nil)
                } catch let failure {
                    return TrashOutcome(source: source, trashed: nil,
                                        reason: failure.localizedDescription)
                }
            }
        }.value
    }
}

/// The one permanent-deletion pathway: deletes the path itself, never the
/// Trash.
///
/// Deliberately not `trashItem`. A shortcut that quietly filled the Trash
/// instead of deleting would make "permanently" a lie and leave the bytes on disk
/// — and the user who chose it did so precisely to skip the Trash. So the
/// irreversible step is named as one, confirmed as one, and performs one.
///
/// `removefile(REMOVEFILE_RECURSIVE)` removes a file, a folder with everything
/// inside it, or a symlink (the link itself, never what it points at) with the
/// same call, which is what makes one function enough here. It is the same
/// primitive `AgentRun`'s parallel sweep uses, so "delete permanently" means one
/// thing in this app.
nonisolated enum Erase {
    /// Delete `path` permanently. Nil when it is gone, else why it is not.
    ///
    /// A path that is already absent is a *success*, not a failure: there is
    /// nothing left to delete, and the caller must still forget its node, or a
    /// removed item would sit in the map and in the totals forever. That is the
    /// one place this differs from `Trash.trash`, which reports "Already gone"
    /// because its caller lists rows the user can still tick.
    ///
    /// Existence is asked with `lstat`, never `fileExists`: `fileExists`
    /// resolves the path, so a *dangling* symlink — a link whose target is
    /// gone, which is exactly the sort of dead thing a disk-space tool is asked
    /// to clean up — reads as absent. Treating that as "already gone" reported
    /// success while the link sat on disk, so the node was cut from the map and
    /// subtracting its bytes from every total, all with nothing removed. The
    /// link owns no data, so the totals were only off by its own entry, but the
    /// item would reappear on the next scan with no sign the delete had failed.
    ///
    /// The status is the whole story on failure: `removefile` returns less than
    /// zero and does not set errno, so there is no message to read. A path that
    /// survived the call is reported; one that did not is not a failure, even
    /// with a non-zero status (a partial sweep can still leave nothing behind).
    static func erase(_ path: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let target = (path as NSString).standardizingPath
            guard exists(target) else { return nil }
            let status = removefile(target, nil, removefile_flags_t(REMOVEFILE_RECURSIVE))
            // Re-check with the same non-resolving test, or a dangling link
            // would look gone on both sides of a call that never touched it.
            guard status < 0, exists(target) else { return nil }
            return "\(target): removefile failed (\(status))"
        }.value
    }

    /// Whether anything occupies `path` — the link itself counted as a thing.
    ///
    /// `lstat` does not follow the final component, so a symlink to a missing
    /// target is present here (and can be removed), while a path that genuinely
    /// does not exist is not. That is the question a delete has to ask.
    nonisolated private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}

/// A manual cleanup batch keeps file coordination off the main actor and
/// prevents repeated clicks from moving the same captured selection twice.
@Observable
@MainActor
final class CleanupTrashBatch {
    private(set) var running = false
    /// Keep errors when the inspector closes during a background batch.
    private(set) var failures: [String] = []

    func clearFailures() { failures = [] }

    @discardableResult
    func start(_ items: [CleanupItem], completion: @escaping ([String]) -> Void) -> Task<Void, Never>? {
        guard !running else { return nil }
        running = true
        return Task {
            // The user ticked these rows in the Clean Up panel themselves: the
            // tick is the authorization, so the guard (a planner-policy bound)
            // does not apply. Those rows come from the engine's own candidate
            // list and can sit outside `$HOME` — a scan of `/Applications`
            // yields `…/node_modules` inside app bundles — and the guard would
            // refuse every one of them as "Outside your home folder".
            let outcomes = await Trash.trash(items.map(\.path), authority: .userDirect)
            // Match by SOURCE path, the identity the caller passed in. Each
            // failure carries its own reason; the batch previously shared one
            // `error` string across every row, so one blocked folder made the
            // successful ones read as blocked too.
            let bySource = Dictionary(outcomes.map { ($0.source, $0) }, uniquingKeysWith: { first, _ in first })
            let failed: [String] = items.compactMap { item in
                guard let reason = bySource[(item.path as NSString).standardizingPath]?.reason else { return nil }
                return "\(item.display): \(reason)"
            }
            failures.append(contentsOf: failed)
            running = false
            completion(failed)
        }
    }
}
