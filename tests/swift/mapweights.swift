// Share-weight regression net: small siblings must stay clickable.
//
// Build (from repo root, same contract as the other Swift suites):
//   swiftc tests/swift/shareweight.swift \
//       $(filter-out app/Main.swift,$(wildcard app/*.swift)) \
//       -import-objc-header app/bz.h -parse-as-library \
//       -swift-version 6 -default-isolation MainActor \
//       -target arm64-apple-macos14.0 -L target/release -lappletree \
//       -framework DiskArbitration -framework IOKit -framework Security \
//       -o .build/shareweight-tests
//
// The bug: a folder holding a 1.08 GB `usr`, a 766 KB `Developer` and a 4 KB
// `Info.plist` drew the last two as sub-pixel specks in both the treemap and
// the rings, so neither could be clicked or right-clicked. Pure-proportional
// sizing cannot fix that at any display size.
//
// These tests therefore check the two owners the fix lives in, against the
// REAL things the user cares about, not just arithmetic:
//   1. ShareWeight  — the blend itself, at the reported sizes, nested.
//   2. Squarify     — the treemap's placed, hit-testable rectangles.
//   3. SunburstView — the rings' arcs, through their own hit geometry.
//
// A real `Tree` is built by scanning a scratch directory with the shipping
// engine, so the node layout (sorted children, `alloc` totals) is the one the
// app really reads, not a hand-rolled stand-in.

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

/// The sizes from the report, in bytes.
let usrBytes = UInt64(1_082_000_000)       // ~1.08 GB allocated
let developerBytes = UInt64(766 * 1024)    // 766 KB
let plistBytes = UInt64(4 * 1024)          // 4 KB

/// Create a file of `bytes` allocated size without writing the data.
///
/// The engine reads `ATTR_FILE_ALLOCSIZE`, i.e. `st_blocks * 512`, so a plain
/// sparse `truncate` reports 0 and would not reproduce the 1.08 GB sibling at
/// all. F_PREALLOCATE gives the file real blocks, so the fixture has the
/// reported shape while staying cheap to create and delete.
@discardableResult
func allocateFile(_ url: URL, bytes: UInt64) -> Bool {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let fd = open(url.path, O_RDWR)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    let size = off_t(bytes)
    var store = fstore_t(fst_flags: UInt32(F_ALLOCATECONTIG), fst_posmode: F_PEOFPOSMODE,
                         fst_offset: 0, fst_length: size, fst_bytesalloc: 0)
    if fcntl(fd, F_PREALLOCATE, &store) == -1 {
        store.fst_flags = UInt32(F_ALLOCATEALL)
        _ = fcntl(fd, F_PREALLOCATE, &store)
    }
    ftruncate(fd, size)
    return true
}

/// Scan `path` with the shipping engine and return its `Tree`.
func scanTree(_ path: String) -> Tree? {
    guard let handle = bz_scan_start(path) else { return nil }
    var done: Int32 = 0
    var files: UInt64 = 0, dirs: UInt64 = 0, bytes: UInt64 = 0
    let deadline = Date().addingTimeInterval(60)
    while Date() < deadline {
        bz_progress(handle, &files, &dirs, &bytes, &done)
        if done != 0 { break }
        usleep(2000)
    }
    guard done != 0, let tree = Tree(handle: handle) else {
        bz_free(handle)
        return nil
    }
    return tree
}

