import AppKit
import Foundation
import Observation
import SwiftUI

nonisolated enum AgentLocator {
    nonisolated(unsafe) private static var qaFaked = false

    /// Asks the user's interactive login shell once where the CLIs are and
    /// what its PATH is, falls back to the usual install locations, then
    /// checks each one is signed in.
    static func find() async -> AgentEnvironment {
        await Task.detached(priority: .userInitiated) { locate() }.value
    }

    private static func locate() -> AgentEnvironment {
        var env = AgentEnvironment(loaded: true)
        // QA: pretend neither agent is installed, to see the setup offer.
        if ProcessInfo.processInfo.environment["BZ_QA_NO_AGENTS"] != nil, !qaFaked {
            qaFaked = true
            return env
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let text = run(shell, ["-lic", "echo \"BZPATH=$PATH\"; command -v claude; command -v codex"]).out
        var fromShell: [AgentKind: String] = [:]
        for line in text.split(separator: "\n").map(String.init) {
            if line.hasPrefix("BZPATH=") { env.path = String(line.dropFirst(7)) }
            guard line.hasPrefix("/") else { continue }
            for kind in AgentKind.allCases where line.hasSuffix("/\(kind.rawValue)") {
                fromShell[kind] = fromShell[kind] ?? line
            }
        }
        let home = NSHomeDirectory()
        // Where AppleTree's own setup installs them, even if no shell knows yet.
        if !env.path.split(separator: ":").contains("\(home)/.local/bin"[...]) {
            env.path += ":\(home)/.local/bin"
        }
        let fallbacks: [AgentKind: [String]] = [
            .claude: ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                      "/opt/homebrew/bin/claude", "/usr/local/bin/claude"],
            .codex: ["\(home)/.nvm/current/bin/codex", "\(home)/.local/bin/codex", "/opt/homebrew/bin/codex",
                     "/usr/local/bin/codex", "\(home)/.bun/bin/codex"],
        ]
        let found: [(AgentKind, String)] = AgentKind.allCases.compactMap { kind in
            let candidates = [fromShell[kind]].compactMap { $0 } + (fallbacks[kind] ?? [])
            guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            else { return nil }
            return (kind, path)
        }
        // Both checks at once; each takes a fraction of a second.
        var signedIn = [Bool](repeating: false, count: found.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: found.count) { i in
            let ok = isSignedIn(found[i].0, path: found[i].1, envPath: env.path)
            lock.lock(); signedIn[i] = ok; lock.unlock()
        }
        env.agents = found.enumerated().map { i, pair in
            InstalledAgent(kind: pair.0, path: pair.1, signedIn: signedIn[i])
        }
        return env
    }

    static func isSignedIn(_ kind: AgentKind, path: String, envPath: String) -> Bool {
        switch kind {
        case .claude:
            let r = run(path, ["auth", "status"], envPath: envPath)
            return r.out.contains("\"loggedIn\": true") || r.out.contains("\"loggedIn\":true")
        case .codex:
            return run(path, ["login", "status"], envPath: envPath).status == 0
        }
    }

    /// The CLI's own sign-out command, with the same argument discipline as
    /// the sign-in path: no extra flags, so what runs is exactly what the tool
    /// documents. `codex logout` and `claude auth logout` both exit 0 on
    /// success and leave the CLI needing a browser sign-in again.
    static func signOutArguments(_ kind: AgentKind) -> [String] {
        switch kind {
        case .claude: return ["auth", "logout"]
        case .codex: return ["logout"]
        }
    }

    /// Signs an agent out through its own CLI. Returns whether it succeeded;
    /// the caller re-reads the environment rather than assuming the result.
    ///
    /// Sign-out is a recovery path, not a convenience: without it a signed-in
    /// agent was a one-way door, and the account could not be changed or
    /// removed from inside the app at all.
    static func signOut(_ kind: AgentKind, path: String, envPath: String) -> Bool {
        run(path, signOutArguments(kind), envPath: envPath, timeout: 20).status == 0
    }

    static func run(_ exe: String, _ args: [String], envPath: String? = nil,
                    timeout: TimeInterval = 5) -> (out: String, status: Int32) {
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
        guard (try? process.run()) != nil else { return ("", -1) }
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
        if process.isRunning { process.terminate(); return ("", -1) }
        // Something the shell left running may hold the pipe open; don't wait on it.
        _ = read.wait(timeout: .now() + 1)
        return (text.value, process.terminationStatus)
    }
}
