import AppKit
import Foundation
import Observation
import SwiftUI

// Guards (enforced here, never left to the model)
/// When Codex last worked in each folder, from its session logs: every
/// rollout file opens with the chat's working folder and is appended to as
/// the chat goes on.
nonisolated enum CodexSessions {
    static func lastActive(since: Date? = nil) -> [String: Date] {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        let root = URL(fileURLWithPath: home + "/sessions")
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [:] }
        var active: [String: Date] = [:]
        for case let url as URL in files where url.pathExtension == "jsonl" {
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  since.map({ date > $0 }) ?? true,
                  let file = try? FileHandle(forReadingFrom: url) else { continue }
            let head = String(decoding: (try? file.read(upToCount: 8192)) ?? Data(), as: UTF8.self)
            try? file.close()
            guard let match = head.firstMatch(of: /"cwd":"((?:[^"\\]|\\.)*)"/) else { continue }
            let cwd = String(match.1).replacingOccurrences(of: "\\/", with: "/")
            active[cwd] = max(active[cwd] ?? date, date)
        }
        return active
    }
}

nonisolated enum CleanupGuard {
    static let home = NSHomeDirectory()

    /// Folders AppleTree never cleans, whatever the agent says.
    static let protected = [
        "Documents", "Desktop", "Pictures", "Movies", "Music", ".ssh", ".gnupg", ".Trash",
        "Library/Mobile Documents", "Library/Mail", "Library/Messages", "Library/Keychains",
        "Library/Photos", "Library/CloudStorage",
    ].map { home + "/" + $0 }

    /// Build output and installs that a tool recreates, allowed even inside a
    /// protected folder (a project in ~/Documents still has a node_modules).
    static let rebuildable: Set<String> = [
        "node_modules", ".venv", "venv", "target", ".next", ".turbo", ".nuxt", ".svelte-kit",
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", "DerivedData", ".gradle",
        ".parcel-cache", ".expo", "Pods",
    ]

    /// Folders that hold other apps' live data: only named subfolders go.
    static let tooBroad: Set<String> = [
        "Library", "Library/Caches", "Library/Application Support", "Library/Containers",
        "Library/Group Containers", "Library/Developer", "Library/Preferences", ".config", ".cache",
        "Library/Developer/CoreSimulator", "Library/Developer/CoreSimulator/Devices",
        ".local", ".local/share", "Downloads",
    ].reduce(into: []) { $0.insert(home + "/" + $1) }

    /// Folders that alter app behavior or persistence (launch agents, fonts,
    /// keychain helpers…): the folder and everything inside it is off limits.
    /// Unlike `Library/Caches`, no named subfolder of these is a rebuildable
    /// cache, so they block recursively (S1).
    static let neverClean: [String] = [
        "Library/LaunchAgents", "Library/LaunchDaemons", "Library/Cookies", "Library/Logs",
        "Library/Saved Application State", "Library/Spelling", "Library/Frameworks",
        "Library/PrivilegedHelperTools", "Library/ScriptingAdditions",
        "Library/Internet Plug-Ins", "Library/PreferencePanes", "Library/Input Methods",
        "Library/Fonts", "Library/Services", "Library/StartupItems", "Library/Tokens",
        "Library/Widgets", "Library/Metadata", "Library/Desktop Pictures",
        "Library/Screen Savers", "Library/Workflows", "Library/Automator",
        "Library/Contextual Menu Items", "Library/Compositions", "Library/DirectoryServices",
        "Library/Calendars", "Library/Accounts", "Library/Application Scripts",
    ].map { home + "/" + $0 }

    /// The allowlist, single source of truth in Rust (`src/cleanup.rs`), read
    /// once through the bridge. Order is the table's: the agent prompt depends
    /// on it to list commands exactly as Rust owns them.
    static let allowlistCommands: [String] = {
        let count = Int(bz_cleanup_allowlist_count())
        // Empty means the bridge failed: the guard then blocks every command
        // (fail closed). Do not fall back to a literal list here.
        guard count > 0, let table = bz_cleanup_allowlist() else { return [] }
        var commands: [String] = []
        commands.reserveCapacity(count)
        for i in 0..<count {
            if let p = table[i] { commands.append(String(cString: p)) }
        }
        return commands
    }()

    /// The only commands AppleTree runs: each tool's own cleanup, in exactly
    /// these forms (S6). No-argument commands must match to the letter; flag
    /// variants are separate entries, not prefix matches. Owned by Rust; this
    /// is a lookup, not a second copy.
    static let commands: Set<String> = Set(allowlistCommands)

    /// Commands that take exactly one trailing argument (a model, a runtime
    /// image, a device…). Nothing beyond that one token — no extra flags — is
    /// accepted (S6), so upstream's prefix-matched `ollama rm `/`simctl erase`
    /// forms stay exact here.
    static let oneArgumentCommands = ["ollama rm", "xcrun simctl runtime delete", "xcrun simctl erase"]

    /// Why a path may not be touched, or nil when it may.
    static func blockReason(path: String) -> String? {
        // Resolve before matching: `trashItem` follows a symlink in the last
        // component, so a link pointing into a protected folder must be
        // judged by where it lands, not what it is called (S3). This also
        // expands ~ itself, but with the same home the guard checks below.
        let p = ((path as NSString).resolvingSymlinksInPath as NSString).standardizingPath
        guard p.hasPrefix(home + "/") else { return "Outside your home folder" }
        let rel = p.dropFirst(home.count + 1)
        guard rel.split(separator: "/").count >= 2 || rel.hasPrefix("."), !tooBroad.contains(p) else {
            return "Too broad: other apps keep live data here"
        }
        // Whole persistence folders: no named subfolder inside is ever fair game (S1).
        if neverClean.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) {
            return "Too broad: other apps keep live data here"
        }
        for dir in protected where p == dir || p.hasPrefix(dir + "/") {
            // Projects live in Documents too; their build output is still fair
            // game, and so are Codex's chat folders (the user decides those).
            let allowed = rebuildable.contains((p as NSString).lastPathComponent) || codexChat(p) != nil
            if !allowed || dir.hasSuffix(".Trash") {
                return "In ~/\(dir.dropFirst(home.count + 1)), which AppleTree never cleans"
            }
        }
        if FileManager.default.fileExists(atPath: p + "/.git") { return "A git repository" }
        // Apple's own app data refuses to move and is rebuilt by macOS anyway.
        if p.contains("/Library/Containers/com.apple.") || p.contains("/Library/Caches/com.apple.")
            || p.contains("/Library/Group Containers/group.com.apple.") { return "Managed by macOS" }
        return nil
    }

    static func blockReason(command: String) -> String? {
        let c = command.trimmingCharacters(in: .whitespaces)
        // Argument discipline (S6): extra flags or arguments beyond the forms
        // above are rejected, not silently run.
        guard commands.contains(c) || oneArgumentCommands.contains(where: {
            c.hasPrefix($0 + " ") && !c.dropFirst($0.count + 1).contains(" ")
        }) else {
            return "AppleTree only runs tools' own cleanup commands"
        }
        let banned = [";", "|", "&", ">", "<", "`", "$", "\n", "*", "\\"]
        if banned.contains(where: { c.contains($0) }) { return "Command not allowed" }
        return nil
    }

    /// The Codex app keeps each chat's files in ~/Documents/Codex/<date>/<chat>
    /// (outputs, work). Returns that chat folder for a path at or inside one.
    static func codexChat(_ path: String) -> String? {
        let root = home + "/Documents/Codex/"
        let p = (path as NSString).standardizingPath
        guard p.hasPrefix(root) else { return nil }
        let parts = p.dropFirst(root.count).split(separator: "/")
        guard parts.count >= 2, parts[0].wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { return nil }
        return root + parts[0] + "/" + parts[1]
    }

    /// Whether the project owning this build folder was used in the last two
    /// days: its git index (touched by every status, commit or checkout), the
    /// project folder or the folder itself changed recently. A Codex chat
    /// counts as used when it started or Codex worked in it since (folder
    /// dates are no help there: Finder's .DS_Store writes bump them).
    static func recentlyUsed(_ path: String, within: TimeInterval = 2 * 86400) -> Bool {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-within)
        if let chat = codexChat(path) {
            let day = ((chat as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if let started = try? Date(day + "T23:59:59Z", strategy: .iso8601), started > cutoff { return true }
            return CodexSessions.lastActive(since: cutoff).keys.contains { $0 == chat || $0.hasPrefix(chat + "/") }
        }
        let url = URL(fileURLWithPath: path)
        guard rebuildable.contains(url.lastPathComponent) else { return false }
        let project = url.deletingLastPathComponent()
        var stamps = [path, project.path]
        let git = project.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: git.path, isDirectory: &isDir) {
            if isDir.boolValue {
                stamps.append(git.appendingPathComponent("index").path)
            } else if let text = try? String(contentsOf: git, encoding: .utf8),
                      let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
                // A worktree: its index lives in the main repository.
                let dir = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                stamps.append(URL(fileURLWithPath: dir, relativeTo: project).appendingPathComponent("index").path)
            }
        }
        return stamps.contains { p in
            ((try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date).map { $0 > cutoff } ?? false
        }
    }

    /// An app that must be quit before its files go, when one is running.
    @MainActor
    static func runningOwner(of paths: [String]) -> String? {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let id = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            for path in paths {
                let parts = path.split(separator: "/").map(String.init)
                if !id.isEmpty, parts.contains(where: { $0 == id || $0.hasPrefix(id + ".") }) { return name }
                if name.count > 2, parts.contains(name) { return name }
            }
        }
        return nil
    }
}
