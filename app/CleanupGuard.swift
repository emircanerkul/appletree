import AppKit
import Foundation
import Observation
import SwiftUI

// Guards (enforced here, never left to the model)

nonisolated enum CleanupGuard {
    /// The user's real home directory, from the one owner of that fact.
    ///
    /// This was `NSHomeDirectory()`, which is the *process* home: under the App
    /// Store sandbox that is the container's `Data` directory, so every real
    /// cache was judged "Outside your home folder" and refused even though the
    /// file grant let this process touch it. `AppEnvironment.realHome` answers
    /// the same in both builds — see its doc comment for the measurement.
    static let home = AppEnvironment.realHome

    /// Folders AppleTree never cleans, whatever the plan says.
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
    /// once through the bridge. Order is the table's: the planner prompt
    /// depends on it to list commands exactly as Rust owns them.
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

    /// The one token these commands may take must be *data*, never a flag and
    /// never the documented destructive keyword.
    ///
    /// Matching "one space-free token" alone is not enough, because the token is
    /// handed to `zsh -c` and interpreted by the tool. Apple's own tools document
    /// broader meanings that a single token reaches:
    ///
    ///   xcrun simctl help erase    → "Usage: simctl erase <device> | all"
    ///                                "Specifying all will erase all existing devices."
    ///   xcrun simctl help runtime  → delete (<identifier>|--notUsedSinceDays <days>
    ///                                       |--unusable|--outdated) … ; alias 'all'
    ///
    /// So `xcrun simctl erase all` erases every simulator on the machine, and a
    /// value beginning with `-` is read as a flag rather than an identifier —
    /// while the plan card describes one device or one runtime. A real target is
    /// an identifier (a UDID, a model name, `com.apple.CoreSimulator.SimRuntime.…`),
    /// which is neither.
    private static func oneArgumentAllowed(_ token: String) -> Bool {
        !token.isEmpty && !token.hasPrefix("-") && token != "all"
    }

    /// The enclosing application bundle of `path`, when there is one.
    ///
    /// A bundle is one sealed, signed unit: its inner folders are what the app
    /// ships and loads at runtime, so removing one invalidates the app's
    /// signature. Verified on real bundles — moving
    /// `Bitwarden.app/Contents/Resources/app.asar.unpacked/node_modules` or
    /// `…/Openship.app/Contents/Resources/dashboard/node_modules` makes
    /// `codesign --verify --strict` report "a sealed resource is missing or
    /// invalid", and `spctl` rejects the app. Those sighed internals are what
    /// an Electron app `dlopen`s (native modules sit beside `app.asar`).
    ///
    /// The guard must refuse them for a reason of its own, not by accident:
    /// `/Applications` is refused merely for being outside `$HOME`, which is a
    /// misleading explanation for a sealed bundle and no protection at all for
    /// the many bundles that live *inside* the home folder. Measured on this
    /// machine: `~/Library/Application Support/com.raycast.macos/Updates/…/
    /// Raycast.app/Contents/Resources/…/api/node_modules` is inside `$HOME`,
    /// so the guard permitted it, and moving it breaks that bundle's
    /// signature (50 sealed entries).
    ///
    /// Whether `dir` really is an application bundle rather than a folder that
    /// merely ends in `.app`.
    ///
    /// Two layouts occur in practice and both must count:
    ///
    /// - the classic macOS bundle, `Contents/Info.plist` — every native app;
    /// - the flat iOS/Unity wrapper, which carries its `Info.plist` at the
    ///   bundle root and has no `Contents/` at all. `/Applications/ARES.app`
    ///   wraps one at `Wrapper/ARES.app`, and testing for `Contents` alone
    ///   walked straight into that signed inner bundle.
    ///
    /// Real container and support folders carry neither marker
    /// (`~/Library/Application Support/com.cmuxterm.app`), so this stays
    /// precise instead of refusing them by name.
    private static func isBundle(_ dir: String) -> Bool {
        guard (dir as NSString).lastPathComponent.hasSuffix(".app") else { return false }
        if FileManager.default.fileExists(atPath: dir + "/Contents/Info.plist") { return true }
        return FileManager.default.fileExists(atPath: dir + "/Info.plist")
    }

    private static func enclosingBundle(_ path: String) -> String? {
        var dir = path
        while dir.count > 1 {
            if isBundle(dir) { return dir }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    /// The boot volume group's Data volume prefix, dropped so the same place has
    /// one spelling for every comparison below.
    ///
    /// `/System/Volumes/Data` is the writable volume behind `/` and the app's
    /// default scan target, so most paths a whole-disk scan produces carry it
    /// while `home` (`AppEnvironment.realHome`) and the guard's own lists are
    /// spelled without it. Only the prefix goes, and only at the head: a
    /// component that merely *reads* "System/Volumes/Data" deeper in a path is
    /// an ordinary folder name.
    ///
    /// The same fold is what `ScopedAccess.spellings` performs for the bookmark
    /// side and what `volume_prefix` performs in `src/cleanup.rs`; three readers
    /// of one fact, each judging paths in the volume's own spelling.
    static func foldingDataVolume(_ path: String) -> String {
        let prefix = "/System/Volumes/Data"
        guard path.hasPrefix(prefix) else { return path }
        let rest = path.dropFirst(prefix.count)
        // `/System/Volumes/Data` alone is the volume, i.e. `/`.
        return rest.isEmpty ? "/" : String(rest)
    }

    /// Why a path may not be touched, or nil when it may.
    static func blockReason(path: String) -> String? {
        // Canonical form first, then judge. Two steps, both needed:
        //
        // 1. `resolvingSymlinksInPath` resolves a symlink in the LAST component
        //    the way `trashItem` will, so a link pointing into a protected folder
        //    is judged by where it lands rather than what it is called (S3).
        // 2. The `/System/Volumes/Data` prefix is dropped unconditionally.
        //
        // Step 2 is not redundant. `resolvingSymlinksInPath` folds the Data
        // prefix only for components that really are firmlinks, and the result
        // depends on what happens to exist: it folds `Data/Users`,
        // `Data/Library` and `Data/private` but NOT `Data/opt`, because `/opt`
        // is a symlink to `private/opt` rather than a firmlink. On the app's
        // DEFAULT scan target (`/System/Volumes/Data`) that made the guard refuse
        // `Data/opt/homebrew/...` as "Outside your home folder" while allowing
        // the identical path spelled `/opt/homebrew/...` — the same rule giving
        // two answers for one place. Measured: 24 of the 57 folders Rust
        // nominated on this machine's whole-disk scan were refused, and
        // `Data/private/tmp/*` was refused although `/private/tmp` is not the
        // user's home either way (audit SW-4).
        //
        // The fold must match what `src/cleanup.rs` reasons in, and that owner
        // already treats the prefix as transparent (`volume_prefix`). Doing it
        // here as well is what makes the two agree, and the agreement is the
        // point: recognition must not offer what authorization refuses.
        let resolved = ((path as NSString).resolvingSymlinksInPath as NSString).standardizingPath
        let p = Self.foldingDataVolume(resolved)
        // Reason strings are user-visible safety communication (T7): routed
        // through String(localized:), keys in all 7 .lproj tables.
        //
        // Judged before the home rule, so a sealed bundle gets the reason that
        // is actually true of it. A bundle inside `$HOME` used to pass, and one
        // outside it was refused as "Outside your home folder" — a message that
        // named the wrong cause and, once the user's own scan root was
        // `/Applications`, read as a bug in the app rather than a rule.
        if enclosingBundle(p) != nil { return String(localized: "Inside a signed app bundle") }
        guard p.hasPrefix(home + "/") else { return String(localized: "Outside your home folder") }
        let rel = p.dropFirst(home.count + 1)
        // A direct child of the home is offered only when the tool recreates it.
        //
        // The rule exists to refuse the home's own broad folders (`~/Downloads`,
        // `~/Library`) that had they been reachable would take unrelated data
        // with them. But it refused by SHAPE — "one component, no leading dot" —
        // and that swept up the home's own build output: `~/node_modules` and
        // `~/target` are exactly what `rebuildable` names, the Rust engine
        // nominates them by name, and `PlanItem.init` then built a card the guard
        // had already refused, so it could never be selected (audit SW-4).
        // Asking the rebuildable set is the same question the `protected` loop
        // below already asks, and it keeps every broad root refused.
        let depth = rel.split(separator: "/").count
        let isRebuildable = rebuildable.contains((p as NSString).lastPathComponent)
        guard (depth >= 2 || rel.hasPrefix(".") || isRebuildable), !tooBroad.contains(p) else {
            return String(localized: "Too broad: other apps keep live data here")
        }
        // Whole persistence folders: no named subfolder inside is ever fair game (S1).
        if neverClean.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) {
            return String(localized: "Too broad: other apps keep live data here")
        }
        for dir in protected where p == dir || p.hasPrefix(dir + "/") {
            // Projects live in Documents too; their build output is still fair
            // game.
            let allowed = rebuildable.contains((p as NSString).lastPathComponent)
            if !allowed || dir.hasSuffix(".Trash") {
                return String(localized: "In ~/\(dir.dropFirst(home.count + 1)), which AppleTree never cleans")
            }
        }
        if FileManager.default.fileExists(atPath: p + "/.git") { return String(localized: "A git repository") }
        // Apple's own app data refuses to move and is rebuilt by macOS anyway.
        if p.contains("/Library/Containers/com.apple.") || p.contains("/Library/Caches/com.apple.")
            || p.contains("/Library/Group Containers/group.com.apple.") { return String(localized: "Managed by macOS") }
        return nil
    }

    static func blockReason(command: String) -> String? {
        let c = command.trimmingCharacters(in: .whitespaces)
        // Argument discipline (S6): extra flags or arguments beyond the forms
        // above are rejected, not silently run. A single token is additionally
        // required to be data, not a flag and not the tools' `all` keyword —
        // see `oneArgumentAllowed`: one token is enough to mean "everything".
        let oneArg = oneArgumentCommands.first(where: {
            c.hasPrefix($0 + " ") && !c.dropFirst($0.count + 1).contains(" ")
        })
        if oneArg != nil {
            let token = String(c.dropFirst(oneArg!.count + 1))
            if !oneArgumentAllowed(token) {
                return String(localized: "Command not allowed")
            }
        }
        guard commands.contains(c) || oneArg != nil else {
            return String(localized: "AppleTree only runs tools' own cleanup commands")
        }
        // Shell metacharacters, including the glob/brace forms zsh expands
        // before the tool ever sees the argument: `{a,b}` and `?`/`[ab]` reach
        // the command as a token, so "no spaces" was never a glob rule.
        let banned = [";", "|", "&", ">", "<", "`", "$", "\n", "*", "\\", "{", "}", "?", "[", "]"]
        if banned.contains(where: { c.contains($0) }) { return String(localized: "Command not allowed") }
        return nil
    }

    /// Whether the project owning this build folder was used in the last two
    /// days: its git index (touched by every status, commit or checkout), the
    /// project folder or the folder itself changed recently.
    static func recentlyUsed(_ path: String, within: TimeInterval = 2 * 86400) -> Bool {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-within)
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
