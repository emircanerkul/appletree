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
            let node = Int(tree.cleanupNodes[index])
            let path = tree.path(node)
            var display = tree.displayPath(node)
            if display.hasPrefix(home) { display = "~" + display.dropFirst(home.count) }
            return CleanupItem(node: node, path: path, display: display,
                               kind: tree.cleanupDescription(index), bytes: tree.alloc[node])
        }
    }
}

/// The one trash pathway: re-checks the guard at action time — minutes can
/// have passed since the plan was validated, so anything changed in between
/// is not acted on (S2) — and judges symlinks by where they land (S3).
nonisolated enum Trash {
    static func trash(_ paths: [String]) async -> (moved: [URL], error: String?) {
        await Task.detached(priority: .userInitiated) {
            var moved: [URL] = []
            var error: String?
            for path in paths where FileManager.default.fileExists(atPath: path) {
                if let reason = CleanupGuard.blockReason(path: path) {
                    error = error ?? reason
                    continue
                }
                do {
                    var out: NSURL?
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &out)
                    if let out { moved.append(out as URL) }
                } catch let failure {
                    error = error ?? failure.localizedDescription
                }
            }
            return (moved, error)
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
            let result = await Trash.trash(items.map(\.path))
            let failed: [String] = result.error.map { reason in
                // Only paths that did not move report a failure; the guard's
                // reason strings surface here exactly as they do for agent runs.
                let movedSet = Set(result.moved.map { ($0.path as NSString).standardizingPath })
                return items.compactMap { item in
                    movedSet.contains((item.path as NSString).standardizingPath)
                        ? nil : "\(item.display): \(reason)"
                }
            } ?? []
            failures.append(contentsOf: failed)
            running = false
            completion(failed)
        }
    }
}
