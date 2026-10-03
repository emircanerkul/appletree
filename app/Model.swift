import AppKit
import SwiftUI
import Foundation
import Observation
// Volume classification for the scan targets: DiskArbitration names the
// device, IOKit storage reports what backs it.
import DiskArbitration
import IOKit
import IOKit.storage

/// Zero-copy view over the Rust engine's flat tree arrays.
/// Read-only after init, so sharing it across threads is safe.
nonisolated final class Tree: @unchecked Sendable {
    private let handle: OpaquePointer
    let count: Int
    let parents: UnsafePointer<UInt32>
    let alloc: UnsafePointer<UInt64>
    let logical: UnsafePointer<UInt64>
    let nFiles: UnsafePointer<UInt32>
    let flags: UnsafePointer<UInt8>
    let childOff: UnsafePointer<UInt32>
    let childArr: UnsafePointer<UInt32>
    let nameOff: UnsafePointer<UInt32>
    let nameBlob: UnsafePointer<UInt8>
    let cleanupCount: Int
    let cleanupNodes: UnsafePointer<UInt32>
    let errors: UInt64

    init?(handle: OpaquePointer) {
        let n = bz_take_tree(handle)
        guard n > 0,
              let parents = bz_parents(handle),
              let alloc = bz_alloc(handle),
              let logical = bz_logical(handle),
              let nFiles = bz_nfiles(handle),
              let flags = bz_flags(handle),
              let childOff = bz_child_off(handle),
              let childArr = bz_children(handle),
              let nameOff = bz_name_off(handle),
              let nameBlob = bz_name_blob(handle),
              let cleanupNodes = bz_cleanup_nodes(handle)
        else { return nil }
        self.handle = handle
        self.count = Int(n)
        self.parents = parents
        self.alloc = alloc
        self.logical = logical
        self.nFiles = nFiles
        self.flags = flags
        self.childOff = childOff
        self.childArr = childArr
        self.nameOff = nameOff
        self.nameBlob = nameBlob
        self.cleanupCount = Int(bz_cleanup_count(handle))
        self.cleanupNodes = cleanupNodes
        self.errors = bz_errors(handle)
    }

    deinit { bz_free(handle) }

    func isDir(_ i: Int) -> Bool { flags[i] & 1 != 0 }

    func cleanupDescription(_ index: Int) -> String {
        guard let label = bz_cleanup_description(handle, UInt64(index)) else { return "" }
        return String(cString: label)
    }

    /// The node at an absolute path, if the scan covered it. NSString
    /// normalization and the "/System/Volumes/Data" root-refix happen here;
    /// the engine resolves the already-refixed path against the name blob.
    nonisolated func node(at path: String) -> Int? {
        let root = self.path(0)
        var p = (path as NSString).standardizingPath
        // A whole-disk scan is rooted at the Data volume; /Users/… lives there.
        if root == "/System/Volumes/Data", !p.hasPrefix(root + "/") { p = root + p }
        let found = bz_node_at_path(handle, p)
        return found == UInt64.max ? nil : Int(found)
    }

    func name(_ i: Int) -> String {
        let start = Int(nameOff[i])
        let end = Int(nameOff[i + 1])
        let buf = UnsafeBufferPointer(start: nameBlob + start, count: end - start)
        return String(decoding: buf, as: UTF8.self)
    }

    func children(_ i: Int) -> UnsafeBufferPointer<UInt32> {
        let start = Int(childOff[i])
        let end = Int(childOff[i + 1])
        return UnsafeBufferPointer(start: childArr + start, count: end - start)
    }

    /// Human-facing path: the Data-volume firmlink prefix reads as "/".
    func displayPath(_ i: Int) -> String {
        let p = path(i)
        let prefix = "/System/Volumes/Data"
        if p.hasPrefix(prefix) {
            let rest = String(p.dropFirst(prefix.count))
            return rest.isEmpty ? "/" : rest
        }
        return p
    }

    /// Full path: root's name is the scanned path itself.
    func path(_ i: Int) -> String {
        var parts: [String] = []
        var cur = i
        while cur != 0 {
            parts.append(name(cur))
            cur = Int(parents[cur])
            if cur == Int(UInt32.max) { break }
        }
        var p = name(0)
        if p.hasSuffix("/") { p.removeLast() }
        for part in parts.reversed() { p += "/" + part }
        return p
    }

    /// Chain of ancestors from root to node (inclusive), for breadcrumbs.
    func ancestry(_ i: Int) -> [Int] {
        var chain = [i]
        var cur = i
        while cur != 0 && cur != Int(UInt32.max) {
            cur = Int(parents[cur])
            chain.append(cur)
        }
        return chain.reversed()
    }

    /// What a map draws for `node`: itself, or when it has no shape of its
    /// own (merged into an "A ▸ B" box, too deep for the rings) the nearest
    /// drawn folder that is mostly it. Nil when only a much larger folder is.
    func drawn(_ node: Int, isDrawn: (Int) -> Bool) -> Int? {
        var cur = node
        while !isDrawn(cur) {
            let parent = parents[cur]
            guard parent != UInt32.max, alloc[Int(parent)] <= 2 * alloc[node] else { return nil }
            cur = Int(parent)
        }
        return cur
    }
}

