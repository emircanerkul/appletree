import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - What the agent is told

nonisolated enum AgentPrompt {
    /// The flat tree orders siblings by size and includes descendants in
    /// each directory's total. Small subtrees cannot contribute a row.
    static func largestNodes(in tree: Tree) -> (folders: [Int], files: [Int]) {
        var folders: [Int] = []
        var files: [Int] = []
        var stack = [0]
        while let parent = stack.popLast() {
            for raw in tree.children(parent) {
                let i = Int(raw), size = tree.alloc[i]
                guard size >= 100_000_000 else { break }
                if tree.isDir(i) {
                    stack.append(i)
                    // Still descend through pass-through folders: only their
                    // redundant table row is omitted.
                    if let first = tree.children(i).first, tree.isDir(Int(first)),
                       Double(tree.alloc[Int(first)]) >= 0.95 * Double(size) { continue }
                    folders.append(i)
                } else if size >= 250_000_000 {
                    files.append(i)
                }
            }
        }
        // The original scan-order sort was stable. Preserve its node-ID
        // order for ties even though traversal now follows the hierarchy.
        func larger(_ a: Int, _ b: Int) -> Bool {
            tree.alloc[a] == tree.alloc[b] ? a < b : tree.alloc[a] > tree.alloc[b]
        }
        folders.sort(by: larger)
        files.sort(by: larger)
        return (Array(folders.prefix(250)), Array(files.prefix(80)))
    }

    static func build(tree: Tree, scanRoot: String, known: [CleanupItem], running: [String]) -> String {
        let home = NSHomeDirectory()
        func shown(_ i: Int) -> String { tree.displayPath(i) }

        let (folders, files) = largestNodes(in: tree)

        // The command list reads straight from the Rust-owned allowlist so
        // the prompt can never drift from what the guard actually accepts.
        // The one-argument forms stay literal: they have placeholders, not
        // allowlist entries.
        let allowlist = CleanupGuard.allowlistCommands.map { "`\($0)`" }.joined(separator: ", ")
        var md = """
        You are the cleanup agent inside AppleTree, a macOS disk-space app. The user clicked \
        "Clean up" and is watching a live view of your steps, so be fast. Their home folder is \(home).

        Below is AppleTree's scan (\(scanRoot == "/System/Volumes/Data" ? "whole disk" : scanRoot), \
        allocated sizes, measured seconds ago). Use it; do not re-scan the disk. Most plans need no \
        commands at all. Only check what you really cannot judge from the tables, batched (one \
        `du -sk a b c` beats several), at most 3 commands.

        Return a cleanup plan as JSON (the schema is enforced):
        - summary: one short sentence, e.g. "About 44 GB of caches and build output can go."
        - items, largest first, at most 12. Each item:
          - title: 2-5 plain words ("uv package cache", "Old Playwright browsers").
          - detail: why it is safe, under 90 characters, plain English.
          - group: "safe" = rebuilt or re-downloaded automatically, nothing lost; "ask" = probably \
        fine but the user should decide (old downloads, models, whole old projects).
          - bytes: size in bytes.
          - paths: the absolute paths it covers.
          - action: "command" when the owning tool has its own cleanup and the item is that tool's \
        cache, otherwise "trash" (AppleTree moves the paths to the Trash itself). AppleTree only runs \
        exactly one of these commands — no extra arguments or flags: \(allowlist) — \
        or exactly one of: `ollama rm <model>`, `xcrun simctl runtime delete <id>`, \
        `xcrun simctl erase <udid>`. \
        Nothing else, no pipes, `;`, `$` or globs; it must not prompt.          - command: the exact command for "command", "" for "trash".
        `npm cache clean` only empties ~/.npm/_cacache; ~/.npm/_npx is a separate "trash" item. Only \
        list caches that appear in the tables above with their real size; skip ones that are not there.
        Name specific folders. Never a whole ~/Library, ~/Library/Caches, ~/Library/Application \
        Support, ~/Library/Containers, ~/Downloads or ~/.config: list the large subfolders instead.
        Never include: ~/Documents, ~/Desktop, ~/Pictures, the Photos library, ~/Movies, ~/Music, Mail, \
        Messages, iCloud Drive (~/Library/Mobile Documents), keychains, ~/.ssh, dotfile configs, source \
        code, git repositories themselves, or files of the running apps below. Build output inside \
        projects (node_modules, target, .next, dist, DerivedData) is fine, and so are the Codex chat \
        folders and Xcode simulators listed at the end.

        ## Apps running now
        \(running.joined(separator: ", "))

        """
        if !known.isEmpty {
            md += "\n## Recognised by AppleTree as rebuildable\n\n| Size | Path | What |\n|---:|---|---|\n"
            for item in known.prefix(120) {
                md += "| \(Fmt.size(item.bytes)) | \(item.path) | \(item.kind) |\n"
            }
        }
        md += "\n## Largest folders\n\n| Size | Files | Path |\n|---:|---:|---|\n"
        for i in folders.prefix(250) {
            md += "| \(Fmt.size(tree.alloc[i])) | \(Fmt.num(UInt64(tree.nFiles[i]))) | \(shown(i))/ |\n"
        }
        if !files.isEmpty {
            md += "\n## Largest files\n\n| Size | Path |\n|---:|---|\n"
            for i in files.prefix(80) { md += "| \(Fmt.size(tree.alloc[i])) | \(shown(i)) |\n" }
        }
        return md
    }

    /// Big folders the scan alone can't explain: Xcode's simulators (runtime
    /// images live outside the home folder and go only through `simctl`) and
    /// the Codex app's chat folders, which sit in the otherwise off-limits
    /// ~/Documents. Listed with what the agent needs to plan them.
    static func appData(tree: Tree) -> String {
        // simctl and Codex's logs are independent: look them up side by side.
        let sims = OutputText()
        let done = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: done) { sims.set(Data(simulators().utf8)) }
        let chats = codexChats(tree: tree)
        done.wait()
        return sims.value + chats
    }

    private static func ago(_ date: Date?) -> String {
        guard let date else { return "never" }
        let days = Int(Date().timeIntervalSince(date) / 86400)
        return days < 1 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
    }

    private static func simulators() -> String {
        // Run simctl straight from the selected Xcode: /usr/bin/xcrun would
        // offer to install the command line tools on a Mac without them.
        let developer = AgentLocator.run("/usr/bin/xcode-select", ["-p"]).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let simctl = developer + "/usr/bin/simctl"
        guard !developer.isEmpty, FileManager.default.isExecutableFile(atPath: simctl) else { return "" }
        func json(_ args: [String]) -> [String: Any] {
            let text = AgentLocator.run(simctl, args, timeout: 10).out
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        }
        func date(_ any: Any?) -> Date? { (any as? String).flatMap { try? Date($0, strategy: .iso8601) } }

        var runtimes = ""
        let images = json(["runtime", "list", "-j"]).values.compactMap { $0 as? [String: Any] }
        for image in images.sorted(by: { ($0["sizeBytes"] as? Int64 ?? 0) > ($1["sizeBytes"] as? Int64 ?? 0) }) {
            guard let id = image["identifier"] as? String, image["deletable"] as? Bool ?? true,
                  let size = image["sizeBytes"] as? Int64, size >= 100_000_000 else { continue }
            // "com.apple.CoreSimulator.SimRuntime.iOS-27-0" → "iOS"
            let platform = (image["runtimeIdentifier"] as? String)?.split(separator: ".").last?
                .split(separator: "-").first.map(String.init) ?? "Simulator"
            let version = image["version"] as? String ?? ""
            runtimes += "| \(Fmt.size(UInt64(size))) | \(platform) \(version) | \(ago(date(image["lastUsedAt"]))) "
                + "| \(id) | \(image["path"] as? String ?? "") |\n"
        }

        var devices = ""
        let byRuntime = json(["list", "devices", "-j"])["devices"] as? [String: Any] ?? [:]
        let all = byRuntime.values.flatMap { $0 as? [[String: Any]] ?? [] }
        for device in all.sorted(by: { ($0["dataPathSize"] as? Int64 ?? 0) > ($1["dataPathSize"] as? Int64 ?? 0) }) {
            guard let udid = device["udid"] as? String, let data = device["dataPath"] as? String,
                  let size = device["dataPathSize"] as? Int64, size >= 100_000_000 else { continue }
            let folder = (data as NSString).deletingLastPathComponent
            let state = device["state"] as? String ?? ""
            devices += "| \(Fmt.size(UInt64(size))) | \(device["name"] as? String ?? "") (\(state)) "
                + "| \(ago(date(device["lastUsedAt"]))) | \(udid) | \(folder) |\n"
        }
        guard !runtimes.isEmpty || !devices.isEmpty else { return "" }

        var md = """

        ## Xcode simulators

        Simulator runtimes are system images Xcode downloads again when a simulator needs one. Plan \
        each as its own item: action "command", command `xcrun simctl runtime delete <id>`, paths = \
        [its path], group "safe" if unused for 30+ days, else "ask". Device data is one simulator's \
        installed apps and files: action "command", command `xcrun simctl erase <udid>` (empties it, \
        the device stays), paths = [its folder], group "ask". Never trash simulator folders directly.

        """
        if !runtimes.isEmpty {
            md += "\n| Size | Runtime | Last used | Id | Path |\n|---:|---|---|---|---|\n" + runtimes
        }
        if !devices.isEmpty {
            md += "\n| Size | Device | Last used | UDID | Folder |\n|---:|---|---|---|---|\n" + devices
        }
        return md
    }

    private static func codexChats(tree: Tree) -> String {
        let root = NSHomeDirectory() + "/Documents/Codex"
        guard let codex = tree.node(at: root) else { return "" }
        var chats: [(node: Int, path: String)] = []
        for day in tree.children(codex).map(Int.init) {
            guard tree.alloc[day] >= 100_000_000 else { break }
            let dayPath = root + "/" + tree.name(day)
            for chat in tree.children(day).map(Int.init) {
                guard tree.alloc[chat] >= 100_000_000 else { break }
                let path = dayPath + "/" + tree.name(chat)
                if tree.isDir(chat), CleanupGuard.codexChat(path) == path { chats.append((chat, path)) }
            }
        }
        guard !chats.isEmpty else { return "" }
        chats.sort { tree.alloc[$0.node] > tree.alloc[$1.node] }

        var md = """

        ## Codex chat folders

        The Codex app keeps each chat's files in ~/Documents/Codex/<date>/<chat>: `outputs` holds what \
        the chat produced (exports, downloads, renders), `work` its scratch files. Nothing recreates \
        them, so group "ask", action "trash". One item per chat over 1 GB, titled from the chat name \
        with its date in the detail; smaller ones may share one item. The chat folder or its \
        `outputs`/`work` subfolders are valid paths. AppleTree keeps chats used in the last 2 days.

        | Size | Chat | Last used | Inside |
        |---:|---|---|---|

        """
        let sessions = CodexSessions.lastActive()
        for (node, path) in chats.prefix(40) {
            let used = sessions.filter { $0.key == path || $0.key.hasPrefix(path + "/") }.values.max()
            let inside = tree.children(node).prefix(3).map { "\(tree.name(Int($0))) \(Fmt.size(tree.alloc[Int($0)]))" }
            md += "| \(Fmt.size(tree.alloc[node])) | \(path) | \(used.map(ago) ?? "unknown") | \(inside.joined(separator: ", ")) |\n"
        }
        return md
    }
}
