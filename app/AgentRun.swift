import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - Run model

@Observable
@MainActor
final class PlanItem: Identifiable {
    /// `inTrash`: step one done, put back or deleted in step two.
    enum Status: Equatable { case waiting, running, inTrash, done, failed(String), skipped }

    let id = UUID()
    let spec: PlanItemSpec
    let paths: [String]
    /// Why AppleTree won't do this one (protected folder, bad command…).
    let blocked: String?
    var selected: Bool
    var status: Status = .waiting
    /// Space this item gave back to the disk (commands, emptied Trash).
    var freed: UInt64 = 0
    /// Where its folders went in the Trash, for "Empty Trash".
    var trashed: [URL] = []
    var trashedBytes: UInt64 = 0

    /// Size from the scan where it can be measured, else the agent's figure.
    let bytes: UInt64
    /// Its folders in the scan the plan was made from, for the treemap.
    let nodes: [Int]

    /// Why some of its folders were left out, shown under the card.
    let note: String?
    /// A tool cache that is only a folder: trashed and deleted like one.
    let viaTrash: Bool

    init(spec: PlanItemSpec, tree: Tree) {
        self.spec = spec
        var asked = spec.paths.map { ($0 as NSString).expandingTildeInPath }
        // A known tool cache named without its folder: use the standard one,
        // so its size is measured instead of guessed.
        if spec.action == .command, asked.isEmpty {
            let home = NSHomeDirectory()
            let known: [(String, String)] = [
                ("uv cache", "\(home)/.cache/uv"), ("npm cache", "\(home)/.npm/_cacache"),
                ("bun pm cache", "\(home)/.bun/install/cache"), ("pip cache", "\(home)/Library/Caches/pip"),
                ("pip3 cache", "\(home)/Library/Caches/pip"), ("yarn cache", "\(home)/Library/Caches/Yarn"),
            ]
            if let hit = known.first(where: { spec.command.hasPrefix($0.0) }) { asked = [hit.1] }
        }
        var reason: String?
        var kept: [String] = []
        var recent = 0
        // A cache that is just a folder goes through the Trash and AppleTree's
        // parallel delete: reversible in step one, and faster than the tool's
        // own single-threaded removal (bun took 20 s for 5 GB).
        // The cache-clearing commands with no flag variants, straight from
        // the Rust allowlist: exactly the no-flag `… cache clean|purge|rm`
        // forms. (Flag variants like the npm force flag match by the
        // same prefix, which is what this check wants.)
        let plainCache = CleanupGuard.allowlistCommands.filter {
            $0.hasSuffix(" cache clean") || $0.hasSuffix(" cache purge") || $0.hasSuffix(" pm cache rm")
        }
        let trashable = spec.action == .command && !asked.isEmpty
            && plainCache.contains { spec.command.hasPrefix($0) }
            && asked.allSatisfy { CleanupGuard.blockReason(path: $0) == nil && FileManager.default.fileExists(atPath: $0) }
        viaTrash = trashable
        if spec.action == .command && !trashable {
            reason = CleanupGuard.blockReason(command: spec.command)
            // A tool cache whose folders are all gone has nothing left to clear.
            if reason == nil, !asked.isEmpty, asked.allSatisfy({ !FileManager.default.fileExists(atPath: $0) }) {
                reason = String(localized: "Already clean")
            }
            kept = asked
        } else if asked.isEmpty {
            reason = String(localized: "Nothing to remove")
        } else {
            // Paths AppleTree won't touch are dropped; the card is blocked only
            // when nothing is left.
            for path in asked {
                if let why = CleanupGuard.blockReason(path: path) {
                    reason = reason ?? why
                } else if CleanupGuard.codexChat(path) == nil, let app = CleanupGuard.runningOwner(of: [path]) {
                    reason = reason ?? String(localized: "Quit \(app) to clean this")
                } else if !FileManager.default.fileExists(atPath: path) {
                    reason = reason ?? String(localized: "Already gone")
                } else if CleanupGuard.recentlyUsed(path) {
                    // Never break what the user is working on right now.
                    recent += 1
                    reason = reason ?? (CleanupGuard.codexChat(path) != nil
                        ? String(localized: "A Codex chat you used in the last 2 days")
                        : String(localized: "In projects you used in the last 2 days"))
                } else {
                    kept.append(path)
                }
            }
            if !kept.isEmpty { reason = nil }
        }
        paths = kept.isEmpty ? asked : kept
        blocked = reason
        selected = reason == nil && spec.group == .safe
        note = recent > 0 && !kept.isEmpty
            ? "Keeps \(recent) project\(recent == 1 ? "" : "s") you used in the last 2 days" : nil

        // Measured sizes, not counting a path inside another listed one twice.
        let nodes = Set(paths.compactMap { tree.node(at: $0) })
        let outer = nodes.filter { node in !tree.ancestry(node).dropLast().contains(where: nodes.contains) }
        let measured = outer.reduce(UInt64(0)) { $0 + tree.alloc[$1] }
        self.nodes = Array(outer)
        bytes = measured > 0 ? measured : UInt64(max(0, spec.bytes))
    }