enum FDA {
    /// FDA-protected paths deny silently (no dialog), so probing is safe.
    static func isActive() -> Bool {
        let home = NSHomeDirectory()
        for p in ["\(home)/Library/Messages", "\(home)/Library/Mail", "\(home)/Library/Safari"] {
            if (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil {
                return true
            }
        }
        return false
    }

    @MainActor
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }
}

/// How the scan is drawn: WizTree-style boxes or DaisyDisk-style rings.
enum MapStyle: String {
    case treemap, rings
}

/// A place a scan can start: what the pickers list, and the path
/// `startScan(path:)` consumes.
nonisolated struct ScanTarget: Identifiable, Hashable {
    let title: String
    let path: String
    var id: String { path }
}

/// The scan targets every picker offers, named in one place so the toolbar
/// menu and the idle overlay cannot drift apart.
nonisolated enum ScanTargets {
    /// The boot volume group's user-data volume, shown to users as the disk.
    static let macintoshHD = ScanTarget(title: String(localized: "Macintosh HD"),
                                       path: "/System/Volumes/Data")
    static let home = ScanTarget(title: String(localized: "Home"),
                                 path: NSHomeDirectory())
    /// Installed applications, usually the biggest thing in a "why is my disk
    /// full" scan. `/Applications` is a firmlink into the Data volume, which
    /// the engine follows like any directory.
    static let applications = ScanTarget(title: String(localized: "Applications"),
                                         path: "/Applications")

    /// The drives worth scanning: real storage devices mounted under /Volumes,
    /// external or internal (a second internal partition counts).
    ///
    /// Read fresh on each call, so a drive plugged in while the app is open
    /// shows up in both pickers. Excluded, by device properties rather than by
    /// name or path: the boot volume group (that is `macintoshHD`), network
    /// volumes (not local disks, and a scan of one crawls), and mounted disk
    /// images — the installers and `.dmg`s whose volumes used to appear here.
    /// "SponsorBar Installer" was one; no list of such names would stay right.
    static func mountedDrives() -> [ScanTarget] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey,
                                      .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url -> ScanTarget? in
            // The boot volume group is offered as `macintoshHD`; it must not be
            // listed twice. Matched on the canonical mount path of the boot
            // volume and of its data volume — the root device is the one case
            // no property distinguishes, since it is an ordinary internal disk.
            let path = url.path
            guard path != "/", path != macintoshHD.path else { return nil }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsLocal == true,
                  values.volumeIsBrowsable != false else { return nil }
            // A disk image is a device whose media is backed by a file; IOKit
            // records that as the physical interconnect location. This is what
            // separates a mounted installer from a real drive, with no name or
            // extension matching anywhere.
            guard !isDiskImage(bsdName: bsdName(ofVolumeAt: path)) else { return nil }
            let name = values.volumeName ?? url.lastPathComponent
            guard !name.isEmpty else { return nil }
            return ScanTarget(title: name, path: path)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The BSD device name ("disk4s1") of the volume mounted at `path`, which
    /// IOKit is then queried by.
    private static func bsdName(ofVolumeAt path: String) -> String? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session,
                                                    URL(fileURLWithPath: path) as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
        return description[kDADiskDescriptionMediaBSDNameKey as String] as? String
    }

    /// True when the device behind `bsdName` is backed by a file — a mounted
    /// disk image, not a drive. `Physical Interconnect Location` is "File" for
    /// those and "Internal"/"External" for storage hardware, as the IOKit
    /// storage protocol characteristics define it.
    ///
    /// Searched upwards through the IOService plane: the property sits on the
    /// storage device above the volume's media, not on the media itself.
    /// A missing property reads as "not an image" — the volume keeps its
    /// place in the list, so an unexpected device is never silently hidden.
    private static func isDiskImage(bsdName: String?) -> Bool {
        guard let bsdName, let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return false }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let location = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane,
            kIOPropertyPhysicalInterconnectLocationKey as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? String
        return location == kIOPropertyInterconnectFileKey
    }
}

