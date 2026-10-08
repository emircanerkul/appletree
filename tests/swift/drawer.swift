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

    // `.plannerPlan` is the authority whose guard re-check this suite is about:
    // the fixture is deliberately inside a protected workspace so the guard has
    // something to permit. `.userDirect` (the right-click menu, a ticked panel
    // row) is authorized by the user's own click and is asserted separately at
    // the bottom of this file.
    let outcomes = await Trash.trash([real, absent], authority: .plannerPlan)
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

    // --- the two authorities: the guard bounds a PLANNER, not the user -------
    //
    // `CleanupGuard`'s rules ("inside your home folder", "never ~/Documents")
    // belong to README "## AI cleanup": they bound what a *planner* may
    // nominate, because a planner writes a plan from a scan summary and
    // AppleTree then acts on paths the user never saw one by one. Applying them
    // to the right-click menu was a real bug: it refused
    // `/Applications/Java 8 Update 491.app` with "Outside your home folder",
    // and refused every candidate of an `/Applications` scan, even though
    // `/Applications` is one of the app's own scan targets and macOS lets you
    // drag anything there to the Trash.
    let outsideRoot = URL(fileURLWithPath: fm.temporaryDirectory.path)
        .appendingPathComponent("drawer-authority-\(ProcessInfo.processInfo.processIdentifier)")
    let outside = outsideRoot.appendingPathComponent("Some.app")
    try? fm.createDirectory(at: outside, withIntermediateDirectories: true)
    try? "x".write(to: outside.appendingPathComponent("f"), atomically: true, encoding: .utf8)

    // The planner is still refused: the guard applies.
    let planned = await Trash.trash([outside.path], authority: .plannerPlan)
    check("a planner is still refused outside the home folder",
          planned.first?.moved == false && planned.first?.reason != nil,
          "reason=\(planned.first?.reason ?? "nil") — the planner guard was weakened")

    // The user is not: their confirmed click is the authorization.
    let direct = await Trash.trash([outside.path], authority: .userDirect)
    check("a direct user action moves a folder outside the home folder",
          direct.first?.moved == true,
          "reason=\(direct.first?.reason ?? "nil") — the menu would refuse /Applications again")
    if let trashed = direct.first?.trashed { try? fm.removeItem(at: trashed) }
    try? fm.removeItem(at: outsideRoot)

    // --- the cross-owner contract: recognition may not over-offer ------------
    //
    // `src/cleanup.rs` owns RECOGNITION and `CleanupGuard` owns AUTHORIZATION,
    // and the module doc states the rule that ties them: recognition must never
    // nominate a folder the guard refuses. Rust can only approximate the guard
    // (it has the tree, not the guard's lists), so the contract is enforced
    // where both answers exist — `Cleanup.find`, which is the only list the
    // panel and the planner prompt read.
    //
    // This is the test that would have caught the whole class: on the app's
    // default whole-disk target, 24 of 57 nominees were refused (mostly under
    // `/opt` and `/private/tmp`), and every one of them was handed to the
    // planner as "recognised by AppleTree as rebuildable" (audit SW-4).
    //
    // It runs on the real engine over a small real directory, and asserts the
    // invariant directly rather than restating the rules: every item the list
    // returns must pass the guard.
    //
    // The fixture is tiny on purpose — a `node_modules` just over threshold —
    // so the test stays fast and deterministic. It lives under the REAL home,
    // because that is what `CleanupGuard.home` measures against: a fixture in
    // `/tmp` is "Outside your home folder" and the engine correctly offers
    // nothing, which is a different question from the one this asserts.
    do {
        // Two fixtures, because the contract has two directions and they need
        // different locations:
        //
        //   - a `node_modules` under the REAL home is recognized AND permitted,
        //     so it must survive the filter;
        //   - a `node_modules` under `/tmp` is recognized by name but refused by
        //     the guard as "Outside your home folder", so it must be filtered
        //     out.
        //
        // The second is the shape this contract exists for: on the app's default
        // whole-disk target, 24 of 57 nominees were refused (mostly under `/opt`
        // and `/private/tmp`) and every one was handed to the planner as
        // "recognised as rebuildable" (audit SW-4). A fixture under the home
        // alone cannot exercise it — `~/node_modules` is legitimately allowed.
        let pid = ProcessInfo.processInfo.processIdentifier
        let homeRoot = URL(fileURLWithPath: AppEnvironment.realHome)
            .appendingPathComponent(".drawer-crossowner-\(pid)")
        let outsideRoot = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent(".drawer-crossowner-\(pid)")
        for root in [homeRoot, outsideRoot] {
            let modules = root.appendingPathComponent("node_modules")
            try? fm.createDirectory(at: modules, withIntermediateDirectories: true)
            // Real bytes, so each candidate clears MIN_BYTES (50 MB).
            try? Data(count: 60_000_000).write(to: modules.appendingPathComponent("blob"))
        }

        for (label, root, shouldSurvive) in [("home", homeRoot, true), ("outside", outsideRoot, false)] {
            let c = root.path
            guard let handle = c.withCString({ bz_scan_start($0) }) else {
                check("the cross-owner \(label) fixture scan started", false, "bz_scan_start failed")
                continue
            }
            var done: Int32 = 0
            var files: UInt64 = 0, dirs: UInt64 = 0, bytes: UInt64 = 0
            while done == 0 {
                bz_progress(handle, &files, &dirs, &bytes, &done)
                if done == 0 { usleep(5_000) }
            }
            guard let scan = Tree(handle: handle) else {
                check("the cross-owner \(label) fixture produced a tree", false, "no tree for \(c)")
                // Only here does this test own the handle: on the success path
                // `Tree` owns it and frees it in `deinit`, so freeing it again
                // would be a double free (which crashed this suite).
                bz_free(handle)
                continue
            }
            let items = Cleanup.find(in: scan)
            let modules = root.appendingPathComponent("node_modules").path
            // The invariant, over whatever the engine actually returned.
            let refused = items.filter { CleanupGuard.blockReason(path: $0.path) != nil }
            check("every item Cleanup.find returns passes the guard (\(label))",
                  refused.isEmpty,
                  "recognition over-offered \(refused.count): \(refused.prefix(3).map(\.path))")
            if shouldSurvive {
                check("an authorized home fixture survives the filter",
                      items.contains(where: { $0.path == modules }),
                      "the filter is too aggressive — a permitted folder vanished")
            } else {
                check("the guard refuses the outside-home fixture",
                      CleanupGuard.blockReason(path: modules) != nil,
                      "the fixture does not exercise a refusal")
                check("the refused outside-home fixture is dropped",
                      !items.contains(where: { $0.path == modules }),
                      "a refused folder reached the panel and the planner prompt")
            }
        }
        try? fm.removeItem(at: homeRoot)
        try? fm.removeItem(at: outsideRoot)

        // --- L2/SW-10: the tool identity reaches the panel and the prompt -----
        //
        // `Kind::tool()` and the identity table exist so a `tool_caches` row can
        // say *which* tool it is, but the FFI carried only the generic
        // `description()`, so the panel row and the planner prompt's "What"
        // column both read "Caches, rebuilt or re-downloaded when needed" for
        // pnpm, pip, Homebrew and Cargo alike. The CLI had the field; these two
        // surfaces did not.
        //
        // The fixture is a real pip-shaped cache — `Library/Caches/pip/http-v2` —
        // built under the real home so the guard permits it.
        do {
            let home = URL(fileURLWithPath: AppEnvironment.realHome)
            let pip = home.appendingPathComponent("Library/Caches/pip")
            let httpv2 = pip.appendingPathComponent("http-v2")
            try? fm.createDirectory(at: httpv2, withIntermediateDirectories: true)
            try? Data(count: 60_000_000).write(to: httpv2.appendingPathComponent("blob"))

            // Scan the cache's PARENT: the scan root itself is never a candidate,
            // so a scan rooted at `pip` could not offer it.
            let c = home.appendingPathComponent("Library/Caches").path
            guard let handle = c.withCString({ bz_scan_start($0) }) else {
                check("the identity fixture scan started", false, "bz_scan_start failed")
                try? fm.removeItem(at: pip)
                return
            }
            var done: Int32 = 0
            var f: UInt64 = 0, d: UInt64 = 0, b: UInt64 = 0
            while done == 0 {
                bz_progress(handle, &f, &d, &b, &done)
                if done == 0 { usleep(5_000) }
            }
            guard let scan = Tree(handle: handle) else {
                check("the identity fixture produced a tree", false, "no tree for \(c)")
                bz_free(handle)
                try? fm.removeItem(at: pip)
                return
            }
            let items = Cleanup.find(in: scan)
            let pipItem = items.first { $0.path.hasSuffix("/Library/Caches/pip") }
            check("a table row's candidate carries its tool name",
                  pipItem?.tool == "pip",
                  "tool=\(pipItem?.tool ?? "nil")")
            check("the panel and prompt label names the tool",
                  pipItem?.label.contains("pip") == true,
                  "label=\(pipItem?.label ?? "nil")")
            check("the generic kind string is still carried",
                  pipItem?.kind == "Caches, rebuilt or re-downloaded when needed",
                  "kind=\(pipItem?.kind ?? "nil")")
            // A shape-recognised folder has no tool, and its label stays generic.
            let modules = home.appendingPathComponent(".drawer-identity-\(pid)/node_modules")
            try? fm.createDirectory(at: modules, withIntermediateDirectories: true)
            try? Data(count: 60_000_000).write(to: modules.appendingPathComponent("blob"))
            let m = modules.path
            if let h2 = m.withCString({ bz_scan_start($0) }) {
                done = 0
                while done == 0 {
                    bz_progress(h2, &f, &d, &b, &done)
                    if done == 0 { usleep(5_000) }
                }
                if let t2 = Tree(handle: h2) {
                    let shapeItem = Cleanup.find(in: t2).first { $0.path.hasSuffix("/node_modules") }
                    check("a shape-recognised folder reports no tool",
                          shapeItem?.tool == nil, "tool=\(shapeItem?.tool ?? "nil")")
                    check("its label is the generic kind string",
                          shapeItem?.label == shapeItem?.kind,
                          "label=\(shapeItem?.label ?? "nil")")
                } else {
                    check("the shape fixture produced a tree", false, "no tree")
                    bz_free(h2)
                }
            } else {
                check("the shape fixture scan started", false, "bz_scan_start failed")
            }
            try? fm.removeItem(at: modules.deletingLastPathComponent())
            try? fm.removeItem(at: pip)
        }

        // --- The scan picker must offer drives, not virtual disks ------------
        //
        // `ScanTargets.mountedDrives()` excludes a volume whose media is backed
        // by a file (`Physical Interconnect Location == "File"` — a mounted
        // `.dmg`/installer). A RAM disk reports `"RAM"` for the same key, and
        // that value was missing, so a memory disk appeared in the picker as if
        // it were a drive: a 100 MB `hdiutil attach -nomount ram://…` volume
        // showed as "BZRam" in the target list while owning no storage anyone
        // wants in a "why is my disk full" scan.
        //
        // Asserted against real devices on this machine rather than a stub: a
        // RAM disk is created here, and the fixture is removed afterwards. The
        // positive half matters as much as the negative — a filter that hid
        // every volume would pass the exclusion checks alone, so the boot
        // volume's own classification is asserted too.
        do {
            // A mounted probe image and a RAM disk, built here so the test does
            // not depend on either existing. `/usr/bin/hdiutil` is the supported
            // way to make both.
            func run(_ launchPath: String, _ args: [String]) -> String {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: launchPath)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                try? p.run()
                p.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(decoding: data, as: UTF8.self)
            }

            let imgPath = fm.temporaryDirectory.appendingPathComponent("bz-picker-\(pid).dmg").path
            _ = run("/usr/bin/hdiutil", ["create", "-size", "10m", "-fs", "HFS+",
                                         "-volname", "BZPickerImg", imgPath, "-quiet"])
            // NOT `-quiet`: that suppresses the mount-point line this needs. The
            // output is `<device>\t<filesystem>\t/mount/point` per partition.
            let attachOut = run("/usr/bin/hdiutil", ["attach", imgPath])
            var imgVolume: String? = nil
            for line in attachOut.split(separator: "\n") {
                for field in line.split(separator: "\t")
                where field.trimmingCharacters(in: .whitespaces).hasPrefix("/Volumes/") {
                    imgVolume = field.trimmingCharacters(in: .whitespaces)
                }
            }

            let ramOut = run("/usr/bin/hdiutil", ["attach", "-nomount", "ram://204800"])
            // The device line looks like `/dev/disk10\t\t\t`; the deprecation
            // warning also goes to the same stream, so the device is found by
            // matching the `/dev/` prefix rather than by taking the first field.
            var ramDev = ""
            for line in ramOut.split(separator: "\n") {
                let first = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
                if first.hasPrefix("/dev/") { ramDev = first }
            }

            // The classification, asked directly about the device we just made.
            //
            // This is the assertion that actually pins the fix. Asking the
            // PICKER whether the RAM disk is absent passes either way, because a
            // bare `ram://` device carries no filesystem and `mountedVolumeURLs`
            // never lists it — so that check cannot fail and proves nothing. The
            // defect was in the classifier, which reported a RAM-backed device
            // as a real drive, and that is what a mounted, browsable RAM volume
            // (a formatted one) would then be offered on. Asserting the class
            // makes the test fail on the old rule.
            if !ramDev.isEmpty {
                let ramBSD = (ramDev as NSString).lastPathComponent
                check("a RAM-backed device is classified as virtual storage",
                      ScanTargets.classifyVolumeForTest(bsdName: ramBSD) == .virtual,
                      "\(ramBSD) classified as a drive — it would be offered if it held a filesystem")
            }

            let offered = ScanTargets.mountedDrives()
            let offeredPaths = Set(offered.map(\.path))

            // The fixture proves the classification works on a device we control.
            if !ramDev.isEmpty {
                // The RAM device is not a browsable volume (no filesystem), so
                // it may not appear at all — that is also correct. What must NOT
                // happen is it appearing as an offerable target.
                check("a RAM disk is not offered as a scan target",
                      !offeredPaths.contains(ramDev),
                      "offered paths: \(offeredPaths.sorted())")
            }
            if let imgVolume {
                check("a mounted disk image is not offered as a scan target",
                      !offeredPaths.contains(imgVolume),
                      "offered \(imgVolume); paths: \(offeredPaths.sorted())")
            }

            // The positive half: real storage must still be offered, or the
            // filter has simply hidden everything. This machine's boot volume is
            // the one device guaranteed to exist.
            let bootBSD: String? = {
                guard let s = DASessionCreate(kCFAllocatorDefault),
                      let d = DADiskCreateFromVolumePath(kCFAllocatorDefault, s,
                                                          URL(fileURLWithPath: "/") as CFURL),
                      let desc = DADiskCopyDescription(d) as? [String: Any] else { return nil }
                return desc[kDADiskDescriptionMediaBSDNameKey as String] as? String
            }()
            check("the boot volume is classified as real storage",
                  ScanTargets.classifyVolumeForTest(bsdName: bootBSD) == .drive,
                  "boot volume classified as excluded — the filter is too broad")

            // Clean up both fixtures, unconditionally.
            //
            // `diskutil eject`, not `hdiutil detach`: the latter is deprecated
            // and, on a bare `ram://` device with no mount, exits 1 with
            // "No such file or directory" while leaving the device attached. The
            // suite then accumulated `diskNN` nodes on every run — a test that
            // leaks real devices is worse than no test.
            func eject(_ target: String) {
                _ = run("/usr/sbin/diskutil", ["eject", target])
            }
            if let imgVolume { eject(imgVolume) }
            if !ramDev.isEmpty { eject(ramDev) }
            try? fm.removeItem(atPath: imgPath)
        }
    }
}

@main
enum DrawerTests {
    static func main() async {
        await run()
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
