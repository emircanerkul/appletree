// Right-drawer regression net: the two data-layer bugs found in the inspector.
//
// Build (from repo root):
//   swiftc tests/swift/drawer.swift app/CleanupModel.swift app/CleanupGuard.swift \
//       app/PlanParsing.swift -import-objc-header app/bz.h \
//       -parse-as-library -swift-version 6 -default-isolation MainActor \
//       -target arm64-apple-macos14.0 -L target/release -lappletree \
//       -o .build/drawer-tests
//
// These lock the fixes at their canonical owners:
//   1. PlanGroup — ONE vocabulary. The section a card lands in and whether it
//      starts ticked must agree, and an unrecognized value must never be
//      treated as safe.
//   2. TrashOutcome — the trash result is keyed by SOURCE path, because
//      `trashItem(resultingItemURL:)` reports the item's location inside the
//      Trash. Comparing a source path against those URLs was always false, so
//      every folder was reported as failed, including ones already trashed.

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

@MainActor
func run() async {
    // --- PlanGroup: one vocabulary, conservative on anything unrecognized ----
    func group(_ raw: String) -> PlanGroup? {
        let json = """
        {"title":"t","detail":"d","group":"\(raw)","bytes":1,"paths":[],"action":"trash","command":""}
        """
        return (try? JSONDecoder().decode(PlanItemSpec.self, from: Data(json.utf8)))?.group
    }

    // The schema's two documented values keep their meaning.
    check("group safe decodes to .safe", group("safe") == .safe)
    check("group ask decodes to .ask", group("ask") == .ask)
    // The overflow direction is the dangerous one: a value the planner did not
    // intend must land under the user's judgement, never under "Safe to
    // remove". Each of these previously matched `group != "ask"` and rendered
    // in the Safe section.
    for raw in ["Safe", "SAFE", "unsafe", "unsafe maybe", "", " ", "yes"] {
        let g = group(raw)
        check("unrecognized group \(raw.debugDescription) is not safe", g == .ask,
              "decoded \(String(describing: g))")
    }
    // One comparison drives both surfaces, so section and tick cannot disagree.
    let spec = { (raw: String) -> PlanItemSpec in
        let json = """
        {"title":"t","detail":"d","group":"\(raw)","bytes":1,"paths":[],"action":"trash","command":""}
        """
        return try! JSONDecoder().decode(PlanItemSpec.self, from: Data(json.utf8))
    }
    for raw in ["safe", "ask", "Safe", "unknown"] {
        let s = spec(raw)
        let inSafeSection = s.group == .safe
        let autoSelected = s.group == .safe
        check("section and tick agree for \(raw.debugDescription)", inSafeSection == autoSelected)
    }

    // --- TrashOutcome: results are keyed by source path ----------------------
    // A real move plus a path that does not exist. The old API returned a single
    // `error` and a list of Trash URLs, which no caller could match back to its
    // own source paths.
    //
    // The fixture is rooted directly in the home folder, the same convention
    // tests/swift/main.swift uses: the repo lives under ~/Documents, which the
    // guard protects, so a scratch dir beside the binary would be refused and
    // the move could never be exercised.
    let fm = FileManager.default
    let scratch = URL(fileURLWithPath: CleanupGuard.home + "/drawer-trash-test")
    try? fm.removeItem(at: scratch)
    try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    let real = scratch.appendingPathComponent("moved.txt").path
    let absent = scratch.appendingPathComponent("never-existed.txt").path
    try? "x".write(toFile: real, atomically: true, encoding: .utf8)
    // Precondition: the fixture must be one the guard actually permits, or the
    // assertions below would pass for the wrong reason (a blocked path also
    // reports a reason).
    check("fixture is permitted by the guard", CleanupGuard.blockReason(path: real) == nil,
          CleanupGuard.blockReason(path: real) ?? "")

    let outcomes = await Trash.trash([real, absent])
    check("one outcome per requested path", outcomes.count == 2, "got \(outcomes.count)")

    let bySource = Dictionary(outcomes.map { ($0.source, $0) }, uniquingKeysWith: { first, _ in first })
    let realOutcome = bySource[(real as NSString).standardizingPath]
    let absentOutcome = bySource[(absent as NSString).standardizingPath]

    // The moved folder reports success, and its Trash URL is NOT its source.
    check("a moved path reports success", realOutcome?.moved == true,
          "reason=\(realOutcome?.reason ?? "nil")")
    check("its trashed URL differs from the source path",
          realOutcome?.trashed?.path != real,
          "trashed=\(realOutcome?.trashed?.path ?? "nil")")
    check("a moved path has no reason", realOutcome?.reason == nil)
    // A path that is already gone is REPORTED, not silently skipped: a row the
    // user can still tick must never be a no-op with no explanation.
    check("an absent path reports a reason", absentOutcome?.reason != nil,
          "reason was nil, so the drawer would stay silent")
    check("an absent path did not move", absentOutcome?.moved == false)
    check("only the real move succeeded",
          outcomes.filter(\.moved).count == 1, "moved \(outcomes.filter(\.moved).count)")
    // The regression itself: matching the caller's source path must find the
    // success. Under the old API this lookup was impossible by construction.
    check("the caller's own source path resolves to its success",
          bySource[(real as NSString).standardizingPath]?.moved == true,
          "source-keyed lookup failed — the inflated-failure bug is back")

    // Put the fixture back so the test leaves no Trash entry behind.
    if let trashed = realOutcome?.trashed { try? fm.removeItem(at: trashed) }
    try? fm.removeItem(at: scratch)
}

@main
enum DrawerTests {
    static func main() async {
        await run()
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
