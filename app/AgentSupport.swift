import Foundation

// MARK: - The planner catalog

/// One entry the user can choose as the Clean Up planner, and the single
/// source of truth for what that choice *means*.
///
/// Both surfaces that offer the choice — the panel's menu and Settings →
/// General — render this one list on `ScanModel`. They used to keep separate
/// rules (the panel preferred a ready agent, Settings preferred the first
/// provider), so the row Settings displayed and the engine the panel ran could
/// disagree. The id is exactly the stored `bz.engine` tag, so a choice and its
/// persistence cannot drift apart either.
///
/// A provider is now the only kind of planner: CLI agents are gone, so the
/// catalog is the configured providers in their stored order.
nonisolated struct PlannerChoice: Identifiable, Sendable {
    /// A configured OpenAI- or Anthropic-compatible endpoint.
    let provider: LLMProvider

    /// Exactly the `bz.engine` tag, which is also the Picker tag: one
    /// identity for the choice, its persistence and the Picker row.
    var id: String { "provider:\(provider.id)" }

    /// How the planner reads in the panel's menu.
    var label: String { provider.displayName }

    /// How it reads in Settings' picker.
    ///
    /// It carried a "(custom)" suffix while built-in planners existed, to say
    /// which kind of planner the row named. Providers are now the only kind, so
    /// the suffix distinguishes nothing and only lengthens the name.
    var settingsLabel: String { provider.displayName }

    /// The whole catalog, built once here so the panel's menu and Settings →
    /// General cannot list different planners or in a different order.
    static func catalog(providers: [LLMProvider]) -> [PlannerChoice] {
        providers.map { PlannerChoice(provider: $0) }
    }

    /// The planner in effect within a catalog.
    ///
    /// A stored choice wins while it is still configured; otherwise the first
    /// provider leads, so deleting a provider does not strand the panel on a
    /// planner that no longer exists (the Picker tag would then match no row
    /// and render blank). Nil only while no provider is configured — the panel
    /// then offers "Add a model provider" instead.
    static func preferredID(stored: String?, in choices: [PlannerChoice]) -> String? {
        if let stored, choices.contains(where: { $0.id == stored }) { return stored }
        return choices.first?.id
    }
}

