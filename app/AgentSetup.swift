import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - One-click setup

/// Installs an agent into ~/.local/bin and signs it in through the browser,
/// all in the background; the panel shows where it is.
@Observable
@MainActor
final class AgentSetup {
    enum Step: Equatable { case installing, signingIn, failed(String) }

    let kind: AgentKind
    private(set) var step: Step
    private var process: Process?
    private var cancelled = false

    init(kind: AgentKind, installed: InstalledAgent?, envPath: String,
         done: @escaping (AgentEnvironment) -> Void) {
        self.kind = kind
        step = installed == nil ? .installing : .signingIn
        Task {
            var path = installed?.path
            if path == nil {
                let target = NSHomeDirectory() + "/.local/bin/" + kind.rawValue
                if let error = await shell(Self.installScript(kind)) {
                    if !cancelled { step = .failed("Couldn't install \(kind.name): \(error)") }
                    return
                }
                path = target
            }
            guard let path, !cancelled else { return }
            if !AgentLocator.isSignedIn(kind, path: path, envPath: envPath) {
                step = .signingIn
                // Opens the browser; the CLI finishes once the sign-in comes back.
                _ = await exec(path, kind == .claude ? ["auth", "login"] : ["login"], envPath: envPath)
                guard !cancelled else { return }
                if !AgentLocator.isSignedIn(kind, path: path, envPath: envPath) {
                    step = .failed("Sign-in didn't finish. Try again.")
                    return
                }
            }
            done(await AgentLocator.find())
        }
    }

    func cancel() {
        cancelled = true
        process?.terminate()
    }

    private static func installScript(_ kind: AgentKind) -> String {
        switch kind {
        case .claude:
            // Anthropic's own installer: everything under ~/.local, no sudo.
            return "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex:
            // OpenAI's standalone build: no Node needed. The version and its
            // SHA-256 are pinned so a new upstream release cannot change what
            // gets installed silently (S5). To update the pin: set VER to the
            // wanted release tag (github.com/openai/codex/releases), download
            // the codex-aarch64-apple-darwin.tar.gz of that release once,
            // run `shasum -a 256` on it, and paste the hash below.
            return """
            set -e; t=$(mktemp -d); mkdir -p "$HOME/.local/bin"
            VER="0.157.1"
            URL="https://github.com/openai/codex/releases/download/rust-v$VER/codex-aarch64-apple-darwin.tar.gz"
            curl -fsSL "$URL" -o "$t/codex.tar.gz"
            # SHA-256 of codex-aarch64-apple-darwin.tar.gz for $VER.
            echo "3c45b162b7a76f51325015b1d0a8112c73219b7a9b59cd5762c37c9ba55894fa  $t/codex.tar.gz" | shasum -a 256 -c - || { echo "Codex download failed the checksum check; nothing was installed." >&2; rm -rf "$t"; exit 1; }
            tar -xzf "$t/codex.tar.gz" -C "$t"
            mv "$t/codex-aarch64-apple-darwin" "$HOME/.local/bin/codex"; rm -rf "$t"
            """
        }
    }

    /// Runs a script; returns the last error line on failure.
    private func shell(_ script: String) async -> String? {
        await exec("/bin/bash", ["-c", script], envPath: "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    private func exec(_ exe: String, _ args: [String], envPath: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = envPath
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        process.standardError = err
        let tail = ErrTail()
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { tail.feed(data) }
        }
        do { try process.run() } catch { return error.localizedDescription }
        self.process = process
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { process.waitUntilExit(); c.resume() }
        }
        self.process = nil
        return process.terminationStatus == 0 ? nil : (tail.last.isEmpty ? "exit \(process.terminationStatus)" : tail.last)
    }
}
