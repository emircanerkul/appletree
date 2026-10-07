// The planner prompt's scope: it may only describe folders the scan covered.
//
// An `/Applications` scan used to hand the planner Xcode's simulator runtimes
// from `/System/Library/AssetsV2/…`, because `AgentPrompt.appData()` appended
// that section unconditionally. The planner nominated them, and the panel —
// headed "Here's the plan" for the Applications scan — filled with two cards
// for folders the user never scanned. Report: "I'm searching Application
// folder why it shows folder inside System in the list".
//
// `appData(tree:)` now keeps a row only when its path resolves in the scanned
// tree. This suite pins both halves: the pure path parsing, and that an
// `/Applications` tree genuinely does not resolve a `/System` path — which is
// what makes the gate meaningful rather than a hardcoded exclusion.
//
// Built against the real shipping sources (the whole app except Main.swift),
// like the other Swift suites, so it fails if the seam drifts.

import Foundation
import AppKit

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

/// Scans `path` to completion and returns its tree, or nil when it cannot.
func scanTree(_ path: String) -> Tree? {
    guard let handle = bz_scan_start(path) else { return nil }
    var done: Int32 = 0
    while done == 0 {
        var files: UInt64 = 0, dirs: UInt64 = 0, bytes: UInt64 = 0
        bz_progress(handle, &files, &dirs, &bytes, &done)
        if done == 0 { usleep(20_000) }
    }
    return Tree(handle: handle)
}

func run() {
    // --- the pure path parsing -------------------------------------------
    //
    // `simctl runtime list -j` reports the runtime's inner `.dmg`; the plan
    // names the `.asset` folder, which is the path `tree.node(at:)` resolves.
    let dmg = "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/"
        + "26c9174130fa5962f3e60f2a49963194dadbae4c.asset/AssetData/Restore/094-56039-099.dmg"
    check("a runtime .dmg path maps to its .asset folder",
          AgentPrompt.assetFolder(ofReportedPath: dmg)
            == "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/"
             + "26c9174130fa5962f3e60f2a49963194dadbae4c.asset",
          AgentPrompt.assetFolder(ofReportedPath: dmg))
    // A path with no `.asset` component is uncovered, not silently kept.
    check("a path without .asset yields no folder",
          AgentPrompt.assetFolder(ofReportedPath: "/tmp/some/runtime.dmg") == "",
          AgentPrompt.assetFolder(ofReportedPath: "/tmp/some/runtime.dmg"))
    check("an empty path yields no folder", AgentPrompt.assetFolder(ofReportedPath: "") == "")

    // --- the gate, against a real /Applications scan ----------------------
    guard let apps = scanTree("/Applications") else {
        check("an /Applications scan can be taken", false, "bz_scan_start returned nil")
        return
    }
    // The mechanism the gate relies on: a path outside the scan root does not
    // resolve in that tree. If this ever became true, the gate would silently
    // pass everything and the bug would return unnoticed.
    let simAsset = "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/"
        + "26c9174130fa5962f3e60f2a49963194dadbae4c.asset"
    check("/Applications tree does not resolve a /System path",
          apps.node(at: simAsset) == nil,
          "resolved to \(apps.node(at: simAsset).map(String.init) ?? "nil")")
    // A path inside the scan does resolve, so the check above is discriminating
    // rather than always-nil.
    check("/Applications tree resolves a path inside it",
          apps.node(at: "/Applications") != nil)

    // The section itself: no `/System` row may reach the planner.
    let appsSection = AgentPrompt.appData(tree: apps)
    check("an /Applications scan contributes no simulator section",
          appsSection.isEmpty, String(appsSection.prefix(200)))
    check("an /Applications scan names no /System path",
          !appsSection.contains("/System"), String(appsSection.prefix(200)))

    // --- the disk scan still offers them ---------------------------------
    //
    // Where the runtimes live *is* covered by a whole-disk scan, so the offer
    // must survive. Skipped when the machine has no Xcode: with no `simctl`
    // there are no runtimes to find, and the section is legitimately empty.
    let developer = ShellRunner.run("/usr/bin/xcode-select", ["-p"]).output
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let hasSimctl = !developer.isEmpty
        && FileManager.default.isExecutableFile(atPath: developer + "/usr/bin/simctl")
    if hasSimctl, let disk = scanTree("/System/Volumes/Data") {
        check("a disk scan resolves the simulator asset folder",
              disk.node(at: simAsset) != nil, "did not resolve \(simAsset)")
        let diskSection = AgentPrompt.appData(tree: disk)
        check("a disk scan still offers the simulator section",
              diskSection.contains("Xcode simulators"),
              String(diskSection.prefix(200)))
        check("the offered rows name an existing path, never the inner .dmg",
              !diskSection.contains("Restore/") && !diskSection.contains(".dmg"),
              String(diskSection.prefix(400)))
    } else {
        print("SKIP disk-scan half (no simctl or no disk scan available)")
    }
}

@main
enum PromptScopeTests {
    static func main() {
        run()
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