    var isCommand: Bool { spec.action == .command && !viaTrash }
}

@Observable
@MainActor
final class AgentRun {
    /// Two decisions from the user: `planned` → Move to Trash (can be undone)
    /// → `staged` → Delete for good → `done`.
    enum Phase: Equatable { case thinking, planned, trashing, staged, deleting, done, failed(String) }

    /// Nil when the plan comes from a custom provider over HTTP.
    let agent: InstalledAgent?
    /// Nil when the plan comes from a CLI agent. The endpoint never runs
    /// tools — it only writes the plan; the guards and the two-step delete
    /// below are identical for both sources.
    let provider: LLMProvider?
    /// What the panel calls the planner: the CLI agent's or the provider's name.
    var displayName: String { agent?.kind.name ?? provider?.displayName ?? "The assistant" }
    private(set) var phase: Phase = .thinking
    /// What the agent has done so far, in plain words; the last one is live.
    private(set) var steps: [String] = ["Reading your scan"]
    private(set) var summary = ""
    private(set) var items: [PlanItem] = []
    private(set) var startedAt = Date()
    private(set) var planSeconds: Double?
    /// The card the run is working on right now, so the panel can mark it.
    /// Written by the two cleaning phases; read by `PlanCard` for its brighter
    /// fill and accent ring.
    private(set) var current: UUID?

    private var process: Process?
    private let scanRoot: String
    private let tree: Tree
    private let onFinish: () -> Void
    private var preparationTask: Task<Void, Never>?