@Observable
@MainActor
final class ScanModel {
    var files: UInt64 = 0
    var dirs: UInt64 = 0
    var bytes: UInt64 = 0
    var scanning = false
    var elapsed: Double = 0
    var tree: Tree?
    var scanRoot: String = {
        // `AppleTree /some/path` scans that path on launch (also handy for QA).
        if CommandLine.arguments.count > 1 {
            var isDir: ObjCBool = false
            let p = (CommandLine.arguments[1] as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                return p
            }
        }
        // Whole disk by default: the user-data volume of the boot volume group.
        return "/System/Volumes/Data"
    }()
    /// Coding agents found on this Mac (Claude Code, Codex) and the user's PATH.
    var agentEnv = AgentEnvironment()
    /// The agent cleanup on screen, if any.
    var agentRun: AgentRun?
    /// An agent being installed or signed in from the panel.
    var agentSetup: AgentSetup?
    /// The first scan after launch opens the Clean Up panel once.
    private var panelOpenedAfterLaunch = false

    /// Custom providers, for the panel's picker menu. Shared store: settings
    /// edits land here immediately, no refresh wiring needed.
    var providerStore: ProviderStore { ProviderStore.shared }

    /// The planner for the Clean Up panel. `bz.engine` names it: a CLI agent
    /// ("claude", "codex") or a custom provider ("provider:<id>"). Default:
    /// the named agent if ready, else Claude Code, else Codex.
    var preferredAgent: InstalledAgent? {
        let ready = agentEnv.ready
        let picked = UserDefaults.standard.string(forKey: "bz.engine") ?? UserDefaults.standard.string(forKey: "bz.agent")
        if picked?.hasPrefix("provider:") == true { return nil }
        return ready.first { $0.kind.rawValue == picked } ?? ready.first { $0.kind == .claude } ?? ready.first
    }

    /// The provider picked in Settings, when `bz.engine` names one.
    var preferredProvider: LLMProvider? {
        guard let picked = UserDefaults.standard.string(forKey: "bz.engine"),
              picked.hasPrefix("provider:") else { return nil }
        let id = String(picked.dropFirst("provider:".count))
        return ProviderStore.shared.providers.first { $0.id == id }
    }

    /// Start the cleanup with whatever the user picked in Settings.
    func startCleanup() {
        if let provider = preferredProvider { startProvider(provider) }
        else if let agent = preferredAgent { startAgent(agent) }
    }

    /// Everything the scan pickers list: the whole disk, the home folder, then
    /// any mounted external drives.
    var scanTargets: [ScanTarget] {
        [ScanTargets.macintoshHD, ScanTargets.home, ScanTargets.applications] + drives
    }

    /// External drives, re-read on mount/unmount so a disk plugged in after
    /// launch shows up in both pickers without a relaunch.
    var drives: [ScanTarget] = ScanTargets.mountedDrives()

    func refreshDrives() {
        let found = ScanTargets.mountedDrives()
        if found != drives { drives = found }
    }

    func startProvider(_ provider: LLMProvider) {
        guard let tree, !scanning else { return }
        UserDefaults.standard.set("provider:\(provider.id)", forKey: "bz.engine")
        agentRun?.cancel()
        let run = AgentRun(agent: nil, env: agentEnv, tree: tree, scanRoot: scanRoot,
                           known: cleanup, provider: provider) { [weak self] in
            guard let self, !self.scanning else { return }
            self.startScan()
        }
        withAnimation(.snappy) { agentRun = run }
    }

    func startAgent(_ agent: InstalledAgent) {
        guard let tree, !scanning, !cleanupTrash.running else { return }
        UserDefaults.standard.set(agent.kind.rawValue, forKey: "bz.engine")
        UserDefaults.standard.set(agent.kind.rawValue, forKey: "bz.agent")
        agentRun?.cancel()
        let run = AgentRun(agent: agent, env: agentEnv, tree: tree, scanRoot: scanRoot, known: cleanup) { [weak self] in
            guard let self, !self.scanning else { return }
            self.startScan()
        }
        withAnimation(.snappy) { agentRun = run }
    }