nonisolated final class OutputText: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ new: Data) { lock.lock(); data = new; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

// MARK: - The shell environment

/// The user's shell PATH, read once at launch.
///
/// The allowlisted cleanup tools (`brew`, `npm`, `uv`, `xcrun`, `ollama`) live
/// in Homebrew, ~/.local/bin, nvm and other tool-manager locations, none of
/// which an app launched by Finder has on its own PATH. Without this the
/// command rows of a plan fail with "command not found" even though the tool is
/// installed.
///
/// `source` records HOW the path was obtained, and is not cosmetic. A login
/// shell that times out or fails yields no `BZPATH=`, and the previous code
/// silently kept the bare Apple default — which contains neither
/// `/opt/homebrew/bin` (brew) nor `~/.local/bin` (uv, and anything else a
/// tool-manager installs). Every such command row then failed with "command not
/// found" while the tool was installed. Making the failure a case the type
/// system can see is what stops the default from surviving unnoticed.
nonisolated struct ShellEnvironment: Sendable {
    /// Where the path came from.
    enum Source: Sendable, Equatable {
        /// The user's own interactive login shell answered with `BZPATH=`.
        case loginShell
        /// No `BZPATH=` arrived, so the path is `fallbackPath`. The tool
        /// directories below are still present, which is the whole point: a
        /// failed shell must not degrade to a PATH that cannot find the tools.
        case fallback
    }

    var path: String
    var source: Source

    /// The PATH a login shell that never answered leaves behind.
    ///
    /// The Apple default plus the two directories tools actually install into.
    /// It mirrors what `AgentLocator.locate()` did before its removal (it
    /// appended `~/.local/bin` unconditionally and probed the Homebrew
    /// prefixes), so the salvaged code does not regress to a PATH that cannot
    /// find `brew` or `uv`.
    static var fallbackPath: String {
        "/usr/bin:/bin:/usr/sbin:/sbin"
            + ":\(AppEnvironment.realHome)/.local/bin"
            + ":/opt/homebrew/bin"
            + ":/usr/local/bin"
    }

    /// Built from a login shell's answer.
    init(loginShellPath: String) {
        path = loginShellPath
        source = .loginShell
    }

    /// The degraded path, used only when no login-shell PATH could be measured.
    init() {
        path = Self.fallbackPath
        source = .fallback
    }

    /// Whether `path` contains `dir`, tested segment-wise: a substring test
    /// would call `/opt/homebrew/bin2` a match for `/opt/homebrew/bin`.
    func contains(directory dir: String) -> Bool {
        path.split(separator: ":").contains(Substring(dir))
    }
}

/// What a `ShellRunner.run` attempt actually did.
///
/// The old `(out, status)` pair conflated "could not start", "timed out" and
/// "exited" under a sentinel status of -1, and discarded a timed-out shell's
/// output. `find()` then could not tell a real PATH from a failed probe, and a
/// timeout threw away the `BZPATH=` the shell had already printed. Each case is
/// its own state here, so a caller must decide what to do about each.
nonisolated enum ShellRunOutcome: Sendable, Equatable {
    /// The process ran to completion. `status` is its exit status.
    case finished(status: Int32, output: String)
    /// The executable could not be started at all (missing, not executable).
    case notStarted
    /// It was still running at the deadline and had to be killed. `output` is
    /// whatever it wrote before then — a shell that printed `BZPATH=` and then
    /// hung must not lose it.
    case timedOut(output: String)

    /// The output in every case, so a caller that only wants text (the
    /// xcode-select and simctl reads) does not have to switch on the outcome.
    var output: String {
        switch self {
        case .finished(_, let output), .timedOut(let output): return output
        case .notStarted: return ""
        }
    }
}

/// Runs a short-lived process and reads its whole output.
///
/// Separate from `ShellEnvironment` because one is a value and the other is a
/// measurement: `find()` asks the interactive login shell where the tools are,
/// `run()` runs a known binary (xcode-select, simctl) and reports what it said.
nonisolated enum ShellRunner {
    /// How long a killed process is given to honour SIGTERM before SIGKILL.
    /// Bounded so a wedged child cannot hold `run` for more than a moment.
    private static let killGrace: TimeInterval = 1

    /// Asks the user's interactive login shell for its PATH, off the main
    /// actor because a shell profile can take a moment.
    ///
    /// A missing `BZPATH=` — a timed-out or failed profile, a shell that
    /// prints nothing — falls back to the augmented PATH rather than to the
    /// bare Apple default. The fallback is what keeps the tool directories
    /// reachable when the login shell is not; see `ShellEnvironment.Source`.
    static func find() async -> ShellEnvironment {
        await Task.detached(priority: .userInitiated) {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let text = run(shell, ["-lic", "echo \"BZPATH=$PATH\""]).output
            return environment(fromShellOutput: text)
        }.value
    }

    /// The PATH decision, split out from `find()` so the failure path can be
    /// tested against literal shell output instead of a live shell.
    ///
    /// The bug this guards: a login shell that fails or times out produces no
    /// `BZPATH=`, and the code kept the bare Apple default — under which every
    /// allowlisted tool row (`brew cleanup`, `docker system prune`) fails with
    /// "command not found" even though the tool is installed. The fallback must
    /// therefore include the tool directories, and the LAST `BZPATH=` wins
    /// because a profile may echo more than one.
    static func environment(fromShellOutput text: String) -> ShellEnvironment {
        var measured: String?
        for line in text.split(separator: "\n") where line.hasPrefix("BZPATH=") {
            let value = String(line.dropFirst(7))
            if !value.isEmpty { measured = value }
        }
        guard let measured else { return ShellEnvironment() }
        return ShellEnvironment(loginShellPath: measured)
    }

    /// Runs `exe` with `args`, optionally under a PATH.
    ///
    /// Invariant: after this returns, no process it started is still running.
    /// SIGTERM alone does not give that — a child that ignores it survives, and
    /// a survivor holding the stdout pipe open parks the reader thread forever
    /// (the reader only sees EOF once the last writer closes it). So a timeout
    /// escalates to SIGKILL after a bounded grace, and only then does the read
    /// settle; the partial output is returned either way.
    static func run(_ exe: String, _ args: [String], envPath: String? = nil,
                    timeout: TimeInterval = 5) -> ShellRunOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        if let envPath {
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = envPath
            process.environment = environment
        }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .notStarted }
        // Read while it runs: output past the pipe's 64 KB would stall it.
        let text = OutputText()
        let read = DispatchGroup()
        read.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            text.set(out.fileHandleForReading.readDataToEndOfFile())
            read.leave()
        }
        // A slow shell profile shouldn't hold the panel up.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            stop(process)
            // A descendant may still hold the pipe open; don't wait on it. If
            // it does, `readDataToEndOfFile` stays parked, but `text` already
            // holds every byte written so far and is returned below.
            _ = read.wait(timeout: .now() + 1)
            return .timedOut(output: text.value)
        }
        // Something the shell left running may hold the pipe open; don't wait on it.
        _ = read.wait(timeout: .now() + 1)
        return .finished(status: process.terminationStatus, output: text.value)
    }

    /// Kills a still-running process: SIGTERM, a bounded wait, then SIGKILL.
    ///
    /// The grace is the whole point of the escalation. SIGTERM is the polite
    /// request, but a process is free to ignore it (`trap '' TERM`), and the
    /// previous code sent exactly one SIGTERM and moved on — so the child it
    /// had decided was too slow kept running. SIGKILL cannot be ignored or
    /// caught, which is what makes the "nothing survives `run`" invariant true.
    private static func stop(_ process: Process) {
        process.terminate()
        let graceDeadline = Date().addingTimeInterval(killGrace)
        while process.isRunning, Date() < graceDeadline { usleep(20_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