    init(agent: InstalledAgent?, env: AgentEnvironment, tree: Tree, scanRoot: String,
         known: [CleanupItem], provider: LLMProvider? = nil, onFinish: @escaping () -> Void) {
        self.agent = agent
        self.provider = provider
        self.scanRoot = scanRoot
        self.tree = tree
        self.onFinish = onFinish
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.localizedName.map { "\($0) (\(app.bundleIdentifier ?? "?"))" } }
        preparationTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let input = await Task.detached(priority: .userInitiated) {
                AgentPrompt.build(tree: tree, scanRoot: scanRoot, known: known, running: running)
                + AgentPrompt.appData(tree: tree)
            }.value
            // Closing or replacing a run while its prompt was being built
            // must not launch an agent after cancellation.
            guard !Task.isCancelled, let self else { return }
            preparationTask = nil
            step("Asking \(displayName) what can go")
            start(input: input, env: env)
        }
    }

    /// Folders to light up on the treemap: what the plan would remove.
    func highlights(in shown: Tree?) -> [Int] {
        guard shown === tree, phase != .done else { return [] }
        return items.filter { $0.selected && $0.blocked == nil && $0.status != .done }
            .flatMap(\.nodes)
    }

    /// What step one moves to the Trash (tool caches wait for step two).
    var trashBytes: UInt64 { targets.filter { !$0.isCommand }.reduce(0) { $0 + $1.bytes } }
    /// What step two deletes for good; while it runs, what is still going,
    /// so the number counts down as each item finishes.
    var pendingBytes: UInt64 {
        targets.filter {
            $0.status == .inTrash || ($0.isCommand && $0.status == .waiting)
                || (phase == .deleting && $0.status == .running)
        }.reduce(0) { $0 + $1.bytes }
    }
    /// The items the user chose and AppleTree may touch.
    var targets: [PlanItem] { items.filter { $0.selected && $0.blocked == nil } }

    /// Space the disk actually got back (statfs), set when deleting ends.
    private(set) var reclaimed: UInt64?

    var selectedBytes: UInt64 { items.filter(\.selected).reduce(0) { $0 + $1.bytes } }
    var freed: UInt64 { items.reduce(0) { $0 + $1.freed } }
    var inTrash: UInt64 { items.reduce(0) { $0 + $1.trashedBytes } }

    private func step(_ text: String) {
        guard steps.last != text else { return }
        withAnimation(.snappy) { steps.append(text) }
    }

    /// `defaults write com.erklab.apps.appletree bz.claudeModel haiku` to try another.
    private static var claudeModel: String {
        ProcessInfo.processInfo.environment["BZ_CLAUDE_MODEL"]
            ?? UserDefaults.standard.string(forKey: "bz.claudeModel") ?? "sonnet"
    }

    func cancel() {
        preparationTask?.cancel()
        preparationTask = nil
        process?.terminate()
        process = nil
        planClient?.cancel()
        planClient = nil
    }

    /// Custom endpoint runs need no process: the client streams SSE straight
    /// from the HTTP response into the same event pipeline.
    private var planClient: LLMPlanClient?

    // MARK: Agent process

    private func start(input: String, env: AgentEnvironment) {
        if let provider { startProvider(input: input, provider: provider); return }
        guard let agent else { return }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppleTree", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: agent.path)
        // An empty working folder: no project settings, hooks or memory load.
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = env.path
        process.environment = environment

        switch agent.kind {
        case .claude:
            process.arguments = [
                "-p", "--setting-sources", "project", "--output-format", "stream-json", "--verbose",
                "--include-partial-messages", "--model", Self.claudeModel, "--effort", "low",
                "--tools", "Bash,Read", "--permission-mode", "dontAsk", "--no-session-persistence",
                "--allowedTools", "Bash(du:*)", "Bash(ls:*)", "Bash(stat:*)", "Bash(docker system df:*)",
                "Bash(xcrun simctl list:*)", "Bash(ollama list:*)", "Read",
                "--json-schema", planSchema,
            ]
        case .codex:
            // The app server, not `codex exec`: only it streams the answer as
            // it is written, so cards can appear one by one.
            process.arguments = ["app-server"]
        }

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Main queue, not Tasks: events must land in the order they were read.
        let writer = stdin.fileHandleForWriting
        let reader = AgentStreamReader(kind: agent.kind, prompt: input, folder: folder.path,
                                       write: { data in try? writer.write(contentsOf: data) },
                                       done: { [weak process] in process?.terminate() }) { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
        }
        // The run ends once the process has exited and all its output is read.
        let ended = DispatchGroup()
        ended.enter(); ended.enter()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                ended.leave()
            } else {
                reader.feed(data)
            }
        }
        let errTail = ErrTail()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { errTail.feed(data) }
        }
        process.terminationHandler = { _ in ended.leave() }
        ended.notify(queue: .main) { [weak self] in
            let status = process.terminationStatus
            let tail = errTail.last
            MainActor.assumeIsolated { self?.processEnded(status: status, stderr: tail) }
        }
        do {
            try process.run()
        } catch {
            phase = .failed("Couldn't start \(displayName): \(error.localizedDescription)")
            return
        }
        self.process = process
        if agent.kind == .claude {
            let data = Data(input.utf8)
            DispatchQueue.global(qos: .userInitiated).async {
                try? writer.write(contentsOf: data)
                try? writer.close()
            }
        } else {
            reader.begin()
        }
    }

    /// Custom provider: stream the plan over HTTP. No process, no PATH, no
    /// working folder — the endpoint only ever sees the prompt text (folder
    /// paths and sizes, never file contents) and answers with plan JSON.
    private func startProvider(input: String, provider: LLMProvider) {
        let key = ProviderStore.getKey(for: provider.id) ?? ""
        let client = LLMPlanClient(provider: provider, apiKey: key)
        planClient = client
        let name = displayName
        client.plan(input) { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleProvider(event, name: name) } }
        }
        step("Asking \(name) what can go")
    }

    private func handleProvider(_ event: LLMEvent, name: String) {
        guard phase == .thinking else { return }
        switch event {
        case .item(let spec):
            withAnimation(.snappy) { items.append(PlanItem(spec: spec, tree: tree)) }
        case .plan(let summary, let specs):
            self.summary = summary
            adopt(specs)
            finishPlanning()
        case .failed(let message):
            NSLog("[bz] provider \(name) failed: \(message)")
            if !items.isEmpty { finishPlanning() } else { phase = .failed(message) }
        }
    }

    private func handle(_ event: AgentStreamReader.Event) {
        guard phase == .thinking else { return }
        switch event {
        case .activity(let text):
            step(text)
        case .item(let spec):
            withAnimation(.snappy) { items.append(PlanItem(spec: spec, tree: tree)) }
        case .restart:
            withAnimation(.snappy) { items = [] }
        case .plan(let summary, let specs):
            self.summary = summary
            adopt(specs)
            finishPlanning()
        case .failed(let message):
            // A CLI run that dies after streaming cards still finishes
            // planning with what arrived; a provider whose JSON never
            // decoded strictly gets the same grace.
            if !items.isEmpty { finishPlanning() } else { phase = .failed(message) }
        }
    }

    /// Make the final plan authoritative while preserving the ticks a user
    /// already made on cards it agrees with.
    ///
    /// The old form compared `specs.map(\.title)` — only the titles. Titles are
    /// model-chosen and the schema does not make them unique, so two cards
    /// legitimately called "node_modules" kept the *streamed* card's paths,
    /// bytes and group, and the panel then showed and acted on partial figures
    /// instead of the plan's. Comparing the whole spec is what makes "agrees
    /// with" mean the card really is the same item.
    private func adopt(_ specs: [PlanItemSpec]) {
        guard specs.map(\.self) != items.map(\.spec) else { return }
        // Reuse a card only when the spec matches at the same position AND the
        // user's tick still applies, so a rebuilt plan cannot silently inherit
        // a selection made for a different item.
        let previous = items
        withAnimation(.snappy) {
            items = specs.enumerated().map { index, spec in
                guard previous.indices.contains(index), previous[index].spec == spec else {
                    return PlanItem(spec: spec, tree: tree)
                }
                return previous[index]
            }
        }
    }

    private func processEnded(status: Int32, stderr: String) {
        process = nil
        guard phase == .thinking else { return }
        if !items.isEmpty {
            finishPlanning()
        } else if status != 0 {
            phase = .failed(stderr.isEmpty ? "\(displayName) stopped (exit \(status))." : stderr)
        } else {
            phase = .failed("\(displayName) didn't return a plan.")
        }
    }

    private func finishPlanning() {
        planSeconds = -startedAt.timeIntervalSinceNow
        items.sort { $0.bytes > $1.bytes }
        if summary.isEmpty {
            summary = String(localized: "About \(Fmt.size(items.filter { $0.blocked == nil }.reduce(0) { $0 + $1.bytes })) can go.")
        }
        withAnimation(.snappy) { phase = .planned }
    }

    // MARK: Cleaning (AppleTree does this, not the agent)

    /// Demo recordings only: walk through both steps without touching disk.
    private let dryRun = ProcessInfo.processInfo.environment["BZ_DEMO_DRYRUN"] != nil

    /// Whether this run is still working. Terminal phases have stopped and keep
    /// their result on screen until the user closes the panel.
    var isActive: Bool {
        switch phase {
        case .thinking, .planned, .trashing, .staged, .deleting: return true
        case .done, .failed: return false
        }
    }

    /// Whether this run touches nothing. Read by the panel's QA auto-approve
    /// hook, which must never drive a real irreversible delete.
    var isDryRun: Bool { dryRun }

    /// Step one: move the chosen folders to the Trash. Nothing is deleted.
    func moveToTrash() {
        guard phase == .planned else { return }
        phase = .trashing
        for item in items where !(item.selected && item.blocked == nil) { item.status = .skipped }
        let work = targets.filter { !$0.isCommand }
        for item in work { item.status = .running }
        // All of them are in flight at once, so the marked card is the first
        // one still working; the status glyphs carry the rest.
        current = work.first?.id
        Task {
            // Moving to the Trash is a rename; all of them at once, off the main thread.
            await withTaskGroup(of: Void.self) { group in
                for item in work {
                    let paths = item.paths
                    let dryRun = dryRun
                    // Re-check at action time, the way `runCommand` re-runs
                    // `blockReason(command:)`: the plan was validated while
                    // streaming, so an app that was closed then and is open
                    // now must get its own folders back (S2, and the README's
                    // "skipped until you quit them"). The verdict is read on
                    // the main actor BEFORE the child task is spawned, because
                    // `runningOwner` is @MainActor and the child runs off it.
                    let owner = CleanupGuard.runningOwner(of: paths)
                    group.addTask {
                        // One outcome per source path: some of a card's folders
                        // can move while another is blocked. Keyed by source,
                        // never by the Trash URL the move returns.
                        let outcomes: [TrashOutcome]
                        if let owner {
                            // Same wording the plan-time gate uses; nothing is
                            // handed to the trash owner at all.
                            outcomes = paths.map {
                                TrashOutcome(source: ($0 as NSString).standardizingPath, trashed: nil,
                                             reason: String(localized: "Quit \(owner) to clean this"))
                            }
                        } else {
                            outcomes = dryRun ? [] : await Self.trash(paths)
                        }
                        await MainActor.run {
                            let moved = outcomes.compactMap(\.trashed)
                            let reason = outcomes.compactMap(\.reason).first
                            item.trashed = moved
                            item.trashedBytes = dryRun || !moved.isEmpty ? item.bytes : 0
                            // A reason with nothing moved is a failed card; a
                            // partial move is still in the Trash, so the
                            // folders that did move stay deletable. The
                            // remainder is reported, not silently dropped.
                            if let reason, moved.isEmpty {
                                item.status = .failed(reason)
                            } else {
                                if let reason {
                                    NSLog("[bz] \(item.spec.title): moved \(moved.count) of \(paths.count) (\(reason))")
                                }
                                item.status = .inTrash
                            }
                        }
                    }
                }
            }
            current = nil
            withAnimation(.snappy) { phase = .staged }
        }
    }

    /// Step two: delete for good what step one trashed, and run the tools'
    /// own cache cleanups. Only this run's items; the rest of the Trash stays.
    /// Everything runs at once: folder deletes spread over every core.
    func deleteForGood(env: AgentEnvironment) {
        guard phase == .staged else { return }
        phase = .deleting
        let work = targets.filter { $0.status == .inTrash || ($0.isCommand && $0.status == .waiting) }
        for item in work { item.status = .running }
        current = work.first?.id
        let before = Self.freeBytes()
        Task {
            await withTaskGroup(of: Void.self) { group in
                for item in work {
                    let urls = item.trashed
                    let command = item.isCommand ? item.spec.command : nil
                    let bytes = item.bytes
                    let dryRun = dryRun
                    group.addTask {
                        var error: String?
                        if dryRun {
                            // Roughly as long as the real delete: bigger items finish later.
                            let gb = Double(bytes) / 1e9
                            try? await Task.sleep(for: .seconds(min(3.5, 0.3 + gb / 4)))
                        } else if let command {
                            error = await Self.runCommand(command, path: env.path)
                        } else {
                            // The irreversibility of this step is what makes the
                            // report load-bearing: a `removefile` that failed
                            // must reach `error`, or the card shows a green
                            // check for data still on disk and the hero "space
                            // freed" counts bytes that never left.
                            error = await Self.remove(urls)
                        }
                        await MainActor.run {
                            item.trashed = []
                            item.trashedBytes = 0
                            if error == nil { item.freed = item.bytes }
                            withAnimation(.snappy) { item.status = error.map { .failed($0) } ?? .done }
                        }
                    }
                }
            }
            // What the disk really got back: APFS frees a moment after the
            // delete, and blocks shared with clones (bun installs packages as
            // clones of its cache) stay in use, so wait for it to settle.
            if !dryRun {
                var last = Self.freeBytes()
                for _ in 0..<10 {
                    try? await Task.sleep(for: .milliseconds(300))
                    let now = Self.freeBytes()
                    if now == last { break }
                    last = now
                }
                reclaimed = last > before ? last - before : 0
            }
            current = nil
            withAnimation(.snappy) { phase = .done }
            if !dryRun { onFinish() }
        }
    }

    /// Moves paths to the Trash via the shared pathway in CleanupModel.swift.
    ///
    /// A planner nominated these, so the guard re-checks each one: the plan was
    /// validated while streaming and the user may have launched an app or moved
    /// a folder since (S2). The user's approval of the plan authorizes the
    /// *plan*, not the guard's bypass.
    nonisolated static func trash(_ paths: [String]) async -> [TrashOutcome] {
        await Trash.trash(paths, authority: .plannerPlan)
    }

    /// Four deletes at a time across the whole run: measured on APFS, 4
    /// threads remove a 100k-file node_modules 2x faster than `rm -rf`, and
    /// more threads only contend (8 and 16 were slower).
    nonisolated private static let deleteSlots = DispatchSemaphore(value: 4)
    nonisolated private static let deleteQueue = DispatchQueue(label: "appletree.delete", qos: .userInitiated,
                                                               attributes: .concurrent)

    /// Deletes folders for good, fast: each folder's children go through
    /// removefile(3) on the shared slots, then the folder itself. Returns the
    /// first failure, or nil when every path is gone.
    ///
    /// The return status of `removefile` used to be discarded, so this caller
    /// marked the item `.done` and added its bytes to the freed total even
    /// when nothing was deleted. `removefile` reports "less than 0 on error,
    /// 0 on success" and does NOT set errno, so the status itself is the
    /// message; a path that is already absent is not a failure (there is
    /// nothing left to delete, and a retried item must not report one).
    nonisolated static func remove(_ urls: [URL]) async -> String? {
        await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            deleteQueue.async {
                let group = DispatchGroup()
                // First failure wins; several queue slots race to write it, so
                // it carries its own lock (the `ErrTail` pattern) rather than
                // relying on the queue being serial.
                let failure = DeleteFailure()
                for url in urls {
                    for kid in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] {
                        deleteSlots.wait()
                        group.enter()
                        deleteQueue.async {
                            Self.deleteItem(url.appendingPathComponent(kid).path, failure: failure)
                            deleteSlots.signal()
                            group.leave()
                        }
                    }
                }
                group.wait()
                for url in urls { Self.deleteItem(url.path, failure: failure) }
                done.resume(returning: failure.first)
            }
        }
    }

    /// One `removefile(3)` call, recording a real failure. `removefile`
    /// reports less than 0 on error and does not set errno, so the status is
    /// the message; a path that is already absent is not reported, because
    /// there is nothing left to delete (and a retried item must not claim one).
    nonisolated private static func deleteItem(_ path: String, failure: DeleteFailure) {
        let status = removefile(path, nil, removefile_flags_t(REMOVEFILE_RECURSIVE))
        guard status < 0, FileManager.default.fileExists(atPath: path) else { return }
        failure.note(status, path)
    }

    /// Plain available space (statfs), exact to the block.
    nonisolated static func freeBytes() -> UInt64 {
        var fs = statfs()
        guard statfs(NSHomeDirectory(), &fs) == 0 else { return 0 }
        return UInt64(fs.f_bavail) * UInt64(fs.f_bsize)
    }

    /// Runs a vetted cleanup command; returns an error message on failure.
    nonisolated static func runCommand(_ command: String, path: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            // Re-check at action time: the plan was validated while streaming,
            // so the guard runs again before anything is spawned (S2).
            if let reason = CleanupGuard.blockReason(command: command) { return reason }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = path
            process.environment = environment
            // Some tools only run inside a project (`bun pm cache rm` wants a
            // package.json), so they run in an empty stand-in one.
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AppleTree/tools", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let manifest = folder.appendingPathComponent("package.json")
            if !FileManager.default.fileExists(atPath: manifest.path) {
                try? #"{"name":"appletree-cleanup","private":true}"#.write(to: manifest, atomically: true, encoding: .utf8)
            }
            process.currentDirectoryURL = folder
            process.standardInput = FileHandle.nullDevice
            // Read as it comes: a chatty tool must never fill the pipe and stall.
            let err = Pipe()
            let tail = ErrTail()
            err.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { tail.feed(data) }
            }
            process.standardError = err
            process.standardOutput = FileHandle.nullDevice
            do { try process.run() } catch { return error.localizedDescription }
            let deadline = Date().addingTimeInterval(600)
            while process.isRunning, Date() < deadline { usleep(50_000) }
            if process.isRunning { process.terminate(); return "Took too long" }
            guard process.terminationStatus != 0 else { return nil }
            return tail.last.isEmpty ? "Exited with \(process.terminationStatus)" : tail.last
        }.value
    }
}

/// Keeps the last line of an agent's stderr for error messages.
nonisolated final class ErrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func feed(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        text = String((text + String(decoding: data, as: UTF8.self)).suffix(2000))
    }
    var last: String {
        lock.lock(); defer { lock.unlock() }
        return text.split(separator: "\n").map(String.init)
            .last(where: { !$0.contains("rmcp::") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
    }
}

/// The first failure from a parallel `removefile` sweep, kept behind a lock so
/// the four delete slots can record one without a data race. `removefile` does
/// not set errno, so the status is the whole story: path plus status.
nonisolated final class DeleteFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?
    var first: String? {
        lock.lock(); defer { lock.unlock() }
        return message
    }
    func note(_ status: Int32, _ path: String) {
        lock.lock(); defer { lock.unlock() }
        if message == nil { message = "\(path): removefile failed (\(status))" }
    }
}