    /// After the launch scan: open the panel on the Clean Up button or the
    /// setup offer. Nothing goes to an agent until the user clicks.
    func openPanelAfterLaunchScan() {
        guard !panelOpenedAfterLaunch, agentEnv.loaded, tree != nil, !scanning,
              !cleanupTrash.running, agentRun == nil else { return }
        panelOpenedAfterLaunch = true
        // Nothing goes to a planner on launch: this only opens the panel (or
        // presses the QA setup button). A click in the panel starts a run.
        panelRequests += 1
        // QA only: BZ_QA_SETUP=claude|codex presses the setup button. A
        // configured provider needs no sign-in, so it is not "not set up".
        if preferredAgent == nil, preferredProvider == nil,
           let kind = ProcessInfo.processInfo.environment["BZ_QA_SETUP"].flatMap(AgentKind.init) { setUp(kind) }
    }

    /// Run the same cleanup again: whatever produced this run (CLI agent or
    /// provider), re-planned from the current scan.
    func restart(_ run: AgentRun) {
        if let provider = run.provider { startProvider(provider) }
        else if let agent = run.agent { startAgent(agent) }
    }

    /// Bumped to ask the window to open the Clean Up panel.
    var panelRequests = 0

    func setUp(_ kind: AgentKind) {
        agentSetup?.cancel()
        let installed = agentEnv.agents.first { $0.kind == kind }
        agentSetup = AgentSetup(kind: kind, installed: installed, envPath: agentEnv.path) { [weak self] env in
            guard let self else { return }
            agentEnv = env
            agentSetup = nil
            if let agent = env.ready.first(where: { $0.kind == kind }) { startAgent(agent) }
        }
    }
    /// A tree has been shown at least once, so the views exist (see ContentView).
    var hasShownTree = false
    var viewRoot: Int = 0 {
        didSet {
            // A selection outside the folder on screen would read as over 100%.
            if let sel = selection, let tree, !tree.ancestry(sel).contains(viewRoot) { selection = nil }
        }
    }
    var selection: Int? = nil

    /// Select a node from a list, zooming out first if it is outside the
    /// folder on screen (it would have nothing to outline).
    func reveal(_ node: Int) {
        if let tree, !tree.ancestry(node).contains(viewRoot) { viewRoot = 0 }
        selection = node
    }

    /// Move the map to `folder` and make it the focus.
    ///
    /// One owner for every zoom — a crumb, a double-click, Return, the rings,
    /// Escape. Dropping the pick is what keeps the title path honest: leaving
    /// the old selection in place anchored the crumbs to a node several levels
    /// *below* the folder now on screen, so the truncation ate exactly the
    /// ancestors you needed to click to go back up. The map went up; the path
    /// did not follow, and there was no way further up.
    ///
    /// The selection is cleared rather than set to `folder`: the folder on
    /// screen is drawn as the whole map, and the accent ring strokes the
    /// selection's rect, so "selecting" it would outline the entire window.
    /// The title path and `selectEnclosingFolder` already fall back to
    /// `viewRoot`, so nothing is lost by leaving the pick empty.
    func navigate(to folder: Int) {
        viewRoot = folder
        selection = nil
        hovered = nil
    }

    /// Move the focus up to the folder that contains `node` — what the map
    /// needs so a small tile still lets you pick the folder holding it. When
    /// the focus is already the folder on screen there is no parent tile to
    /// move to, so this zooms out instead: the command always goes somewhere.
    ///
    /// Focus is the selection first, then the hover, then the folder on
    /// screen: the selection is the pick the user sees ringed, the hover only
    /// follows the pointer, and with neither the folder being viewed is still
    /// the thing "up" means. Every surface (map, rings, list) calls this one
    /// owner, so "up" cannot mean something different in each of them.
    ///
    /// Returns whether it moved anything, so a caller can fall back to plain
    /// zoom-out (Escape) when the focus is already at the top of the view.
    @discardableResult
    func selectEnclosingFolder(of node: Int? = nil) -> Bool {
        guard let tree, let focus = node ?? selection ?? hovered ?? (viewRoot == 0 ? nil : viewRoot)
        else { return false }
        let parent = Int(tree.parents[focus])
        guard parent != Int(UInt32.max), tree.isDir(parent) else { return false }
        // The enclosing folder is the folder on screen: it has no tile or row
        // of its own here, so step out one level instead.
        if focus == viewRoot || parent == viewRoot {
            guard viewRoot != 0 else { return false }
            // Only node 0 has `parents[0] == UInt32.max`, and it is excluded
            // above, so this always lands on a real folder.
            navigate(to: Int(tree.parents[viewRoot]))
            return true
        }
        selection = parent
        hovered = parent
        return true
    }

