// Planner catalog and sign-out harness.
//
// Build (from repo root):
//   swiftc tests/swift/planner.swift app/AgentSupport.swift app/AgentLocator.swift \
//       -parse-as-library -swift-version 6 -default-isolation MainActor \
//       -target arm64-apple-macos14.0 -o .build/planner-tests
//   .build/planner-tests
//
// Prints PASS/FAIL lines and exits nonzero on any failure.
//
// This covers the half of the reported defect a screenshot cannot: that the
// planner list is never empty, that the planner in effect resolves the same way
// for the panel and for Settings, and that signing out invokes exactly the
// command each CLI documents.
//
// `AgentSupport.swift` and `AgentLocator.swift` are compiled as real shipping
// sources — no stub copies — so the harness fails if the catalog rule or the
// logout argv drifts.

import Foundation

var failed = 0
var passed = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        passed += 1
        print("PASS \(name)")
    } else {
        failed += 1
        print("FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }
}

let home = NSHomeDirectory()

// MARK: - Fixtures

func agent(_ kind: AgentKind, signedIn: Bool) -> InstalledAgent {
    InstalledAgent(kind: kind, path: "\(home)/.local/bin/\(kind.rawValue)", signedIn: signedIn)
}

func env(_ agents: [InstalledAgent]) -> AgentEnvironment {
    AgentEnvironment(agents: agents, path: "/usr/bin:/bin", loaded: true)
}

func provider(_ id: String) -> LLMProvider {
    LLMProvider(id: id, displayName: id.capitalized,
                baseURL: URL(string: "https://\(id).example/v1")!,
                api: .openAIChat, model: "m")
}

func ids(_ choices: [PlannerChoice]) -> [String] { choices.map(\.id) }

@main
enum PlannerTests {
    static func main() {
        catalogIsNeverEmpty()
        choicesCarryTheirPlanner()
        storedPreferenceResolvesOneWay()
        labelsDescribeTheChoice()
        signOutUsesTheDocumentedCommand()

        print("")
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

// MARK: - S1: the catalog is never empty, whatever is installed

func catalogIsNeverEmpty() {
    // The reported state: one agent signed in, no custom provider. The old menu
    // was gated on `ready.count > 1 || !providers.isEmpty`, so this produced no
    // menu at all.
    let onlyCodex = PlannerChoice.catalog(agents: env([agent(.codex, signedIn: true)]), providers: [])
    check("S1 catalog non-empty with one signed-in agent", !onlyCodex.isEmpty,
          "got \(ids(onlyCodex))")
    check("S1 both agents listed with one signed in", Set(ids(onlyCodex)) == ["claude", "codex"],
          "got \(ids(onlyCodex))")
    check("S1 signed-in agent is runnable", onlyCodex.first?.runnable == true,
          "first: \(String(describing: onlyCodex.first))")
    check("S1 other agent is offered as setup, not hidden",
          onlyCodex.contains { $0.id == "claude" && $0.kind == .claude })
    check("S1 no provider entries", !onlyCodex.contains { $0.providerValue != nil })

    // Nothing installed at all: the install path must still be offered for both.
    let bare = PlannerChoice.catalog(agents: env([]), providers: [])
    check("S1 catalog non-empty with nothing installed", !bare.isEmpty)
    check("S1 bare Mac lists both agents as missing",
          bare.count == 2 && bare.allSatisfy { if case .agentMissing = $0 { return true } ; return false },
          "got \(bare.map { "\($0.id):\($0.runnable)" })")

    // Both agents signed in plus a provider: runnable first, in AgentKind order.
    let rich = PlannerChoice.catalog(
        agents: env([agent(.codex, signedIn: true), agent(.claude, signedIn: true)]),
        providers: [provider("acme")]
    )
    check("S1 runnable planners lead, in AgentKind order", ids(rich).prefix(2) == ["claude", "codex"],
          "got \(ids(rich))")
    check("S1 providers follow the agents", ids(rich) == ["claude", "codex", "provider:acme"],
          "got \(ids(rich))")
    check("S1 installed-but-signed-out is distinct from missing",
          PlannerChoice.catalog(agents: env([agent(.claude, signedIn: false)]), providers: [])
            .contains { if case .agentSignedOut(.claude) = $0 { return true } ; return false })
}

// MARK: - S2: which entry is runnable, and what it carries

func choicesCarryTheirPlanner() {
    let rich = PlannerChoice.catalog(
        agents: env([agent(.codex, signedIn: true), agent(.claude, signedIn: true)]),
        providers: [provider("acme")]
    )
    let providerChoice = rich.first { $0.id == "provider:acme" }
    check("S2 provider choice carries its LLMProvider", providerChoice?.providerValue?.id == "acme")
    check("S2 provider choice carries no agent", providerChoice?.installed == nil)
    check("S2 provider choice has no AgentKind", providerChoice?.kind == nil)
    check("S2 agent choice carries its path",
          rich.first { $0.id == "codex" }?.installed?.path == "\(home)/.local/bin/codex")
    check("S2 signed-out agent is not runnable",
          !PlannerChoice.catalog(agents: env([agent(.codex, signedIn: false)]), providers: [])
            .first { $0.id == "codex" }!.runnable)
}

// MARK: - S3: the stored preference resolves identically for panel and Settings

func storedPreferenceResolvesOneWay() {
    let bothReady = PlannerChoice.catalog(
        agents: env([agent(.codex, signedIn: true), agent(.claude, signedIn: true)]), providers: [])
    check("S3 a valid stored agent wins", PlannerChoice.preferredID(stored: "codex", in: bothReady) == "codex")
    check("S3 no stored choice falls back to the first runnable",
          PlannerChoice.preferredID(stored: nil, in: bothReady) == "claude",
          "got \(String(describing: PlannerChoice.preferredID(stored: nil, in: bothReady)))")

    // The bug the two surfaces disagreed on: the panel preferred a ready agent,
    // Settings preferred the first provider. One rule now, so this cannot differ.
    let codexAndProvider = PlannerChoice.catalog(
        agents: env([agent(.codex, signedIn: true)]), providers: [provider("acme")])
    check("S3 a stored provider wins over an earlier agent",
          PlannerChoice.preferredID(stored: "provider:acme", in: codexAndProvider) == "provider:acme")
    check("S3 a stored agent wins over a later provider",
          PlannerChoice.preferredID(stored: "codex", in: codexAndProvider) == "codex")

    // A dangling provider id must not survive as the selection: the row would
    // then have no matching tag and render blank.
    let dangling = PlannerChoice.preferredID(stored: "provider:gone", in: codexAndProvider)
    check("S3 dangling provider id falls back to a runnable planner",
          dangling == "codex", "got \(String(describing: dangling))")

    // Signing the selected agent out must move the engine, not strand the panel
    // on a planner that can no longer run.
    let codexSignedOut = PlannerChoice.catalog(
        agents: env([agent(.codex, signedIn: false), agent(.claude, signedIn: true)]), providers: [])
    let afterSignOut = PlannerChoice.preferredID(stored: "codex", in: codexSignedOut)
    check("S3 signing the picked agent out falls to a runnable one",
          afterSignOut == "claude", "got \(String(describing: afterSignOut))")

    // With nothing runnable an explicit pick is kept, so it reads as "sign this
    // in" instead of silently becoming a different engine.
    let nothingReady = PlannerChoice.catalog(agents: env([agent(.codex, signedIn: false)]), providers: [])
    check("S3 with nothing runnable the picked agent is kept",
          PlannerChoice.preferredID(stored: "codex", in: nothingReady) == "codex")
    check("S3 resolution is never nil while an agent kind exists",
          PlannerChoice.preferredID(stored: nil, in: nothingReady) != nil)

    // Precedence when nothing can run: an installed-but-signed-out agent is one
    // step from working, a missing one is two. This is the rule that keeps the
    // panel's caption and its button naming the same planner.
    let codexOutClaudeMissing = PlannerChoice.catalog(
        agents: env([agent(.codex, signedIn: false)]), providers: [])
    let signInBeatsInstall = PlannerChoice.preferredID(stored: "claude", in: codexOutClaudeMissing)
    check("S3 sign-in beats install when nothing is runnable", signInBeatsInstall == "codex",
          "got \(String(describing: signInBeatsInstall))")
    let storedOutRespected = PlannerChoice.preferredID(stored: "codex", in: codexOutClaudeMissing)
    check("S3 a stored signed-out agent is honoured among candidates",
          storedOutRespected == "codex", "got \(String(describing: storedOutRespected))")

    // Every runnable id must round-trip through the resolver, since that id is
    // both the Picker tag and the stored `bz.engine` value.
    let rich = PlannerChoice.catalog(
        agents: env([agent(.codex, signedIn: true), agent(.claude, signedIn: true)]),
        providers: [provider("acme")]
    )
    var allRoundTrip = true
    for choice in rich where choice.runnable {
        if PlannerChoice.preferredID(stored: choice.id, in: rich) != choice.id {
            allRoundTrip = false
            print("      round-trip failed for \(choice.id)")
        }
    }
    check("S3 every runnable id round-trips through the tag", allRoundTrip)
}

// MARK: - S4: labels describe the choice the same way on both surfaces

func labelsDescribeTheChoice() {
    let withProvider = PlannerChoice.catalog(
        agents: env([agent(.codex, signedIn: true), agent(.claude, signedIn: false)]),
        providers: [provider("acme")])

    // A provider must not read like a CLI agent in Settings.
    let acme = withProvider.first { $0.id == "provider:acme" }
    check("S4 provider is marked custom in Settings",
          acme?.settingsLabel.contains("custom") == true, "got \(acme?.settingsLabel ?? "nil")")
    check("S4 provider menu label is its display name",
          acme?.menuLabel == "Acme", "got \(acme?.menuLabel ?? "nil")")

    // An installed-but-signed-out agent is an action, not a run.
    let claude = withProvider.first { $0.id == "claude" }
    check("S4 signed-out agent offers sign-in in the menu",
          claude?.menuLabel.contains("Sign in") == true, "got \(claude?.menuLabel ?? "nil")")
    check("S4 signed-out agent says so in Settings",
          claude?.settingsLabel.contains("not signed in") == true, "got \(claude?.settingsLabel ?? "nil")")
    check("S4 signed-out agent explains what it needs", claude?.readinessNote != nil)

    // A signed-in agent is ready: no note, and no "(not signed in)" suffix.
    let codex = withProvider.first { $0.id == "codex" }
    check("S4 ready agent has no readiness note", codex?.readinessNote == nil)
    check("S4 ready agent is not marked unready",
          codex?.settingsLabel == "Codex", "got \(codex?.settingsLabel ?? "nil")")
    check("S4 ready agent runs from the menu", codex?.menuLabel == "Codex")

    // A missing agent is an install, not a sign-in.
    let missing = PlannerChoice.catalog(agents: env([]), providers: [])
        .first { $0.id == "claude" }
    check("S4 missing agent offers setup in the menu",
          missing?.menuLabel.contains("Set up") == true, "got \(missing?.menuLabel ?? "nil")")
    check("S4 missing agent says not installed in Settings",
          missing?.settingsLabel.contains("not installed") == true, "got \(missing?.settingsLabel ?? "nil")")
}

// MARK: - S5: sign-out invokes exactly the documented command

func signOutUsesTheDocumentedCommand() {
    check("S5 codex signs out with `logout`", AgentLocator.signOutArguments(.codex) == ["logout"],
          "got \(AgentLocator.signOutArguments(.codex))")
    check("S5 claude signs out with `auth logout`",
          AgentLocator.signOutArguments(.claude) == ["auth", "logout"],
          "got \(AgentLocator.signOutArguments(.claude))")
    check("S5 sign-out carries no extra flags",
          AgentLocator.signOutArguments(.codex).count == 1
            && AgentLocator.signOutArguments(.claude).count == 2)
    check("S5 sign-out shares the sign-in subcommand prefix",
          AgentLocator.signOutArguments(.claude)[0] == "auth")
}
