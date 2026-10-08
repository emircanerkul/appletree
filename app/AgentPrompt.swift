import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - What the planner is told

nonisolated enum AgentPrompt {
    /// Whether `i` is an installed application bundle.
    ///
    /// Its whole subtree is withheld from the tables below. A bundle is sealed
    /// by its code signature, so anything inside it is off limits
    /// (`CleanupGuard` refuses it as "Inside a signed app bundle"), and the
    /// planner must never be invited to nominate it — a card that can only be
    /// blocked is a Move the user cannot act on. The name alone is not enough:
    /// macOS names containers `com.example.app`, which are ordinary folders.
    ///
    /// Both bundle layouts count, matching `CleanupGuard.isBundle`: the classic
    /// `Contents/Info.plist`, and the flat iOS/Unity wrapper whose
    /// `Info.plist` sits at the bundle root (`/Applications/ARES.app` wraps one
    /// at `Wrapper/ARES.app`).
    static func isAppBundle(_ tree: Tree, _ i: Int) -> Bool {
        guard tree.isDir(i), tree.name(i).hasSuffix(".app") else { return false }
        for child in tree.children(i) {
            let name = tree.name(Int(child))
            if name == "Info.plist" { return true }
            if name == "Contents",
               tree.children(Int(child)).contains(where: { tree.name(Int($0)) == "Info.plist" }) {
                return true
            }
        }
        return false
    }

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
                    // A bundle and its whole subtree stay out of the tables,
                    // the bundle's own row included. Keeping the row was worse
                    // than useless: `/Applications/Xcode.app` is the largest
                    // thing there, so listing it invited the planner to
                    // nominate a sealed bundle, and the guard then refused the
                    // card — the user sees an option they cannot select, which
                    // is the very complaint this withholds. Nothing inside a
                    // bundle is ever cleanable, so there is no row to offer.
                    if isAppBundle(tree, i) { continue }
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

    /// `commandsAvailable` says whether this build can run a cleanup command at
    /// all. The App Store build cannot: the sandbox denies `exec`, so every
    /// allowlisted form dies and its card reports success while the bytes stay
    /// on disk. Offering one is therefore worse than offering nothing, and the
    /// planner is told the reason in words rather than left to infer it from an
    /// empty list — a planner given no list and no reason invents command items.
    ///
    /// The list itself still reads straight from the Rust-owned allowlist, so
    /// the prompt cannot drift from what the guard accepts. The one-argument
    /// forms stay literal: they have placeholders, not allowlist entries.
    static func build(tree: Tree, scanRoot: String, known: [CleanupItem], running: [String],
                      commandsAvailable: Bool = true) -> String {
        let home = AppEnvironment.realHome
        func shown(_ i: Int) -> String { tree.displayPath(i) }

        let (folders, files) = largestNodes(in: tree)

        let allowlist = CleanupGuard.allowlistCommands.map { "`\($0)`" }.joined(separator: ", ")
        let action: String
        if commandsAvailable {
            action = """
            - action: "command" when the owning tool has its own cleanup and the item is that tool's \
            cache, otherwise "trash" (AppleTree moves the paths to the Trash itself). AppleTree only runs \
            exactly one of these commands — no extra arguments or flags: \(allowlist) — \
            or exactly one of: `ollama rm <model>`, `xcrun simctl runtime delete <id>`, \
            `xcrun simctl erase <udid>`. \
            Nothing else, no pipes, `;`, `$` or globs; it must not prompt.          - command: the exact command for "command", "" for "trash".
            `npm cache clean` only empties `~/.npm/_cacache`; `~/.npm/_npx` is a separate "trash" item. Only \
            list caches that appear in the tables above with their real size; skip ones that are not there.
            """
        } else {
            action = """
            - action: always "trash". This build runs inside the App Store sandbox, which forbids \
            launching any external tool, so AppleTree cannot run a cleanup command at all and no \
            "command" item could be honoured — the card would silently do nothing. Every item is a \
            folder AppleTree moves to the Trash itself. \
            Do not propose a command, a shell invocation, or a tool's own cleanup flag; nominate the \
            cache folder instead.          - command: always "".
            Only list caches that appear in the tables above with their real size; skip ones that are not there.
            """
        }
        var md = """
        You are the cleanup agent inside AppleTree, a macOS disk-space app. The user clicked \
        "Clean up" and is watching a live view of your steps, so be fast. Their home folder is \(home).

        Below is AppleTree's scan (\(scanRoot == "/System/Volumes/Data" ? "whole disk" : scanRoot), \
        allocated sizes, measured seconds ago). Use it; do not re-scan the disk. Most plans need no \
        commands at all. Only check what you really cannot judge from the tables, batched (one \
        `du -sk a b c` beats several), at most 3 commands.

        Return a cleanup plan as JSON. The reply is requested in JSON mode only, so these field \
        names and shapes are what gives it structure; follow them exactly:
        - summary: one short sentence, e.g. "About 44 GB of caches and build output can go."
        - items, largest first, at most 12. Each item:
          - title: 2-5 plain words ("uv package cache", "Old Playwright browsers").
          - detail: why it is safe, under 90 characters, plain English.
          - group: "safe" = rebuilt or re-downloaded automatically, nothing lost; "ask" = probably \
        fine but the user should decide (old downloads, models, whole old projects).
          - bytes: size in bytes.
          - paths: the absolute paths it covers.
          \(action)
        Name specific folders. Never a whole ~/Library, ~/Library/Caches, ~/Library/Application \
        Support, ~/Library/Containers, ~/Downloads or ~/.config: list the large subfolders instead.
        Never include: ~/Documents, ~/Desktop, ~/Pictures, the Photos library, ~/Movies, ~/Music, Mail, \
        Messages, iCloud Drive (~/Library/Mobile Documents), keychains, ~/.ssh, dotfile configs, source \
        code, git repositories themselves, or files of the running apps below. Build output inside \
        projects (node_modules, target, .next, dist, DerivedData) is fine, and so are the Xcode \
        simulators listed at the end.

        ## Apps running now
        \(running.joined(separator: ", "))

        """
        if !known.isEmpty {
            md += "\n## Recognised by AppleTree as rebuildable\n\n| Size | Path | What |\n|---:|---|---|\n"
            for item in known.prefix(120) {
                md += "| \(Fmt.size(item.bytes)) | \(item.path) | \(item.label) |\n"
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

    /// Big folders the scan alone can't explain: Xcode's simulators, whose
    /// runtime images live outside the home folder and go only through
    /// `simctl`. Listed with what the planner needs to plan them — but only
    /// what the scan actually covered.
    ///
    /// `tree` is the scanned tree, and it is what decides: a row is kept only
    /// when its path resolves in that tree. `simctl` reports paths that are
    /// real on the machine but sit outside a folder scan, and handing those to
    /// the planner on an `/Applications` scan produced a plan of nothing but
    /// `/System/Library/AssetsV2/…` simulator runtimes — cards for folders the
    /// user never scanned, in a panel headed "Here's the plan" for the folder
    /// they did scan. Every path offered must be one the scan reached.
    static func appData(tree: Tree) -> String {
        simulators(tree: tree)
    }

    private static func ago(_ date: Date?) -> String {
        guard let date else { return "never" }
        let days = Int(Date().timeIntervalSince(date) / 86400)
        return days < 1 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
    }

    /// The `.asset` folder a runtime's reported path belongs to.
    ///
    /// `simctl runtime list -j` reports
    /// `…/com_apple_MobileAsset_iOSSimulatorRuntime/<hash>.asset/AssetData/Restore/<n>.dmg`.
    /// The plan names the whole asset folder — `xcrun simctl runtime delete`
    /// takes the runtime and removes that — so coverage is judged on it. Paths
    /// with no `.asset` component yield "" and are treated as uncovered.
    static func assetFolder(ofReportedPath path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard let end = parts.firstIndex(where: { $0.hasSuffix(".asset") }) else { return "" }
        return "/" + parts[0...end].joined(separator: "/")
    }

    private static func simulators(tree: Tree) -> String {
        // Run simctl straight from the selected Xcode: /usr/bin/xcrun would
        // offer to install the command line tools on a Mac without them.
        let developer = ShellRunner.run("/usr/bin/xcode-select", ["-p"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let simctl = developer + "/usr/bin/simctl"
        guard !developer.isEmpty, FileManager.default.isExecutableFile(atPath: simctl) else { return "" }
        func json(_ args: [String]) -> [String: Any] {
            let text = ShellRunner.run(simctl, args, timeout: 10).output
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        }
        func date(_ any: Any?) -> Date? { (any as? String).flatMap { try? Date($0, strategy: .iso8601) } }

        var runtimes = ""
        let images = json(["runtime", "list", "-j"]).values.compactMap { $0 as? [String: Any] }
        for image in images.sorted(by: { ($0["sizeBytes"] as? Int64 ?? 0) > ($1["sizeBytes"] as? Int64 ?? 0) }) {
            guard let id = image["identifier"] as? String, image["deletable"] as? Bool ?? true,
                  let size = image["sizeBytes"] as? Int64, size >= 100_000_000 else { continue }
            // Only what the scan reached (see `appData`). `simctl` reports the
            // runtime's `.dmg`, which is a file deep inside the asset folder
            // and can be absent from the tree; the `.asset` directory is the
            // path the plan card names and the one `tree.node(at:)` resolves,
            // so coverage is judged on it.
            let reported = image["path"] as? String ?? ""
            let asset = assetFolder(ofReportedPath: reported)
            guard !asset.isEmpty, tree.node(at: asset) != nil else { continue }
            // "com.apple.CoreSimulator.SimRuntime.iOS-27-0" → "iOS"
            let platform = (image["runtimeIdentifier"] as? String)?.split(separator: ".").last?
                .split(separator: "-").first.map(String.init) ?? "Simulator"
            let version = image["version"] as? String ?? ""
            runtimes += "| \(Fmt.size(UInt64(size))) | \(platform) \(version) | \(ago(date(image["lastUsedAt"]))) "
                + "| \(id) | \(asset) |\n"
        }

        var devices = ""
        let byRuntime = json(["list", "devices", "-j"])["devices"] as? [String: Any] ?? [:]
        let all = byRuntime.values.flatMap { $0 as? [[String: Any]] ?? [] }
        for device in all.sorted(by: { ($0["dataPathSize"] as? Int64 ?? 0) > ($1["dataPathSize"] as? Int64 ?? 0) }) {
            guard let udid = device["udid"] as? String, let data = device["dataPath"] as? String,
                  let size = device["dataPathSize"] as? Int64, size >= 100_000_000 else { continue }
            let folder = (data as NSString).deletingLastPathComponent
            // Same coverage rule: a device's data folder is under the scanned
            // root only when the scan covered it.
            guard tree.node(at: folder) != nil else { continue }
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
}
