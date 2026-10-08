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
    // The big sibling's size-pool component is `1 - pooled` times its byte
    // fraction, and it then adds its own equal share of the pool.
    let p = ShareWeight.pooled(siblings: n)
    let bigFraction = Double(tree.alloc[Int(byShare[0].0)]) / Double(total)
    let sizeComponent = (1 - p) * bigFraction
    check("the big sibling keeps its size share plus its equal pool share",
          abs(byShare[0].1 - (sizeComponent + p / Double(n))) < 1e-9,
          "share=\(byShare[0].1)")
    check("the shares still sum to the parent's area exactly",
          abs(shares.reduce(0, +) - 1) < 1e-9, "sum=\(shares.reduce(0, +))")
    // Every non-dominant sibling sits on the pool floor.
    let floor = ShareWeight.floor(siblings: n)
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

    // --- 1b. The count curve, and the memo that caches it -------------------
    // The curve grows 0.10 -> 0.25 with the sibling count, eased t³.
    check("the pool is pooledMin at the smallest counts",
          ShareWeight.pooled(siblings: 0) == ShareWeight.pooledMin
          && ShareWeight.pooled(siblings: 1) == ShareWeight.pooledMin
          && ShareWeight.pooled(siblings: ShareWeight.pooledMinCount) == ShareWeight.pooledMin)
    check("the pool reaches pooledMax at the top of the range",
          ShareWeight.pooled(siblings: ShareWeight.pooledMaxCount) == ShareWeight.pooledMax)
    check("the pool holds at pooledMax past the range",
          ShareWeight.pooled(siblings: 500) == ShareWeight.pooledMax
          && ShareWeight.pooled(siblings: 100_000) == ShareWeight.pooledMax)
    check("the pool never leaves its bounds over 0...400",
          (0...400).allSatisfy {
              let v = ShareWeight.pooled(siblings: $0)
              return v >= ShareWeight.pooledMin - 1e-15 && v <= ShareWeight.pooledMax + 1e-15
          })
    check("the pool is non-decreasing",
          (0..<400).allSatisfy { ShareWeight.pooled(siblings: $0) <= ShareWeight.pooled(siblings: $0 + 1) })
    // easeInCubic: at the midpoint of the range t³ = 0.125, so only an eighth
    // of the range is spent — the growth is late. Asserted against the curve's
    // own definition: `pooled` is quantised, so it intentionally differs from
    // the raw cubic by up to half a quantum.
    let mid = (ShareWeight.pooledMinCount + ShareWeight.pooledMaxCount) / 2
    let tMid = Double(mid - ShareWeight.pooledMinCount)
        / Double(ShareWeight.pooledMaxCount - ShareWeight.pooledMinCount)
    check("the curve is ease-in-cubic, not linear",
          abs(ShareWeight.pooledCubic(siblings: mid)
              - (ShareWeight.pooledMin + (ShareWeight.pooledMax - ShareWeight.pooledMin) * tMid * tMid * tMid)) < 1e-15,
          "cubic(\(mid))=\(ShareWeight.pooledCubic(siblings: mid))")
    check("the quantised lookup tracks the cubic within half a quantum",
          (0...ShareWeight.pooledMaxCount).allSatisfy {
              abs(ShareWeight.pooled(siblings: $0) - ShareWeight.pooledCubic(siblings: $0))
                  <= ShareWeight.pooledQuantum / 2 + 1e-12
          })
    check("a busy folder gives up more than a small one",
          ShareWeight.pooled(siblings: 30) > ShareWeight.pooled(siblings: 3))

    // THE MEMO EQUALS THE QUANTISED CURVE, for every input the table can
    // serve. This is what makes the cache safe: `pooled` is a lookup,
    // `pooledCubic` is the shape's definition, and `quantize` is the precision,
    // so this asserts the table equals `quantize(pooledCubic(…))` bit for bit
    // over the whole domain and can never drift from the curve it stands for.
    var memoMismatch: Int? = nil
    for n in 0...ShareWeight.pooledMaxCount {
        if ShareWeight.pooled(siblings: n) != ShareWeight.quantize(ShareWeight.pooledCubic(siblings: n)) {
            memoMismatch = n
        }
    }
    check("the memo table equals quantize(cubic) at every n in 0...\(ShareWeight.pooledMaxCount)",
          memoMismatch == nil, "first mismatch at n=\(memoMismatch.map(String.init) ?? "-")")
    check("a table read is exactly quantize(cubic), bit for bit, not merely close",
          (0...ShareWeight.pooledMaxCount).allSatisfy {
              ShareWeight.pooled(siblings: $0).bitPattern
                  == ShareWeight.quantize(ShareWeight.pooledCubic(siblings: $0)).bitPattern
          })

    // PRECISION: every entry is a clean multiple of the table's quantum, so the
    // values are the legible 3-decimal ones (0.100, 0.101, … 0.250). Without
    // this a quantisation that silently stopped rounding would still pass the
    // equality check above only if quantize stopped working too.
    check("every table entry is a whole number of \(ShareWeight.pooledQuantum)s",
          (0...ShareWeight.pooledMaxCount).allSatisfy {
              let scaled = ShareWeight.pooled(siblings: $0) * 1000
              return abs(scaled - scaled.rounded()) < 1e-9
          })
    check("no entry carries more than \(ShareWeight.pooledDecimals) decimals",
          (0...ShareWeight.pooledMaxCount).allSatisfy {
              abs(ShareWeight.pooled(siblings: $0) * 1000 - (ShareWeight.pooled(siblings: $0) * 1000).rounded()) < 1e-9
          })
    check("quantize rounds to nearest, not toward zero",
          ShareWeight.quantize(0.1294) == 0.129 && ShareWeight.quantize(0.1296) == 0.13)
    // Quantising a non-decreasing curve leaves it non-decreasing.
    check("quantising preserved monotonicity",
          (0..<ShareWeight.pooledMaxCount).allSatisfy {
              ShareWeight.pooled(siblings: $0) <= ShareWeight.pooled(siblings: $0 + 1)
          })
    // The ends are exact: the clamp returns pooledMax, which is already a clean
    // 3-decimal value, so the boundary and the table cannot disagree.
    check("pooledMax is exactly representable at this precision",
          ShareWeight.quantize(ShareWeight.pooledMax) == ShareWeight.pooledMax)
    check("the clamped path agrees with the table",
          ShareWeight.pooled(siblings: ShareWeight.pooledMaxCount) == ShareWeight.pooledMax
          && ShareWeight.pooled(siblings: 999) == ShareWeight.pooledMax)

    // DETERMINISM: the same input gives the same answer, every call, and it is
    // the value the curve computes rather than something inherited from a
    // neighbour. Repeated and out of order, to catch a lookup that reads the
    // wrong slot.
    let order = [37, 3, 50, 2, 19, 3, 37, 11, 50, 2, 26, 8, 44, 5]
    let repeatable = order.map { ShareWeight.pooled(siblings: $0) }
    let repeatableAgain = order.map { ShareWeight.pooled(siblings: $0) }
    check("pooled is deterministic across repeated, out-of-order calls",
          repeatable == repeatableAgain)
    check("each repeated lookup still matches its quantised curve value",
          zip(order, repeatable).allSatisfy {
              ShareWeight.quantize(ShareWeight.pooledCubic(siblings: $0.0)) == $0.1
          })
    // A few exact values, so a future edit to the table cannot pass silently.
    // These are the 3-decimal values the request named, listed exhaustively.
    let expected: [(Int, Double)] = [
        (2, 0.100), (10, 0.101), (13, 0.102), (20, 0.108),
        (30, 0.130), (40, 0.174), (44, 0.200), (50, 0.250),
    ]
    for (n, want) in expected {
        check("pooled(\(n)) is exactly \(String(format: "%.3f", want))",
              ShareWeight.pooled(siblings: n).bitPattern == want.bitPattern,
              "got \(String(format: "%.17g", ShareWeight.pooled(siblings: n)))")
    }

    // The floor: still falls with n (n divides it), but the curve slows the
    // fall rather than collapsing to 0.10/n everywhere.
    check("the floor is highest for the smallest folders",
          ShareWeight.floor(siblings: 2) > ShareWeight.floor(siblings: 10))
    check("the floor at 50 is above what a flat 0.10 would give",
          ShareWeight.floor(siblings: 50) > 0.10 / 50)
    check("the floor bottoms out around n=35 and rises after",
          ShareWeight.floor(siblings: 35) < ShareWeight.floor(siblings: 50)
          && ShareWeight.floor(siblings: 35) < ShareWeight.floor(siblings: 20))

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
        // With two siblings the pool is pooledMin and the floor is its half,
        // and the tiny one's own bytes add almost nothing above it.
        check("the nested small sibling sits on the two-sibling pool floor",
              abs(nestedShare - ShareWeight.floor(siblings: 2)) < 0.01,
              "share=\(nestedShare) floor=\(ShareWeight.floor(siblings: 2))")
        // This is the property that matters: the same sibling under the old
        // proportional rule. Nesting repeats the blend, so it is lifted an
        // order of magnitude. The factor tracks `floor / byteFraction`; with
        // two siblings the curve sits at pooledMin, so it is ~10x rather than
        // the ~20x a flat 0.20 pool gave.
        let oldNestedShare = Double(tree.alloc[nestedSmall]) / Double(tree.alloc[dev])
        check("the nested small sibling was ~10x worse off before",
              nestedShare / oldNestedShare > 8,
              "old=\(oldNestedShare) new=\(nestedShare) factor=\(nestedShare / oldNestedShare)")
    } else {
        check("Developer found in the fixture", false)
    }

    // --- 2. Squarify: the treemap's real rectangles --------------------------
    // The weighting reaches the layout: every sized sibling is laid out, the
    // weights conserve the folder, and the tiles do not overlap (an overlap
    // would let a hit pick the wrong node).
    for (w, h) in [(1200.0, 800.0), (800.0, 600.0)] {
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        var items: [Squarify.Item] = []
        Squarify.items(tree: tree, dir: tc, into: &items)
        check("treemap lays out every sized sibling at \(Int(w))x\(Int(h))",
              items.count == kids.count, "got \(items.count)")
        // The weights handed to the layout are the blend, and they conserve
        // the folder's own total.
        let weightSum = items.reduce(0.0) { $0 + $1.size }
        check("treemap weights sum to the folder's total at \(Int(w))x\(Int(h))",
              abs(weightSum - Double(total)) < 1.0,
              "sum=\(weightSum) total=\(total)")
        // Largest-first is what `layoutItems`' early stop depends on.
        check("treemap items stay sorted largest-first at \(Int(w))x\(Int(h))",
              zip(items, items.dropFirst()).allSatisfy { $0.size >= $1.size })
        var placed: [Squarify.Placed] = []
        Squarify.layoutItems(items, rect: rect, into: &placed)
        check("treemap placed every sized sibling at \(Int(w))x\(Int(h))",
              placed.count == kids.count, "got \(placed.count)")
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

    // --- 3. The rings: spans follow the blend and tile the circle ------------
    let outer = 340.0
    let radii = SunburstNSView.ringRadii(outer: outer)
    let segments = SunburstNSView.layout(tree: tree, root: 0, radii: radii, freeBytes: 0)
    check("rings laid out arcs", !segments.isEmpty)
    // Every arc carries its true bytes, so the tooltip and centre label stay
    // truthful even though the drawn span is blended.
    check("every ring segment keeps its real byte count",
          segments.filter { $0.node >= 0 }.allSatisfy { $0.bytes == tree.alloc[$0.node] })
    // The rings of one folder must tile their ring without gaps or overlap.
    let ring0 = segments.filter { $0.ring == 0 }.sorted { $0.start < $1.start }
    check("the outer ring's arcs are contiguous",
          zip(ring0, ring0.dropFirst()).allSatisfy { abs($1.start - $0.end) < 1e-12 },
          "gaps in ring 0")
    check("the ring's arcs are all non-empty", ring0.allSatisfy { $0.end > $0.start })

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

    // --- UI-2: the rings must not draw 0-byte children ----------------------
    //
    // The divisor counted only siblings carrying bytes, but the loop drew every
    // child and `ShareWeight.share` gives any sibling a positive pool floor — so
    // a 0-byte child got a real arc. Ring 0 then overran the whole circle
    // (measured: 8.168 rad against 6.283) and wrapped over arc 0, so the picture
    // disagreed with what hover and click resolve.
    //
    // A directory with one real child and several empty ones is the smallest
    // fixture that exposes it, and it is an ordinary shape: empty files and
    // folders are everywhere on a whole-disk scan.
    do {
        let zeroRoot = fm.temporaryDirectory.appendingPathComponent("bz-rings-zero-\(UUID().uuidString)")
        try? fm.createDirectory(at: zeroRoot, withIntermediateDirectories: true)
        // TWO real children, so the pooled (`siblings > 1`) path runs — that is
        // the path that gave a 0-byte sibling its floor. With a single real child
        // the strict-bytes branch gives an empty sibling a zero span, and the
        // defect cannot appear at all.
        for name in ["big-a", "big-b"] {
            let big = zeroRoot.appendingPathComponent(name)
            try? fm.createDirectory(at: big, withIntermediateDirectories: true)
            try? Data(count: 60_000_000).write(to: big.appendingPathComponent("blob"))
        }
        // Several empty siblings, each with bytes == 0.
        for i in 0..<6 {
            let empty = zeroRoot.appendingPathComponent("empty-\(i)")
            try? fm.createDirectory(at: empty, withIntermediateDirectories: true)
            try? Data().write(to: empty.appendingPathComponent("nothing"))
        }
        let handle = zeroRoot.path.withCString { bz_scan_start($0) }
        if let handle {
            var done: Int32 = 0
            var f: UInt64 = 0, d: UInt64 = 0, b: UInt64 = 0
            while done == 0 {
                bz_progress(handle, &f, &d, &b, &done)
                if done == 0 { usleep(5_000) }
            }
            if let zeroTree = Tree(handle: handle) {
                let radii = SunburstNSView.ringRadii(outer: 340)
                let segs = SunburstNSView.layout(tree: zeroTree, root: 0, radii: radii, freeBytes: 0)
                let ring0: [SBSegment] = segs.filter { $0.ring == 0 && $0.node >= 0 }
                check("ring 0 draws no 0-byte arc",
                      !ring0.contains(where: { $0.bytes == 0 }),
                      "empty arcs: \(ring0.filter { $0.bytes == 0 }.map(\.node))")
                let end = ring0.map(\.end).max() ?? 0
                check("ring 0 stays inside the full circle",
                      end <= 2 * Double.pi + 1e-9,
                      "end=\(end) exceeds \(2 * Double.pi)")
                let sorted = ring0.sorted { $0.start < $1.start }
                let overlapping = zip(sorted, sorted.dropFirst()).contains { $0.end > $1.start + 1e-9 }
                check("ring 0's arcs do not overlap", !overlapping)
            } else {
                check("the rings fixture produced a tree", false, "no tree for \(zeroRoot.path)")
                bz_free(handle)
            }
        } else {
            check("the rings fixture scan started", false, "bz_scan_start failed")
        }
        try? fm.removeItem(at: zeroRoot)
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
