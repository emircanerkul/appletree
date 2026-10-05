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
    static func find(in tree: Tree) -> [CleanupItem] {
        let home = NSHomeDirectory()
        return (0..<tree.cleanupCount).map { index in
            let node = Int(tree.cleanupNode(index))
            let path = tree.path(node)
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

    /// Move each path to the Trash, reporting one outcome per path.
    ///
    /// A path that is already gone reports "Already gone" rather than being
    /// skipped in silence: a row the user can still tick must never be a
    /// no-op with no explanation.
    static func trash(_ paths: [String], authority: Authority) async -> [TrashOutcome] {
        await Task.detached(priority: .userInitiated) {
            paths.map { path in
                let source = (path as NSString).standardizingPath
                guard FileManager.default.fileExists(atPath: source) else {
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
