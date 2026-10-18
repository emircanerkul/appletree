// Planner step one: moving folders to the Trash must make the views follow.
//
// Build (from repo root, same contract as the other suites):
//   swiftc tests/swift/planner-refresh.swift \
//       $(filter-out app/Main.swift,$(wildcard app/*.swift)) \
//       -import-objc-header app/bz.h -parse-as-library \
//       -swift-version 6 -default-isolation MainActor \
//       -target arm64-apple-macos14.0 -L target/release -lappletree \
//       -framework DiskArbitration -framework IOKit -framework Security \
//       -o .build/planner-refresh-tests
//
// The bug this exists for. The planner's two-step delete had exactly one
// refresh point, `onFinish`, called from `deleteForGood` — step TWO. Step one
// (`moveToTrash`) really moved the folders out of the scan root and told nobody:
// `AgentRun` holds a `Tree` but only `ScanModel` may edit it, so the list, the
// map, the rings and every byte total kept counting folders that were already
// in the Trash. Closing the run with "Keep in the Trash" — a documented exit,
// and the one that stages a reversible step — left them there for good, until a
// manual Rescan. Measured at HEAD before the fix, with the real `ContentView`
// and the real `AgentRun`: after step one the folder was off the disk and the
// list still read ["Doomed", "blob", "keep.bin"] with `node(at:) == 1` and
// `treeRevision == 0`.
//
// Why the test drives the REAL path rather than re-implementing it. The defect
// was not a wrong calculation, it was a missing report at a seam between two
// owners — so a test that calls `forgetPath` itself would pass on the broken
// code. This goes through `ScanModel.startProvider` → the real `AgentRun` → the
// real `moveToTrash` → the model's own `onMoved` closure → the real engine, and
// asserts on the tree the views read. The plan comes from a registered
// `URLProtocol`, so there is no server, no port and no network.
//
// It pins three separate contracts:
//   1. Step one reports exactly the paths that left the disk, so the tree stops
//      counting them. Blocked or failed cards are never forgotten.
//   2. A folder that disappears between the plan and step one ("Already gone")
//      is still forgotten: the tree was built from an earlier scan, so its node
//      is still there and would otherwise linger as a phantom row.
//   3. Step one does NOT call `onFinish`. That is the tempting one-line "fix"
//      and it is wrong: a rescan renumbers every node, discarding the zoom, the
//      selection and the plan's highlight overlay that the run is still holding.
//   4. Step two rescans ONLY when the run contained a tool-command card (Task 5).
//      A folder-only run already forgot its folders in step one, so a walk would
//      re-learn nothing and could only destroy view state. A command card clears
//      data behind the engine's back — `go clean -cache`, `npm cache clean` — and
//      only a walk can re-measure that.
//
// NOTE: the test file MUST NOT be named after any app/*.swift source. On a
// case-insensitive filesystem both would emit the same object file into one
// swiftc invocation, which silently clobbers one of them and fails the link.

import AppKit
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

func drain(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
}