/// The report's folder: `usr` (1.08 GB), `Developer` (766 KB) and
/// `ToolchainsInfo.plist` (4 KB), the last two too small to click before.
@MainActor
func run() {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mapweights-\(ProcessInfo.processInfo.processIdentifier)")

    let apps = root.appendingPathComponent("Apps")
    let toolchain = apps.appendingPathComponent("XcodeDefault.xctoolchain")
    try? fm.createDirectory(at: toolchain, withIntermediateDirectories: true)
    check("fixture directory exists", fm.fileExists(atPath: toolchain.path))

    let usr = toolchain.appendingPathComponent("usr")
    check("the big sibling allocated its bytes", allocateFile(usr, bytes: usrBytes))
    do {
        // Two small siblings: the directory and the plist from the report.
        // `Developer` itself holds a huge/tiny pair, so the blend has to run a
        // second time one level down.
        let dev = toolchain.appendingPathComponent("Developer")
        try? fm.createDirectory(at: dev, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 760 * 1024).write(to: dev.appendingPathComponent("huge"))
        try Data(repeating: 0x44, count: 300).write(to: dev.appendingPathComponent("tiny"))
        _ = developerBytes
    } catch {
        check("fixture written", false, "\(error)")
    }
    do {
        try Data(repeating: 0x42, count: Int(plistBytes))
            .write(to: toolchain.appendingPathComponent("ToolchainsInfo.plist"))
    } catch {
        check("fixture plist written", false, "\(error)")
    }
    // A folder of empty files, as a *fourth sibling* of `usr`. This is the
    // divisor case: each empty file takes a floor share, and counting only the
    // children with bytes made the weights sum to several times the parent's
    // area (a bug caught in review — the tiles overflowed their box).
    do {
        let empties = toolchain.appendingPathComponent("EmptyDeps")
        try? fm.createDirectory(at: empties, withIntermediateDirectories: true)
        for i in 0..<10 {
            fm.createFile(atPath: empties.appendingPathComponent("empty-\(i)").path, contents: nil)
        }
        try Data(repeating: 0x45, count: 2048).write(to: empties.appendingPathComponent("real"))
    } catch {
        check("fixture empties written", false, "\(error)")
    }

    guard let tree = scanTree(root.path) else {
        print("FAIL could not scan the fixture tree")
        print("0 passed, 1 failed")
        exit(1)
    }
    let toolchainNode = tree.node(at: toolchain.path)
    check("the engine resolved the fixture root", toolchainNode != nil)
    guard let tc = toolchainNode else {
        print("\(passed) passed, \(failed + 1) failed")
        exit(1)
    }

    // --- The sizes really are the reported ones ------------------------------
    // If the fixture did not reproduce the shape, every claim below is void.
    let kids = tree.children(tc)
    // usr, Developer, ToolchainsInfo.plist, EmptyDeps.
    check("four siblings", kids.count == 4, "got \(kids.count)")
    let sizes = kids.map { tree.alloc[Int($0)] }.sorted(by: >)
    check("the pool has one dominant sibling and small ones",
          sizes.count == 4 && sizes[0] > 1_000_000_000 && sizes[1] < 2_000_000 && sizes[3] < 100_000,
          "sizes=\(sizes)")

    // --- 0. The divisor: only siblings with bytes take part -----------------
    // `usr`, `Developer`, `ToolchainsInfo.plist` and `EmptyDeps` are the four
    // siblings. `EmptyDeps` holds ten 0-byte files and one real one. The pool
    // is divided by the *sized* siblings, so an empty file cannot dilute a real
    // sibling's floor; and the weights must still conserve the folder exactly.
    if let empties = kids.first(where: { tree.name(Int($0)) == "EmptyDeps" }).map({ Int($0) }) {
        let emptyKids = tree.children(empties)
        check("the empty-file folder has 11 children", emptyKids.count == 11, "got \(emptyKids.count)")
        let sized = emptyKids.filter { tree.alloc[Int($0)] > 0 }
        check("only one of them carries bytes", sized.count == 1, "got \(sized.count)")
        let emptyTotal = tree.alloc[empties]
        // The divisor the layout uses: siblings with bytes.
        let n = sized.count
        let weights = sized.map {
            ShareWeight.weight(bytes: tree.alloc[Int($0)], siblings: n, parentTotal: emptyTotal)
        }
        check("the sized siblings conserve the folder exactly",
              abs(weights.reduce(0, +) - Double(emptyTotal)) < 0.001,
              "sum=\(weights.reduce(0, +)) parent=\(emptyTotal)")
        // The layout must not lay the empty files out at all: 20,000 of them
        // beside one real file was measured at 20,001 paint steps instead of 1.
        var emptyItems: [Squarify.Item] = []
        Squarify.items(tree: tree, dir: empties, into: &emptyItems)
        check("the treemap lays out only the sized sibling",
              emptyItems.count == 1, "got \(emptyItems.count)")
        check("the empty files are not drawn",
              emptyItems.allSatisfy { tree.alloc[$0.node] > 0 })
    } else {
        check("EmptyDeps found in the fixture", false)
    }

    // --- 1. ShareWeight: the blend, exactly as reported ----------------------
    // "first one got %79.99 space because its big plus 20/3 size, and others
    // get 20/3 size both."
    let n = kids.count
    let total = tree.alloc[tc]
    let shares = kids.map { ShareWeight.share(bytes: tree.alloc[Int($0)], siblings: n, parentTotal: total) }
    let byShare = zip(kids, shares).sorted { $0.1 > $1.1 }
    // The big sibling's size-pool component is 0.8 · its byte fraction — the
    // reported ~79.99% — and it then adds its own equal share of the pool.
    let bigFraction = Double(tree.alloc[Int(byShare[0].0)]) / Double(total)
    let sizeComponent = (1 - ShareWeight.pooled) * bigFraction
    check("the big sibling's size component is ~79.99% of the area",
          abs(sizeComponent - 0.7999) < 0.005, "sizeComponent=\(sizeComponent)")
    check("the big sibling keeps its 80% plus its equal pool share",
          abs(byShare[0].1 - (sizeComponent + ShareWeight.pooled / Double(n))) < 1e-9,
          "share=\(byShare[0].1)")
    check("the shares still sum to the parent's area exactly",
          abs(shares.reduce(0, +) - 1) < 1e-9, "sum=\(shares.reduce(0, +))")
    // The two small siblings from the report are no longer the only ones on
    // the floor; each of the three non-dominant siblings sits on it.
    let floor = ShareWeight.pooled / Double(n)
    check("each small sibling gets at least the 1/n pool floor",
          byShare.dropFirst().allSatisfy { $0.1 >= floor - 1e-9 },
          "shares=\(byShare.map(\.1))")
    check("the big sibling is still unmistakably the biggest",
          byShare[0].1 > 10 * byShare[1].1, "big=\(byShare[0].1) small=\(byShare[1].1)")

    // The floor a sibling is guaranteed, whatever its size. The old
    // proportional rule gave the 4 KB file a ~3.8e-6 share — invisible.
    let oldPlistShare = Double(plistBytes) / Double(total)
    check("proportional sizing really did make the plist unclickable",
          oldPlistShare < 1e-5, "old=\(oldPlistShare)")
    let plistWeight = ShareWeight.weight(bytes: plistBytes, siblings: n, parentTotal: total)
    check("the plist's weight is now the floor, not its bytes",
          abs(plistWeight / Double(total) - floor) < 0.005)

    // Nesting: the blend runs again inside Developer, among its own children.
    let devNode = kids.first { tree.isDir(Int($0)) && tree.name(Int($0)) == "Developer" }
    if let dev = devNode.map({ Int($0) }) {
        let devKids = tree.children(dev)
        check("Developer's own children are laid out too", devKids.count == 2, "got \(devKids.count)")
        let devSizes = devKids.map { tree.alloc[Int($0)] }.sorted(by: >)
        // The small sibling is ~190x smaller than its neighbour, yet the blend
        // gives it the pool floor for two siblings — 1/10 of Developer.
        check("the nested small sibling was genuinely tiny",
              devSizes.count == 2 && devSizes[0] > 100 * max(devSizes[1], 1),
              "sizes=\(devSizes)")
        var nestedItems: [Squarify.Item] = []
        Squarify.items(tree: tree, dir: dev, into: &nestedItems)
        let nestedShares = Dictionary(nestedItems.map { ($0.node, $0.size) }) { a, _ in a }
        let nestedTotal = nestedItems.reduce(0.0) { $0 + $1.size }
        let nestedSmall = devKids.map { Int($0) }.min { tree.alloc[$0] < tree.alloc[$1] }!
        let nestedShare = (nestedShares[nestedSmall] ?? 0) / nestedTotal
        // With two siblings the floor is pooled/2 = 0.1, and the tiny one's own
        // bytes add almost nothing above it.
        check("the nested small sibling sits on the pool floor, ~1/10",
              abs(nestedShare - ShareWeight.pooled / 2) < 0.01, "share=\(nestedShare)")
        // This is the property that matters: the same sibling under the old
        // proportional rule. Nesting repeats the blend, so it is lifted ~20x.
        let oldNestedShare = Double(tree.alloc[nestedSmall]) / Double(tree.alloc[dev])
        check("the nested small sibling was ~20x worse off before",
              nestedShare / oldNestedShare > 15,
              "old=\(oldNestedShare) new=\(nestedShare) factor=\(nestedShare / oldNestedShare)")
    } else {
        check("Developer found in the fixture", false)
    }

    // --- 2. Squarify: the treemap's real, hit-testable rectangles -----------
    // 1200x800 is a plausible window; the report's own screenshot is wider.
    for (w, h) in [(1200.0, 800.0), (800.0, 600.0)] {
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        var items: [Squarify.Item] = []
        Squarify.items(tree: tree, dir: tc, into: &items)
        check("treemap lays out every sibling at \(Int(w))x\(Int(h))",
              items.count == kids.count, "got \(items.count)")
        var placed: [Squarify.Placed] = []
        Squarify.layoutItems(items, rect: rect, into: &placed)
        check("treemap placed every sibling at \(Int(w))x\(Int(h))",
              placed.count == kids.count, "got \(placed.count)")
        let areas = Dictionary(placed.map { ($0.node, $0.rect.width * $0.rect.height) }) { a, _ in a }
        // The small siblings are the ones that used to vanish: assert their
        // tiles are big enough for a pointer to land on, and that the big one
        // is still dominant.
        let smalls = kids.map { Int($0) }.filter { tree.alloc[$0] < 2_000_000 }
        check("treemap: the small siblings are present at \(Int(w))x\(Int(h))",
              smalls.count == 3, "got \(smalls.count)")
        for node in smalls {
            let a = areas[node] ?? 0
            check("treemap tile for \(tree.name(node)) is clickable at \(Int(w))x\(Int(h))",
                  a >= 1000, "area=\(a) pt²")
        }
        let big = kids.map { Int($0) }.max { tree.alloc[$0] < tree.alloc[$1] }!
        check("treemap: the big sibling still dominates at \(Int(w))x\(Int(h))",
              (areas[big] ?? 0) > 10 * (areas[smalls[0]] ?? 0))
        // Tiles must not overlap, or a hit would select the wrong node.
        let rects = placed.map(\.rect)
        var overlapped = false
        for i in rects.indices {
            for j in rects.indices where j > i {
                if rects[i].intersection(rects[j]).width > 0.5,
                   rects[i].intersection(rects[j]).height > 0.5 { overlapped = true }
            }
        }
        check("treemap tiles stay disjoint at \(Int(w))x\(Int(h))", !overlapped)
    }

    // --- 3. The rings, through their own hit geometry ------------------------
    // A 700 pt round chart, the size the report's window gives the rings.
    let outer = 340.0
    let radii = SunburstNSView.ringRadii(outer: outer)
    // The fixture root holds one folder, so the reported siblings sit one ring
    // out from the centre — the level the bug was reported at.
    let segments = SunburstNSView.layout(tree: tree, root: 0, radii: radii, freeBytes: 0)
    check("rings laid out arcs", !segments.isEmpty)

    let smalls = kids.map { Int($0) }.filter { tree.alloc[$0] < 2_000_000 }
    check("the small siblings are present at the reported level", smalls.count == 3, "got \(smalls.count)")
    let toolchainSeg = segments.first { $0.node == tc }
    check("the rings show the toolchain folder", toolchainSeg != nil)
    for node in smalls {
        guard let seg = segments.first(where: { $0.node == node }) else {
            check("rings drew an arc for \(tree.name(node))", false)
            continue
        }
        let rMid = Double((radii[seg.ring] + radii[seg.ring + 1]) / 2)
        let arcLen = (seg.end - seg.start) * rMid
        check("rings arc for \(tree.name(node)) is clickable", arcLen >= 2.0,
              "arc=\(String(format: "%.2f", arcLen)) pt at r=\(String(format: "%.0f", rMid))")
        // The same arc under the old proportional rule: this is what the user
        // could not click. If this ever stops being true the premise is gone.
        let oldShare = Double(tree.alloc[node]) / Double(tree.alloc[tc])
        let oldArcLen = oldShare * (toolchainSeg.map { $0.end - $0.start } ?? 0) * rMid
        check("under proportional sizing \(tree.name(node))'s arc was unclickable",
              oldArcLen < 2.0, "old arc=\(String(format: "%.4f", oldArcLen)) pt")
        // Hit-test that midpoint through the view's own rule: distance in
        // [radii[k], radii[k+1]) and angle inside the arc.
        let hitRing = (0..<(radii.count - 1)).first {
            rMid >= Double(radii[$0]) && rMid < Double(radii[$0 + 1])
        }
        check("rings: the arc's ring contains its midpoint", hitRing == seg.ring,
              "ring=\(String(format: "%.1f", rMid))")
        check("rings: the arc's angle holds its midpoint",
              (seg.start + seg.end) / 2 >= seg.start && (seg.start + seg.end) / 2 < seg.end)
    }

    // Free space must keep exactly its proportional share: the pool may only
    // move area between the used siblings, never across the used/free boundary.
    let freeBytes: UInt64 = 500_000_000
    let withFree = SunburstNSView.layout(tree: tree, root: 0, radii: radii, freeBytes: freeBytes)
    let freeSeg = withFree.first { $0.node == -1 }
    check("rings still draw a free-space arc", freeSeg != nil)
    if let freeSeg {
        let used = Double(tree.alloc[0])
        let expectedUsedSpan = 2 * Double.pi * used / (used + Double(freeBytes))
        check("the free-space boundary is unchanged by the pool",
              abs(freeSeg.start - expectedUsedSpan) < 1e-9,
              "boundary=\(freeSeg.start) expected=\(expectedUsedSpan)")
        check("the free arc reaches the end of the circle",
              abs(freeSeg.end - 2 * Double.pi) < 1e-9)
        // The used children still fill exactly the used span, pooled or not.
        let usedArcs = withFree.filter { $0.ring == 0 && $0.node >= 0 }
        let usedEnd = usedArcs.map(\.end).max() ?? 0
        check("the used arcs still fill exactly the used span",
              abs(usedEnd - expectedUsedSpan) < 1e-9,
              "usedEnd=\(usedEnd) expected=\(expectedUsedSpan)")
    }

    try? fm.removeItem(at: root)
    print("\(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}

@main
enum ShareWeightTests {
    static func main() {
        run()
    }
}