    /// The path to show in the title, and what it had to leave out.
    ///
    /// The folder on screen and its ancestors always survive, because those
    /// are what "go up" clicks: anchoring the path on a deep pick instead
    /// truncated the ancestors away exactly when they were needed, so the
    /// only crumbs left pointed *back down* and there was no way up.
    nonisolated struct CrumbPath {
        /// Folders to draw, outermost first.
        var nodes: [Int]
        /// Something above the first crumb was dropped.
        var elidedAbove = false
        /// Something between the folder on screen and the pick was dropped.
        var elidedBelow = false
    }

    /// At most this many parents above the folder on screen, and this many
    /// steps below it to the pick: enough to walk out, bounded so a deep
    /// chain cannot push the ancestors off the end of the title bar.
    private static let crumbParents = 5
    private static let crumbDepth = 3

    var crumbPath: CrumbPath {
        guard let tree else { return CrumbPath(nodes: [viewRoot]) }
        // The folder on screen, from the scan root down to it.
        let toRoot = tree.ancestry(viewRoot)
        var path = CrumbPath(nodes: [])
        // A pick *below* the folder on screen extends the path past it, so
        // the file you picked still shows which folder holds it.
        var below: [Int] = []
        if let selection, selection != viewRoot {
            let toPick = tree.ancestry(selection)
            if toPick.count > toRoot.count { below = Array(toPick.dropFirst(toRoot.count)) }
        }
        if below.count > Self.crumbDepth {
            below = Array(below.suffix(Self.crumbDepth))
            path.elidedBelow = true
        }
        let parents = Array(toRoot.suffix(Self.crumbParents))
        path.elidedAbove = parents.count < toRoot.count
        path.nodes = parents + below
        return path
    }

    /// How a scan target reads as a name: the whole disk is "Macintosh HD".
    /// One owner, so the title, the breadcrumbs and the rings' centre label
    /// cannot name the same root differently.
    var displayRootName: String {
        let p = scanRoot
        if p == "/System/Volumes/Data" { return String(localized: "Macintosh HD") }
        let last = (p as NSString).lastPathComponent
        return last.isEmpty ? p : last
    }
    var hovered: Int? = nil
    var freeBytes: UInt64 = 0
    /// Rebuildable folders worth deleting, largest first.
    var cleanup: [CleanupItem] = []
    let cleanupTrash = CleanupTrashBatch()
    /// Volume-used minus what the scan could see: root-only territory.
    var unscannedBytes: UInt64 = 0
    var showFreeSpace: Bool = UserDefaults.standard.bool(forKey: "bz.showFree") {
        didSet { UserDefaults.standard.set(showFreeSpace, forKey: "bz.showFree") }
    }
    var mapStyle: MapStyle = MapStyle(rawValue: UserDefaults.standard.string(forKey: "bz.mapStyle") ?? "") ?? .treemap {
        didSet { UserDefaults.standard.set(mapStyle.rawValue, forKey: "bz.mapStyle") }
    }

    private var handle: OpaquePointer?
    private var timer: Timer?
    private var startedAt: Date?
    private var activity: NSObjectProtocol?
    private var volumeTask: Task<VolumeSpace, Never>?

    func startScan(path: String? = nil) {
        if scanning || cleanupTrash.running { return }
        if let path { scanRoot = path }
        tree = nil
        cleanup = []
        viewRoot = 0
        selection = nil
        hovered = nil
        files = 0; dirs = 0; bytes = 0; elapsed = 0
        lastPollAt = nil; maxPollGap = 0
        scanning = true
        startedAt = Date()
        // Keep the process out of App Nap / timer coalescing while scanning.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Disk scan"
        )
        // Foundation may ask a disk-management service about purgeable space.
        // Read it alongside the scan, before publishing the finished tree, so
        // the main thread never waits synchronously on that service.
        let volumePath = scanRoot
        volumeTask = Task.detached(priority: .userInitiated) { VolumeSpace.read(volumePath) }
        handle = bz_scan_start(scanRoot)

