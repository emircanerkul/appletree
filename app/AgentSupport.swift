import AppKit
import Foundation
import Observation
import SwiftUI

// "Clean up with Claude Code / Codex": the agent runs headless in the
// background, read-only, and only writes a plan from the scan AppleTree
// already has. Its steps and plan cards stream into the side panel as they
// happen. AppleTree then does the cleanup itself, behind its own guards:
// moving folders to the Trash or running the owning tool's cleanup command.
// MARK: - Agents on this Mac

nonisolated enum AgentKind: String, CaseIterable, Sendable {
    case claude, codex

    var name: String { self == .claude ? "Claude Code" : "Codex" }
}

nonisolated struct InstalledAgent: Identifiable, Hashable, Sendable {
    let kind: AgentKind
    /// Absolute path to the CLI.
    let path: String
    /// Signed in to an account, so a run can start right away.
    let signedIn: Bool
    var id: String { kind.rawValue }
}

nonisolated struct AgentEnvironment: Sendable {
    var agents: [InstalledAgent] = []
    /// The user's shell PATH: cleanup tools live in Homebrew, ~/.local/bin,
    /// nvm… none of which an app's PATH has.
    var path: String = "/usr/bin:/bin:/usr/sbin:/sbin"
    /// Set once the lookup has finished (an empty list then means none).
    var loaded = false

    var ready: [InstalledAgent] { agents.filter(\.signedIn) }
}

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
/// `LLMProvider` is Equatable but not Hashable, so identity here is the id
/// string alone — which is also what a Picker tags on and what `bz.engine`
/// stores. One identity, used for all three, so they cannot disagree.
nonisolated enum PlannerChoice: Identifiable, Sendable {
    /// Installed and signed in: a run can start now.
    case agent(InstalledAgent)
    /// A configured OpenAI- or Anthropic-compatible endpoint.
    case provider(LLMProvider)
    /// Installed but signed out: the entry signs it in.
    case agentSignedOut(AgentKind)
    /// Not installed: the entry installs it.
    case agentMissing(AgentKind)

    var id: String {
        switch self {
        case .agent(let a): return a.kind.rawValue
        case .provider(let p): return "provider:\(p.id)"
        case .agentSignedOut(let k), .agentMissing(let k): return k.rawValue
        }
    }

    var label: String {
        switch self {
        case .agent(let a): return a.kind.name
        case .provider(let p): return p.displayName
        case .agentSignedOut(let k), .agentMissing(let k): return k.name
        }
    }

    /// The installed agent behind this entry, when there is one. Only a
    /// signed-in agent is runnable; the other two agent cases need setup first.
    var installed: InstalledAgent? { if case .agent(let a) = self { return a } ; return nil }
    var providerValue: LLMProvider? { if case .provider(let p) = self { return p } ; return nil }
    var kind: AgentKind? {
        switch self {
        case .agent(let a): return a.kind
        case .agentSignedOut(let k), .agentMissing(let k): return k
        case .provider: return nil
        }
    }
    /// Ready to run without an install or a sign-in first.
    var runnable: Bool { installed != nil || providerValue != nil }

    // MARK: Presentation
    //
    // The labels live here, not in each view, so the panel's menu and Settings'
    // picker cannot describe the same planner differently. They are also then
    // plain values a test can assert.

    /// How the planner reads in the panel's menu.
    var menuLabel: String {
        switch self {
        case .agentSignedOut(let kind): return String(localized: "Sign in to \(kind.name)…")
        case .agentMissing(let kind): return String(localized: "Set up \(kind.name)…")
        default: return label
        }
    }

    /// How it reads in Settings' picker: a provider is marked custom so it is
    /// not mistaken for a CLI agent, and an agent that cannot run yet says so
    /// rather than looking like a working choice.
    var settingsLabel: String {
        switch self {
        case .provider(let provider): return String(localized: "\(provider.displayName) (custom)")
        case .agentSignedOut(let kind): return String(localized: "\(kind.name) (not signed in)")
        case .agentMissing(let kind): return String(localized: "\(kind.name) (not installed)")
        default: return label
        }
    }

    /// What the picked planner still needs, or nil when it can run now.
    var readinessNote: String? {
        switch self {
        case .agentSignedOut(let kind):
            return String(localized: "\(kind.name) is not signed in — sign in from the Clean Up panel.")
        case .agentMissing(let kind):
            return String(localized: "\(kind.name) is not installed — set it up from the Clean Up panel.")
        default:
            return nil
        }
    }

    /// The whole catalog, built once here so the panel's menu and Settings →
    /// General cannot list different planners or in a different order.
    ///
    /// Runnable planners lead (signed-in agents in `AgentKind` order, then
    /// configured providers), then the agents that need an install or a
    /// sign-in. Both agents are always present whatever is signed in — that is
    /// what makes the list non-empty, and an empty list is precisely what left
    /// a signed-in agent with no way out.
    static func catalog(agents: AgentEnvironment, providers: [LLMProvider]) -> [PlannerChoice] {
        let ready = agents.ready
        let installed = Set(agents.agents.map(\.kind))
        // Iterate `AgentKind.allCases` rather than the discovered array: the
        // catalog owns its order, so it does not inherit whatever order the
        // lookup happened to return. Both the panel's menu and Settings' picker
        // then list the same planners in the same place.
        var choices: [PlannerChoice] = AgentKind.allCases.compactMap { kind in
            ready.first { $0.kind == kind }.map { PlannerChoice.agent($0) }
        }
        choices += providers.map { .provider($0) }
        for kind in AgentKind.allCases where !ready.contains(where: { $0.kind == kind }) {
            choices.append(installed.contains(kind) ? .agentSignedOut(kind) : .agentMissing(kind))
        }
        return choices
    }

    /// The planner in effect within a catalog.
    ///
    /// A stored choice wins **while it can actually run**; otherwise the first
    /// runnable planner leads, so signing one agent out falls back to another
    /// instead of leaving a "sign in" button where a run used to be.
    ///
    /// When nothing can run, an agent that is *installed but signed out* beats
    /// one that is missing, and the stored pick is honoured among equals: one
    /// sign-in is a shorter path to a working planner than an install plus a
    /// sign-in. Only then does a stored-but-missing choice survive, and it
    /// reads as "set this one up". Never nil while any agent kind exists, so a
    /// Picker always has a row to show (an unmatched tag used to render the
    /// row blank).
    static func preferredID(stored: String?, in choices: [PlannerChoice]) -> String? {
        if let stored, choices.contains(where: { $0.id == stored && $0.runnable }) { return stored }
        if let first = choices.first(where: { $0.runnable }) { return first.id }
        // Closest to running: installed, just signed out.
        let signedOut = choices.filter { if case .agentSignedOut = $0 { return true } ; return false }
        if let stored, signedOut.contains(where: { $0.id == stored }) { return stored }
        if let first = signedOut.first { return first.id }
        if let stored, choices.contains(where: { $0.id == stored }) { return stored }
        return choices.first { $0.kind != nil }?.id
    }
}
nonisolated final class OutputText: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ new: Data) { lock.lock(); data = new; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