/// Serves the plan over `URLSession.shared` for the provider client, so the run
/// exercises its real streaming parser without a socket.
///
/// The payload is installed by the test before the request is made: the fixture
/// paths are decided at runtime, so the plan cannot be a literal.
nonisolated final class PlanStub: URLProtocol {
    nonisolated(unsafe) static var plan = ""
    nonisolated(unsafe) static var requests = 0

    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    nonisolated override func startLoading() {
        PlanStub.requests += 1
        // The real wire shape: SSE deltas carrying the plan JSON.
        //
        // Built by serializing the whole event ONCE. Hand-assembling the
        // `content` string means escaping the plan JSON by hand, and a mistake
        // there is invisible from the outside: the transport still delivers a
        // well-formed event, the delta just decodes to the wrong text and the
        // client reports "no plan" — a stub bug that looks exactly like an app
        // bug. Letting `JSONSerialization` own both layers removes that.
        let event: [String: Any] = ["choices": [["delta": ["content": PlanStub.plan]]]]
        let payload = (try? JSONSerialization.data(withJSONObject: event)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let sse = "data: " + payload + "\n\ndata: [DONE]\n\n"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream",
                                                      "Content-Length": String(sse.utf8.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(sse.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    nonisolated override func stopLoading() {}
}

@MainActor
func run() async {
    let fm = FileManager.default
    // Rooted in the home folder, the convention the other suites use: the guard
    // permits `$HOME/<dir>/<child>` (depth ≥ 2) and refuses anything under
    // ~/Documents, so a scratch dir in the temp folder could not be trashed by
    // the planner path this test is about.
    let scratch = URL(fileURLWithPath: CleanupGuard.home + "/planner-refresh-test")
    let doomed = scratch.appendingPathComponent("Doomed")
    let keeps = scratch.appendingPathComponent("keep.bin")
    try? fm.removeItem(at: scratch)
    try? fm.createDirectory(at: doomed, withIntermediateDirectories: true)
    try? Data(count: 2_000_000).write(to: doomed.appendingPathComponent("blob"))
    try? Data(count: 100_000).write(to: keeps)
    defer { try? fm.removeItem(at: scratch) }

    // Precondition: the fixture must be one the guard actually permits, or the
    // card would be created blocked and nothing below would be exercised.
    check("the fixture is permitted by the guard",
          CleanupGuard.blockReason(path: doomed.path) == nil,
          CleanupGuard.blockReason(path: doomed.path) ?? "")

    // A real tree, from the real engine, over the fixture.
    guard let tree = scan(scratch.path) else {
        check("the engine scanned the fixture", false, "the scan did not finish")
        print("\(passed) passed, \(failed) failed")
        exit(1)
    }
    check("the tree holds the folder", tree.node(at: doomed.path) != nil)

    // Two cards: the one that will move, and one the guard refuses. The refused
    // card proves the report is filtered by what really left the disk.
    let protected = CleanupGuard.home + "/Documents/planner-refresh-never-touched"
    PlanStub.plan = """
    {"summary":"2 MB can go","items":[\
    {"title":"Doomed","detail":"fixture","group":"safe","bytes":2000000,\
    "paths":["\(doomed.path)"],"action":"trash","command":""},\
    {"title":"Protected","detail":"fixture","group":"safe","bytes":1,\
    "paths":["\(protected)"],"action":"trash","command":""}]}
    """
    URLProtocol.registerClass(PlanStub.self)
    defer { URLProtocol.unregisterClass(PlanStub.self) }

    // `startProvider` writes the planner choice and reads the consent flag, both
    // through `UserDefaults.standard`. Snapshot and restore, so a test run never
    // edits the preference it is checking (the rule planner-selection.swift sets).
    let realEngine = UserDefaults.standard.string(forKey: "bz.engine")
    let realConsent = UserDefaults.standard.object(forKey: "bz.cleanupConsent")
    UserDefaults.standard.set(true, forKey: "bz.cleanupConsent")
    defer {
        if let realEngine { UserDefaults.standard.set(realEngine, forKey: "bz.engine") }
        else { UserDefaults.standard.removeObject(forKey: "bz.engine") }
        if let realConsent { UserDefaults.standard.set(realConsent, forKey: "bz.cleanupConsent") }
        else { UserDefaults.standard.removeObject(forKey: "bz.cleanupConsent") }
        ProviderStore.shared.select(engineTag: realEngine)
    }

    // The real model, holding the real tree — the whole app except Main.swift is
    // compiled in, so this is the same `ScanModel` the views read.
    let model = ScanModel()
    model.tree = tree
    model.scanRoot = scratch.path

    let provider = LLMProvider(id: "planner-refresh-stub", displayName: "Stub",
                               baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                               api: .openAIChat, model: "stub")
    model.startProvider(provider)
    guard let aiRun = model.agentRun else {
        check("the run started", false, "startProvider produced no run")
        print("\(passed) passed, \(failed) failed")
        exit(1)
    }

    var waited = 0.0
    while aiRun.phase == .thinking && waited < 30 { drain(0.2); waited += 0.2 }
    check("the plan arrived", aiRun.phase == .planned, "phase=\(aiRun.phase)")
    check("the stub was actually asked", PlanStub.requests > 0)

    // The protected card must be blocked, so it can never be selected or moved.
    let blocked = aiRun.items.first { $0.spec.title == "Protected" }
    check("the refused card is blocked, not offered",
          blocked?.blocked != nil, "blocked=\(blocked?.blocked ?? "nil")")
    for item in aiRun.items where item.blocked == nil { item.selected = true }
    check("the movable card is ticked", aiRun.items.contains { $0.selected && $0.blocked == nil })

    let before = tree.alloc[0]
    let revisionBefore = model.treeRevision
    let treeBefore = model.tree

    /* ---- 1. Step one: the report and the tree ------------------------------ */
    aiRun.moveToTrash()
    waited = 0.0
    while aiRun.phase == .trashing && waited < 30 { drain(0.2); waited += 0.2 }
    drain(1.0)
    check("step one completed", aiRun.phase == .staged, "phase=\(aiRun.phase)")
    check("the folder really left the disk", !fm.fileExists(atPath: doomed.path))
    check("the refused folder was NOT touched", !fm.fileExists(atPath: protected))
    check("the refused folder was never trashed", blocked?.status == .skipped,
          "status=\(String(describing: blocked?.status))")

    check("STEP ONE: the tree no longer holds the folder",
          model.tree?.node(at: doomed.path) == nil,
          "the list, the map and the totals still count a folder that is in the Trash")
    check("STEP ONE: the tree lost exactly the folder's bytes",
          model.tree!.alloc[0] < before,
          "root size \(before) did not drop; a stale total is what the user sees")
    check("STEP ONE: the views were told something changed",
          model.treeRevision != revisionBefore,
          "an in-place edit keeps the Tree identity, so the revision is what the views compare")
    check("STEP ONE: the tree was edited in place, not replaced",
          model.tree === treeBefore,
          "a replacement renumbers every node and discards the open plan's highlight overlay")

    // The overlay the run still holds must survive the edit and not name the
    // forgotten node: `highlights` is what the map and the rings read.
    let lit = aiRun.highlights(in: model.tree)
    check("the staged plan's highlight overlay still reads the live tree",
          !lit.contains(where: { !model.tree!.isAttached($0) }),
          "the overlay names a detached node; the map would draw bytes that are gone")

    /* ---- 2. The race: gone between the plan and step one ------------------- */
    // A second folder that the plan names, removed from the disk after the plan
    // was validated and before step one runs. This is the "Already gone" case.
    let vanished = scratch.appendingPathComponent("Vanished")
    try? fm.createDirectory(at: vanished, withIntermediateDirectories: true)
    try? Data(count: 1_000_000).write(to: vanished.appendingPathComponent("b"))
    // The tree cannot see it (it was scanned before), which is precisely the
    // situation: the plan names a path, the tree has no node for it, and the
    // disk has lost it too. Step one must not claim a failure that leaves a row.
    try? fm.removeItem(at: vanished)
    PlanStub.plan = """
    {"summary":"1 MB can go","items":[\
    {"title":"Vanished","detail":"fixture","group":"safe","bytes":1000000,\
    "paths":["\(vanished.path)"],"action":"trash","command":""}]}
    """
    aiRun.moveToTrash()
    drain(0.4)
    // Step one is single-shot per run; this second call is a no-op by design, so
    // the already-gone contract is asserted at the owner that decides it.
    check("RACE: an already-gone path counts as having left the disk",
          TrashOutcome(source: vanished.path, trashed: nil,
                       reason: TrashOutcome.alreadyGone).leftTheDisk,
          "the caller would keep a phantom node for a folder that is not on disk")
    check("RACE: a genuinely failed path is not mistaken for a removal",
          !TrashOutcome(source: vanished.path, trashed: nil, reason: "Permission denied").leftTheDisk)

    /* ---- 3. Step two: rescan ONLY when a command card ran ------------------ */
    // Updated for Task 5. Step two's rescan used to be unconditional, and this
    // suite pinned it. It is not unconditional any more, and it must not be:
    // step one already forgot every folder it moved, in place, so a folder-only
    // run has nothing left to re-measure and rescanning would only discard the
    // zoom, the selection and the plan's overlay. A COMMAND card is the
    // exception — `go clean -cache` empties a cache folder the engine tree
    // still holds, and only a walk can re-measure that — so the decision is
    // read from the run.
    //
    // The predicate is asserted directly rather than by executing a real tool
    // cleanup: this suite must not run `go`/`brew`/`pnpm` on the machine it is
    // run on, and a blocked command card never reaches the cleaning steps at
    // all. `hasCommandCards` is the whole of the decision, and it is what the
    // model's `onFinish` reads, so this is the contract that matters.
    check("STEP TWO: a folder-only run asks for no rescan",
          !aiRun.hasCommandCards,
          "this run moved only folders; a rescan would renumber every node to re-learn nothing")
    // A command card that did NOT leave the disk is still a command card: the
    // cache it cleared is what the rescan exists for. A card the user left
    // unticked, or one the guard blocked, must NOT trigger it — nothing of
    // theirs ran.
    //
    // The card's path must EXIST, or `PlanItem` blocks the card "Already
    // clean" and the command never runs — in which case no rescan is the right
    // answer for the wrong reason, and this check would prove nothing.
    let commandTarget = scratch.appendingPathComponent("command-cache")
    try? fm.createDirectory(at: commandTarget, withIntermediateDirectories: true)
    // A command that is allowlisted AND stays a COMMAND card.
    //
    // What the fixture had to clear, verified against `CleanupGuard`:
    // `go clean -cache` and `brew cleanup` are both allowlisted and both stay
    // command cards (`viaTrash == false`), so either would do. `npm cache clean`
    // is allowlisted too, but gets converted into a FOLDER card when its cache
    // folder exists (`viaTrash` is true, so `isCommand` is false) — rightly
    // needing no rescan, because the folder path is forgotten in place.
    // Measured: `npm cache clean` → viaTrash=true, isCommand=false;
    // `brew cleanup` → viaTrash=false, isCommand=true.
    //
    // The first attempt at this failed on "Already clean", which is a
    // DIFFERENT trap worth keeping in mind: `PlanItem` blocks a command card
    // whose paths all fail to exist, so the command never runs — and "no
    // rescan" would then be the right answer for the wrong reason. Hence the
    // real directory above.
    let commandSpec = PlanItemSpec(title: "Homebrew cleanup", detail: "fixture",
                                   group: .safe, bytes: 1, paths: [commandTarget.path],
                                   action: .command, command: "brew cleanup")
    let unticked = PlanItem(spec: commandSpec, tree: tree)
    unticked.selected = false
    check("STEP TWO: an unticked command card does not ask for a rescan",
          !(unticked.selected && unticked.blocked == nil && unticked.isCommand))
    let ticked = PlanItem(spec: commandSpec, tree: tree)
    ticked.selected = true
    check("STEP TWO: a ticked command card DOES ask for a rescan",
          ticked.blocked == nil && ticked.isCommand,
          "blocked=\(ticked.blocked ?? "nil") viaTrash=\(ticked.viaTrash) isCommand=\(ticked.isCommand)")

    let treeAtStaging = model.tree
    let revisionAtStaging = model.treeRevision
    aiRun.deleteForGood(env: model.shellEnv)
    waited = 0.0
    while aiRun.phase != .done && waited < 40 { drain(0.3); waited += 0.3 }
    check("step two finished", aiRun.phase == .done, "phase=\(aiRun.phase)")
    // Give a rescan every chance to appear, so "no rescan" is a real answer
    // rather than a race won by asserting too early.
    drain(2.0)
    check("STEP TWO: the folder-only run did NOT rescan",
          model.tree === treeAtStaging,
          "the tree was replaced; a folder-only run has nothing a walk could add")
    check("STEP TWO: the tree was still edited in place (or already was)",
          model.treeRevision >= revisionAtStaging)
    check("STEP TWO: the moved folder is still gone from the tree",
          model.tree?.node(at: doomed.path) == nil,
          "step one's in-place forget must have removed it")
    check("STEP TWO: the finished run stops offering a highlight overlay",
          aiRun.highlights(in: model.tree).isEmpty,
          "a .done run must not paint ids from a plan whose cards are gone")

    print("\(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}

/// A real `Tree` over `path`, from the real engine, or nil if the scan failed.
@MainActor
func scan(_ path: String) -> Tree? {
    guard let handle = bz_scan_start(path) else { return nil }
    let deadline = Date().addingTimeInterval(60)
    var done: Int32 = 0
    while Date() < deadline {
        var files: UInt64 = 0, dirs: UInt64 = 0, bytes: UInt64 = 0
        bz_progress(handle, &files, &dirs, &bytes, &done)
        if done != 0 { break }
        usleep(2000)
    }
    guard done != 0 else { bz_free(handle); return nil }
    return Tree(handle: handle)
}

@main
enum PlannerRefresh {
    static func main() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        await run()
    }
}