        // 60 Hz: the elapsed time ticks every frame, so the screen keeps
        // moving while the engine assembles the tree after the last file is
        // counted (the counters sit still for that part).
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        // Common modes: keep polling while a control is being clicked.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private var lastPollAt: Date?
    private var maxPollGap: Double = 0

    private func poll() {
        guard let handle else {
            // A slow volume-space service must not freeze progress while the
            // already finished tree waits for its matching volume snapshot.
            if scanning { elapsed = -(startedAt?.timeIntervalSinceNow ?? 0) }
            return
        }
        if let last = lastPollAt { maxPollGap = max(maxPollGap, -last.timeIntervalSinceNow) }
        lastPollAt = Date()
        var f: UInt64 = 0, d: UInt64 = 0, b: UInt64 = 0
        var done: Int32 = 0
        bz_progress(handle, &f, &d, &b, &done)
        files = f; dirs = d; bytes = b
        elapsed = -(startedAt?.timeIntervalSinceNow ?? 0)
        if done != 0 {
            let doneAt = Date()
            let result = Tree(handle: handle)
            self.handle = nil
            if result == nil { bz_free(handle) }
            let pendingVolume = volumeTask
            volumeTask = nil
            Task {
                let space = await pendingVolume?.value ?? VolumeSpace(free: nil, used: nil)
                finishScan(result, space: space, doneAt: doneAt)
            }
        }
    }

    private func finishScan(_ result: Tree?, space: VolumeSpace, doneAt: Date) {
        timer?.invalidate()
        timer = nil
        tree = result
        if tree != nil { hasShownTree = true }
        if ProcessInfo.processInfo.environment["BZ_TIMING"] != nil {
            // Queue latency includes awaiting metadata and UI updates; it is
            // not a measurement of uninterrupted main-thread blocking.
            DispatchQueue.main.async {
                NSLog("BZ hand-off: queued completion %.1f ms after engine done", -doneAt.timeIntervalSinceNow * 1000)
            }
            NSLog("BZ done at %.3f, longest gap between polls %.1f ms", doneAt.timeIntervalSinceReferenceDate, maxPollGap * 1000)
        }
        scanning = false
        if let tree {
            Task {
                let found = await Task.detached(priority: .userInitiated) { Cleanup.find(in: tree) }.value
                // A rescan may have replaced the tree while discovery ran.
                // Node IDs only belong to the scan that produced them.
                guard self.tree === tree else { return }
                cleanup = found
                openPanelAfterLaunchScan()
            }
            NSLog("BZ scan done: %llu nodes, %llu unreadable dirs", UInt64(tree.count), tree.errors)
        }
        freeBytes = space.free ?? 0
        // Coverage honesty: compare scanned bytes with what the volume
        // says it holds. The difference is root-only space (Spotlight
        // index, unified logs, …) no unelevated app can read.
        unscannedBytes = 0
        if let tree, let used = space.used {
            let seen = tree.alloc[0]
            if used > seen {
                unscannedBytes = used - seen
            }
        }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}

nonisolated private struct VolumeSpace: Sendable {
    let free: UInt64?
    let used: UInt64?

    static func read(_ path: String) -> VolumeSpace {
        let values = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return VolumeSpace(
            free: values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) },
            used: path == "/System/Volumes/Data" ? volumeUsedBytes(path) : nil
        )
    }
}

/// Space used by this APFS volume alone, the figure `df` shows. statfs and
/// Foundation's systemSize/systemFreeSize describe the whole container,
/// which also holds the macOS system volume, VM swap and Recovery.
nonisolated func volumeUsedBytes(_ path: String) -> UInt64? {
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
    var reply = (length: UInt32(0), used: UInt64(0))
    let status = withUnsafeMutableBytes(of: &reply) {
        getattrlist(path, &request, $0.baseAddress, $0.count, 0)
    }
    guard status == 0 else { return nil }
    // Packed buffer: u_int32_t length, then off_t at offset 4 (unaligned).
    return withUnsafeBytes(of: &reply) { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
}

nonisolated enum Fmt {
    static func size(_ b: UInt64) -> String { Int64(b).formatted(.byteCount(style: .file)) }
    static func num(_ n: UInt64) -> String { n.formatted() }
}
