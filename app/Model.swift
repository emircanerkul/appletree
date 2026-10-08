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
              bz_cleanup_nodes(handle) != nil
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
        self.errors = bz_errors(handle)
    }

    // Clean Up's candidate list is NOT cached. `bz_remove_node` recomputes it
    // (`Flat::refresh_cleanup`), which may reallocate that `Vec`, so a pointer
    // captured here would dangle. Both are read live from the handle instead;
    // the tree arrays above are safe to cache because `remove_node` never
    // changes any `Vec`'s allocation.
    var cleanupCount: Int { Int(bz_cleanup_count(handle)) }
    func cleanupNode(_ index: Int) -> UInt32 {
        guard let nodes = bz_cleanup_nodes(handle) else { return 0 }
        return nodes[index]
    }

    deinit { bz_free(handle) }

    func isDir(_ i: Int) -> Bool { flags[i] & 1 != 0 }

    /// Forget a node's subtree locally, because its path left the scan root.
    ///
    /// In place in the engine, so this `Tree`'s cached pointers stay valid and
    /// no other node is renumbered — a rescan would do both wrong: it moves
    /// every buffer and renumbers every id, discarding the zoom, the selection
    /// and any open plan that names nodes.
    ///
    /// Returns whether the engine cut the link (false for the scan root, which
    /// can never be a removal target).
    @discardableResult
    func removeNode(_ node: Int) -> Bool {
        bz_remove_node(handle, UInt64(node)) == 1
    }

    func cleanupDescription(_ index: Int) -> String {
        guard let label = bz_cleanup_description(handle, UInt64(index)) else { return "" }
        return String(cString: label)
    }

    /// The tool owning candidate `index`, or nil when it was recognised by
    /// shape rather than by a `CACHE_RULES` row.
    ///
    /// The identity table exists to say *which* tool a cache belongs to; the
    /// description above is deliberately generic and stays the published panel
    /// label, so this is the narrower question (audit L2/SW-10).
    func cleanupTool(_ index: Int) -> String? {
        guard let name = bz_cleanup_tool(handle, UInt64(index)) else { return nil }
        let tool = String(cString: name)
        return tool.isEmpty ? nil : tool
    }

    /// The node at an absolute path, if the scan covered it. NSString
    /// normalization and the "/System/Volumes/Data" root-refix happen here;
    /// the engine resolves the already-refixed path against the name blob.
    nonisolated func node(at path: String) -> Int? {
        let root = self.path(0)
        var p = (path as NSString).standardizingPath
        // A whole-disk scan is rooted at the Data volume; /Users/… lives there.
        // `p != root` is required, not incidental: without it a path equal to
        // the root itself fails the `hasPrefix(root + "/")` test (the root has
        // no trailing slash where the prefix does) and the prefix is prepended
        // a second time, so the engine is asked for
        // "/System/Volumes/Data/System/Volumes/Data" and the root's own node
        // becomes unreachable. `src/ffi.rs` already resolves a path equal to
        // the root, so this pre-check must not defeat it.
        if root == "/System/Volumes/Data", p != root, !p.hasPrefix(root + "/") { p = root + p }
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

    /// Whether `node` still hangs off the root after an in-place removal.
    ///
    /// `removeNode` detaches a subtree by cutting one link, so a node inside it
    /// still has its own arrays but no path from the root. Views and the model
    /// must check this before trusting an id they were holding.
    func isAttached(_ node: Int) -> Bool {
        guard node >= 0, node < count else { return false }
        if node == 0 { return true }
        return ancestry(node).first == 0
    }

    /// The closest still-attached node at or above `node`, or 0.
    func attachedAncestor(of node: Int) -> Int {
        guard node > 0, node < count else { return 0 }
        for candidate in ancestry(node).reversed() where isAttached(candidate) {
            return candidate
        }
        return 0
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
        let home = AppEnvironment.realHome
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
                                 path: AppEnvironment.realHome)
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

    /// The volume classification, for the picker and for tests.
    enum VolumeClass: Equatable {
        /// Real storage media: offered as a scan target.
        case drive
        /// A disk image or a RAM disk: not a drive, never offered.
        case virtual
    }

    /// What backs the device behind `bsdName`.
    ///
    /// One owner for the question, so a test cannot assert a rule the picker
    /// does not use. See `isDiskImage` for what the property means.
    static func classifyVolumeForTest(bsdName: String?) -> VolumeClass {
        isDiskImage(bsdName: bsdName) ? .virtual : .drive
    }

    /// True when the device behind `bsdName` is *backed by something other than
    /// storage hardware* — a mounted disk image, or a RAM disk.
    ///
    /// `Physical Interconnect Location` answers this, and there are two values
    /// that mean "not a drive": `File` for a `.dmg`/installer whose bytes are a
    /// file, and `RAM` for a memory disk. Both are `Virtual Interface` devices;
    /// real storage reports `Internal`/`External`/`Thunderbolt`/…
    ///
    /// `RAM` was missing, so a RAM disk appeared in the picker as if it were a
    /// drive. Measured with `hdiutil attach -nomount ram://204800` (a 100 MB
    /// memory disk): path `/private/tmp/bzram`, name `BZRam`, protocol
    /// `Virtual Interface`, interconnect `RAM` — offered as a scan target while
    /// its 100 MB of system memory is not a disk anyone wants in a
    /// "why is my disk full" list. Apple's own header defines the value: "If the
    /// device is system memory that is being represented as a storage device,
    /// this key should be set."
    ///
    /// Searched upwards through the IOService plane: the property sits on the
    /// storage device above the volume's media, not on the media itself.
    /// A missing property reads as "a real drive" — the volume keeps its place
    /// in the list, so an unexpected device is never silently hidden.
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
            || location == kIOPropertyInterconnectRAMKey
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
        // An explicit path argument is a deliberate choice for this launch, so
        // it wins over the saved target.
        if let p = commandLineTarget {
            return p
        }
        // The target scanned last time, so the session opens where it left off.
        // Only if it is still there: an unmounted drive must not become the
        // launch scan, which would fail before the user sees a window.
        if let saved = UserDefaults.standard.string(forKey: Saved.scanRoot), !saved.isEmpty {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: saved, isDirectory: &isDir), isDir.boolValue {
                return saved
            }
        }
        // Whole disk by default: the user-data volume of the boot volume group.
        return "/System/Volumes/Data"
    }()
    /// The user's shell PATH, for the allowlisted cleanup commands. Tools live
    /// in Homebrew, ~/.local/bin and nvm, none of which an app launched by
    /// Finder has on its own PATH.
    var shellEnv = ShellEnvironment()
    /// The cleanup on screen, if any.
    var agentRun: AgentRun?
    /// A cleanup the user asked for, held until they acknowledge what is about
    /// to be sent off this Mac.
    ///
    /// App Store Guideline 5.1.2(i) requires explicit permission before personal
    /// data is shared with a third party "including with third-party AI". Before
    /// this, clicking "Clean up" *was* the consent: the scan summary left for
    /// Anthropic, OpenAI or the user's own endpoint with nothing having named
    /// the destination or described the payload.
    ///
    /// Nothing starts while this is non-nil. Every entry point — the panel's
    /// primary button, its planner menu, Settings' start and a restart —
    /// funnels through `startProvider`, which refuses to run until
    /// `grantCleanupConsent()` is called. Gating the buttons instead would
    /// leave the other paths open.
    var pendingConsent = false
    /// Who the held-back run would send to, so the dialog can name the
    /// destination. Guideline 5.1.2(i) is about *explicit permission*, and a
    /// dialog that does not say where the data goes cannot give it.
    var pendingConsentDestination = ""
    /// What a held-back start should do once consent is given. Set alongside
    /// `pendingConsent`, read once, then cleared.
    private var consentResume: (() -> Void)?
    /// Whether the user has ever granted this, so the dialog is a one-time
    /// decision rather than a toll gate on every cleanup.
    private static let consentKey = "bz.cleanupConsent"

    /// The provider picked in Settings, when `bz.engine` names one.
    var preferredProvider: LLMProvider? { preferredChoice?.provider }

    /// The whole choice in effect, so a caller that must react to whether a
    /// planner exists at all does not have to re-derive it.
    var preferredChoice: PlannerChoice? {
        let choices = plannerChoices
        if let id = defaultPlannerID, let match = choices.first(where: { $0.id == id }) { return match }
        return choices.first
    }

    /// Every planner the user may choose, in the order it is offered — the one
    /// owner of that list, read by the panel's menu and by Settings → General.
    var plannerChoices: [PlannerChoice] {
        PlannerChoice.catalog(providers: ProviderStore.shared.providers)
    }

    /// The planner in effect — one resolution, read by both the panel and
    /// Settings, which each used to keep their own fallback chain. The stored
    /// tag comes from `ProviderStore`, which publishes it, so a pick in either
    /// surface is visible to the other. A stale tag from an older install
    /// simply fails to resolve and the first configured provider leads.
    var defaultPlannerID: String? {
        PlannerChoice.preferredID(stored: ProviderStore.shared.engineTag, in: plannerChoices)
    }

    /// Start the cleanup with whatever the user picked in Settings.
    func startCleanup() {
        if let provider = preferredProvider { startProvider(provider) }
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

    /// Whether a *user-initiated* scan may start right now.
    ///
    /// A plan belongs to the scan that produced it — its cards carry node IDs
    /// and sizes from that tree, and a new walk renumbers the nodes and
    /// re-measures the sizes. Replacing the tree while a cleanup is still
    /// working would leave the panel reporting figures from a scan the user has
    /// moved past, and would swallow the run's own post-clean rescan (whose
    /// callback skips while a scan is in flight). This gates the scan controls
    /// only; `startScan` stays open because that callback goes through it.
    ///
    /// A finished run does not block a rescan: it has stopped touching the tree
    /// and shows a result that is explicitly historical.
    var canScan: Bool { !scanning && !cleanupTrash.running && !(agentRun?.isActive ?? false) }

    /// Whether a cleanup may start right now.
    ///
    /// A plan belongs to the scan that produced it, so a run and a scan cannot
    /// overlap; the guard is one rule, not one per entry point.
    private var canStartCleanup: Bool { tree != nil && !scanning && !cleanupTrash.running }

    func startProvider(_ provider: LLMProvider) {
        guard canStartCleanup, let tree else { return }
        guard consentsToSending() else {
            askForConsent(destination: provider.displayName) { [weak self] in self?.startProvider(provider) }
            return
        }
        // Through the store, so the record and the published value agree and
        // every surface reading it re-renders.
        ProviderStore.shared.select(engineTag: "provider:\(provider.id)")
        agentRun?.cancel()
        let run = AgentRun(provider: provider, tree: tree, scanRoot: scanRoot,
                           known: cleanup) { [weak self] in
            guard let self, !self.scanning else { return }
            self.startScan()
        }
        withAnimation(.snappy) { agentRun = run }
    }

    /// Whether the user has already agreed to send a scan summary to a planner.
    ///
    /// Stored, not per-session: the disclosure describes an ongoing behaviour,
    /// and re-asking on every cleanup would train the user to click through it.
    private func consentsToSending() -> Bool {
        UserDefaults.standard.bool(forKey: Self.consentKey)
    }

    /// Hold a start until the disclosure is acknowledged.
    private func askForConsent(destination: String, resume: @escaping () -> Void) {
        pendingConsentDestination = destination
        consentResume = resume
        pendingConsent = true
    }

    /// The user acknowledged the disclosure: remember it and run what was held.
    func grantCleanupConsent() {
        UserDefaults.standard.set(true, forKey: Self.consentKey)
        pendingConsent = false
        let resume = consentResume
        consentResume = nil
        resume?()
    }

    /// The user declined: drop the held start and leave the app untouched.
    func declineCleanupConsent() {
        pendingConsent = false
        pendingConsentDestination = ""
        consentResume = nil
    }

    /// Whether the Clean Up drawer can be opened.
    ///
    /// It needs a finished scan: without a tree there are no reclaimable folders
    /// and no scan for a planner to read, so the panel would be an empty drawer
    /// advertising an AI cleanup that cannot run.
    var canShowCleanup: Bool { tree != nil && !scanning }

    /// Open Settings on Model Providers with the add-provider form raised.
    ///
    /// The intent is recorded in the shared router and applied by the Settings
    /// scene; this only asks. `openSettings` needs an environment value, so the
    /// view that owns a click passes its own action in — the model cannot reach
    /// the Settings scene on its own, which is exactly why the request has to
    /// travel through a shared object rather than a direct call.
    func addModelProvider(openSettings: @escaping () -> Void) {
        SettingsRouter.shared.requestAddProvider()
        openSettings()
    }

    /// Open Settings on Model Providers without raising a form.
    ///
    /// For the panel's "Manage model providers": the user already has providers
    /// and wants that list, so a blank new-provider sheet would sit in the way
    /// of what they asked for.
    func manageModelProviders(openSettings: @escaping () -> Void) {
        SettingsRouter.shared.requestManageProviders()
        openSettings()
    }

    /// Open Settings on Model Providers with this provider's own form raised.
    func editModelProvider(_ provider: LLMProvider, openSettings: @escaping () -> Void) {
        SettingsRouter.shared.requestEditProvider(id: provider.id)
        openSettings()
    }

    /// Run the same cleanup again, re-planned from the current scan.
    func restart(_ run: AgentRun) {
        startProvider(run.provider)
    }

    /// Re-read the user's shell PATH, then publish it.
    ///
    /// Launch and every cleanup run both land here, so the PATH the command
    /// rows use cannot be applied two slightly different ways.
    func refreshShellEnvironment() async {
        shellEnv = await ShellRunner.find()
    }

    /// A tree has been shown at least once, so the views exist (see ContentView).
    var hasShownTree = false

    /// Bumped whenever the tree is edited IN PLACE.
    ///
    /// The views detect a *new* scan by object identity (`t !== tree`), which
    /// an in-place edit cannot show them: `Tree` is the same object before and
    /// after a removal. This is the signal they compare instead, so the
    /// treemap, the rings and the outline all re-read the arrays they cached.
    private(set) var treeRevision = 0

    /// Forget a path's subtree locally, because it just left the scan root.
    ///
    /// Deliberately NOT a rescan. A rescan walks the whole disk again and
    /// renumbers every node id (an id is an index into the flat arrays), which
    /// throws away the zoom, the selection, the hover and any open plan that
    /// names nodes — for one folder the user already knows has gone. The engine
    /// edits its arrays in place instead, so every id keeps its meaning and
    /// every total stays honest.
    ///
    /// The cleanup candidate list is rebuilt too, since a removed node can also
    /// un-prune candidates beneath it.
    @discardableResult
    func forgetPath(_ path: String) -> Bool {
        guard let tree, let node = tree.node(at: path), tree.removeNode(node) else {
            // The path was not in this scan's tree (or it was the root): there
            // is nothing to subtract, so leave the view exactly as it was.
            return false
        }
        let name = tree.name(node)
        cleanup = Cleanup.find(in: tree)
        // A selection, hover or zoom root inside what just went would now point
        // at a detached node; drop just those, so removing one member of a
        // multi-selection leaves the others picked rather than clearing them.
        validateSelection()
        if let hovered, !tree.isAttached(hovered) { self.hovered = nil }
        if !tree.isAttached(viewRoot) { viewRoot = tree.attachedAncestor(of: viewRoot) }
        treeRevision &+= 1
        NSLog("[bz] forgot %@ (node %d) in place; tree now %llu nodes", name, node, UInt64(tree.count))
        return true
    }

    var viewRoot: Int = 0 {
        didSet {
            // Only attachment is enforced here, not containment.
            //
            // The old single-selection rule dropped a pick that fell outside the
            // folder on screen, because one item outside the root reads as over
            // 100%. A multi-selection cannot use that rule: the selection is
            // shared across views on purpose, and dropping every member outside
            // the new root would silently discard most of it. Nothing is lost by
            // leaving off-screen members selected either — the map rings what it
            // draws, and the status bar and Delete still count the whole set.
            //
            // Every path that re-roots either clears the selection
            // (`navigate`, `rootForFocus`, a rescan, the trail) or moves the root
            // UP to an ancestor (an in-place removal), so a member outside the
            // root cannot arise from navigation in the first place.
            validateSelection()
        }
    }
    /// The multi-selection: primary anchor plus its members, with the
    /// antichain invariant owned by `SelectionSet`.
    ///
    /// The one place selection state lives. The views call this; none of them
    /// keeps its own copy, which is what stops the map, the rings and the list
    /// from disagreeing about what is picked.
    ///
    /// Cleared whenever the tree is REPLACED (a rescan renumbers every node id,
    /// so old ids would name different folders — see `Cleanup`'s header for the
    /// bug that caused), and validated in place when a node is removed.
    private(set) var picks = SelectionSet()

    /// The primary pick: the last node clicked, the range anchor, and what the
    /// breadcrumbs and status bar describe.
    ///
    /// A façade over `picks` rather than separate state, so there is exactly one
    /// selection and the single-pick callers keep working unchanged: assigning
    /// replaces the whole selection, which is what a plain click and every
    /// existing writer already meant.
    var selection: Int? {
        get { picks.primary }
        set { picks.replace(with: newValue) }
    }

    /// Make `node` the selection (plain click), or clear it with nil.
    func select(_ node: Int?) { picks.replace(with: node) }

    /// Cmd+click: add `node`, or remove it when already picked.
    func toggleSelection(_ node: Int) {
        guard let tree else { return }
        picks.toggle(node, in: tree)
    }

    /// Shift+click or Cmd+A: make these the selection, reduced to the outermost
    /// items so a swept folder stands for everything inside it.
    ///
    /// `anchor` keeps the end the user did not click as the anchor, so a second
    /// Shift+click re-ranges from the same place instead of creeping.
    func setSelection(_ nodes: [Int], anchor: Int? = nil) {
        guard let tree else { return }
        picks.set(nodes, anchor: anchor, in: tree)
    }

    /// Shift+click: extend the selection to `node`, ranging over the order the
    /// calling view draws. The whole gesture lives in `SelectionSet.extend`, so
    /// the map and the rings cannot read the same click differently.
    ///
    /// The anchor is projected onto the SAME level as the range: a primary
    /// picked in the list can be several levels below the folder the map is
    /// showing, and ranging from its own deep index would span the whole level
    /// plus everything under it — the same escape this gesture was just fixed
    /// for, arriving through the other endpoint.
    ///
    /// Returns whether anything changed.
    @discardableResult
    func extendSelection(to node: Int, order: [Int]) -> Bool {
        guard let tree else { return false }
        // The endpoint is a FOLDER: a file's tile cannot express a range (the
        // antichain rule would drop it against its own folder), and the scan
        // root is never a selectable target.
        guard let target = SelectionSet.folderEndpoint(for: node, in: tree),
              target != viewRoot else { return false }
        return picks.extend(to: target, order: order, in: tree)
    }

    /// Every picked node that still hangs off the root, outermost first.
    var pickedNodes: [Int] {
        guard let tree else { return picks.members }
        return picks.containmentDeduped(in: tree)
    }

    /// Drop members whose node an in-place removal detached.
    ///
    /// `removeNode` cuts one link, so a removed folder's descendants stop being
    /// attached without being individually touched: this drops the removed node
    /// and everything that was under it in one pass.
    func validateSelection() {
        guard let tree else { picks.clear(); return }
        picks.validate(in: tree)
    }

    /// Select a node from a list, zooming out first if it is outside the
    /// folder on screen (it would have nothing to outline).
    ///
    /// The zoom-out serves the selection rather than a change of folder the
    /// user asked for, so it re-roots without adding a trail visit.
    func reveal(_ node: Int) {
        if let tree, !tree.ancestry(node).contains(viewRoot) { rootForFocus(on: 0) }
        selection = node
    }

    /// Move the map to `folder` as a *visit*: a deliberate change of the folder
    /// being browsed, which is what the back/forward trail records.
    ///
    /// One owner for every zoom — a crumb, a double-click, the list, Return,
    /// ⌘↑, the rings, Escape. Dropping the pick is what keeps the title path
    /// honest: leaving the old selection in place anchored the crumbs to a
    /// node several levels *below* the folder now on screen, so the truncation
    /// ate exactly the ancestors you needed to click to go back up. The map
    /// went up; the path did not follow, and there was no way further up.
    ///
    /// The selection is cleared rather than set to `folder`: the folder on
    /// screen is drawn as the whole map, and the accent ring strokes the
    /// selection's rect, so "selecting" it would outline the entire window.
    /// The title path and `selectEnclosingFolder` already fall back to
    /// `viewRoot`, so nothing is lost by leaving the pick empty.
    func navigate(to folder: Int) {
        viewRoot = folder
        picks.clear()
        hovered = nil
        record(folder)
    }

    /// Re-root the map so `folder` is on screen, without touching the trail.
    ///
    /// This is focus mechanics, not browsing: arrow keys sliding the focus to
    /// a tile that scrolled off screen, or revealing a list selection, move the
    /// map to keep their target visible. Those are not folders the user chose
    /// to open, so they must not become steps on the trail — otherwise back
    /// would retrace wherever the focus wandered instead of the folders
    /// actually browsed.
    ///
    /// The trail is left exactly as it was. Rewriting the current entry to
    /// match the new root looked tidier, but it *erased* the folder being
    /// browsed: browse A, then B, then reveal a file outside B (the map zooms
    /// to the root) and open C, and back would land on the bare root — a folder
    /// the user never chose — with B gone from the history entirely.
    func rootForFocus(on folder: Int) {
        viewRoot = folder
        picks.clear()
        hovered = nil
    }

    // MARK: back / forward trail

    /// Where the trail is kept between launches.
    ///
    /// Paths, not node IDs: a node ID names a slot in one scan's arrays, so it
    /// means nothing after a rescan (the tree is replaced) or a relaunch (there
    /// is no tree at all). One owner for every key, so a rename cannot
    /// half-apply and leave state that restores from the wrong key.
    private enum Saved {
        static let scanRoot = "bz.scanRoot"
        static let trail = "bz.trail"
        static let trailIndex = "bz.trailIndex"
        /// The launch-scan preference, shared with Settings through @AppStorage.
        static let autoScan = "bz.autoScan"
        /// Whether the user has answered the launch-scan question at all.
        /// Distinct from `autoScan` itself: "never asked" and "asked and said
        /// no" are different states, and only the first one offers the choice.
        static let autoScanAnswered = "bz.autoScanSet"
    }

    /// Folders visited, oldest first, as absolute paths.
    private(set) var trail: [String] = []
    /// Which entry of `trail` is on screen, or -1 before the first visit.
    private(set) var trailIndex: Int = -1

    /// Deep enough to retrace a session, bounded so the stored entry and the
    /// re-resolution pass after a rescan stay small.
    private static let trailLimit = 200

    /// Offer back/forward only when there is a tree to move in: mid-scan the
    /// tree is gone, so a click would land on a dead control.
    var canGoBack: Bool { tree != nil && !scanning && trailIndex > 0 }
    var canGoForward: Bool {
        tree != nil && !scanning && trail.indices.contains(trailIndex + 1)
    }

    /// Offer "up" only while the folder on screen still has an ancestor. The
    /// scan root is node 0 and only `parents[0]` is the sentinel, so 0 is
    /// exactly "no parent left" — and mid-scan the tree is gone, as with
    /// back/forward.
    var canGoUp: Bool { tree != nil && !scanning && viewRoot != 0 }

    // MARK: launch scan preference

    /// The path passed on the command line, when there is a real one.
    ///
    /// `AppleTree /some/path` scans that path on launch (also handy for QA).
    /// The check is "an existing directory", not "argv has a second element":
    /// when the app is launched by double-clicking it in Finder, LaunchServices
    /// appends its own `-psn_0_…` process-serial-number argument, which is not
    /// a path. Counting arguments read that as an explicit target and silently
    /// disabled the launch scan, so double-clicking behaved differently from
    /// running the binary from a shell.
    static var commandLineTarget: String? {
        guard CommandLine.arguments.count > 1 else { return nil }
        let p = (CommandLine.arguments[1] as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue
        else { return nil }
        return p
    }

    /// The saved launch-scan choice. Reads `false` when never set: a first run
    /// must not scan — and must not request Full Disk Access — until the user
    /// says so.
    static var autoScanPreference: Bool {
        UserDefaults.standard.bool(forKey: Saved.autoScan)
    }
    /// True only while the user has never answered the launch-scan question.
    ///
    /// Distinct from the preference itself: "never asked" and "asked and said
    /// no" are different states, and only the first offers the choice.
    static var autoScanUnanswered: Bool {
        !UserDefaults.standard.bool(forKey: Saved.autoScanAnswered)
    }

    /// Answer the question: store the value and retire the offer for good.
    ///
    /// Called by the first scan (the single owner of "a scan began") and by
    /// Settings, since deliberately changing the setting there is also an
    /// answer. One writer per key, so the value and the answered flag cannot
    /// drift apart. Posts `autoScanAnswered` so a home screen that is already
    /// on screen retires its offer without needing a relaunch.
    static func answerAutoScan(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Saved.autoScan)
        UserDefaults.standard.set(true, forKey: Saved.autoScanAnswered)
        NotificationCenter.default.post(name: .autoScanAnswered, object: nil)
    }

    /// Show the folder that contains the one on screen.
    ///
    /// A deliberate change of folder, so it joins the trail through
    /// `navigate` and back steps down into the folder just climbed out of.
    /// One owner for the two "up" affordances that mean exactly this — the
    /// Parent Folder toolbar button and the middle click — so they cannot
    /// disagree. ⌘↑/Escape are deliberately not routed here: those climb out
    /// of the *focus* and only zoom out when it is already the folder on
    /// screen (`selectEnclosingFolder`), which is a different question.
    @discardableResult
    func goUp() -> Bool {
        guard canGoUp, let tree else { return false }
        navigate(to: Int(tree.parents[viewRoot]))
        return true
    }

    /// Step back to the folder visited before the current one.
    @discardableResult
    func goBack() -> Bool {
        guard canGoBack else { return false }
        trailIndex -= 1
        return applyTrail()
    }

    /// Step forward again into a folder the trail already holds.
    @discardableResult
    func goForward() -> Bool {
        guard canGoForward else { return false }
        trailIndex += 1
        return applyTrail()
    }

    /// Show the folder the trail points at.
    ///
    /// Entries that no longer resolve are dropped and the neighbouring one is
    /// tried, so a folder deleted since it was recorded cannot strand the whole
    /// trail behind a dead step.
    @discardableResult
    private func applyTrail() -> Bool {
        guard let tree else { return false }
        while trail.indices.contains(trailIndex) {
            if let node = resolve(trail[trailIndex], in: tree) {
                viewRoot = node
                picks.clear()
                hovered = nil
                persistTrail()
                return true
            }
            trail.remove(at: trailIndex)
            trailIndex = min(trailIndex, trail.count - 1)
        }
        persistTrail()
        return false
    }

    /// The node for a recorded folder path, or nil when this scan has no such
    /// folder. The scan root is node 0 by definition, which also saves the
    /// lookup for the entry every trail starts with.
    private func resolve(_ path: String, in tree: Tree) -> Int? {
        if path == tree.path(0) { return 0 }
        guard let node = tree.node(at: path), tree.isDir(node) else { return nil }
        return node
    }

    /// Note a deliberate change of folder on the trail.
    private func record(_ folder: Int) {
        guard let tree else { return }
        let path = tree.path(folder)
        if trail.indices.contains(trailIndex), trail[trailIndex] == path { return }
        // A fresh visit abandons what was ahead of it: you cannot go forward
        // into a branch you just chose to leave.
        if trail.indices.contains(trailIndex + 1) { trail.removeSubrange((trailIndex + 1)...) }
        trail.append(path)
        if trail.count > Self.trailLimit { trail.removeFirst(trail.count - Self.trailLimit) }
        trailIndex = trail.count - 1
        persistTrail()
    }

    /// Save what a relaunch needs: the target, the trail, and where in it we
    /// are. Called from the few places that change any of them, so the stored
    /// state cannot drift from the live one.
    private func persistTrail() {
        let defaults = UserDefaults.standard
        defaults.set(scanRoot, forKey: Saved.scanRoot)
        defaults.set(trail, forKey: Saved.trail)
        defaults.set(trailIndex, forKey: Saved.trailIndex)
    }

    /// Re-apply the saved folder and trail once a scan lands.
    ///
    /// Only when the finished scan is of the target that state was saved for: a
    /// trail of folders on one volume names nothing on another. The folders are
    /// looked up again in the new tree by path, because the scan that recorded
    /// them is gone.
    private func restoreTrail() {
        guard let tree else { return }
        let defaults = UserDefaults.standard
        let savedRoot = defaults.string(forKey: Saved.scanRoot)
        guard savedRoot == nil || savedRoot == scanRoot else {
            trail = []
            trailIndex = -1
            record(viewRoot)
            return
        }
        let savedIndex = defaults.integer(forKey: Saved.trailIndex)
        var restored: [String] = []
        var restoredIndex = -1
        for (i, path) in (defaults.stringArray(forKey: Saved.trail) ?? []).enumerated()
        where resolve(path, in: tree) != nil {
            // Track where the saved position landed after the missing entries
            // were skipped, so we come back to the same folder, not the same
            // offset in a shorter list.
            if i <= savedIndex { restoredIndex = restored.count }
            restored.append(path)
        }
        trail = restored
        trailIndex = restoredIndex
        if let node = trail.indices.contains(trailIndex) ? resolve(trail[trailIndex], in: tree) : nil {
            viewRoot = node
            picks.clear()
            hovered = nil
        } else {
            viewRoot = 0
            trail = []
            trailIndex = -1
        }
        // Seed the trail, so the folder the session opens in is already
        // something the user can step back from once they move on.
        record(viewRoot)
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
    ///
    /// Only meaningful when the scan actually had access to its root. See
    /// `scanCoverage` for why the two are tracked apart.
    var unscannedBytes: UInt64 = 0
    /// Whether the last scan lost coverage rather than merely meeting
    /// unreadable system data. Set by `finishScan`; drives the status bar's
    /// wording so a partial walk is never presented as a finished scan.
    var scanLostCoverage = false
    /// Set when a sandboxed scan could not hold the grant covering its root, so
    /// the UI offers the folder picker instead of showing a partial tree. See
    /// `startScan`.
    var needsFolderBeforeScan = false
    /// The path the grant covered when the scan began, for the diagnostic line.
    private var grantAtScanStart: String?
    /// The most this launch has ever reached, in allocated bytes.
    ///
    /// A later scan that falls well short of it has lost coverage — a signal
    /// that needs no volume figure, so it still works where `VolumeSpace` comes
    /// back empty.
    private var bestCoverageBytes: UInt64 = 0
    var showFreeSpace: Bool = UserDefaults.standard.bool(forKey: "bz.showFree") {
        didSet { UserDefaults.standard.set(showFreeSpace, forKey: "bz.showFree") }
    }
    var mapStyle: MapStyle = MapStyle(rawValue: UserDefaults.standard.string(forKey: "bz.mapStyle") ?? "") ?? .treemap {
        didSet { UserDefaults.standard.set(mapStyle.rawValue, forKey: "bz.mapStyle") }
    }

    private var handle: OpaquePointer?
    private var timer: Timer?
    /// The sandbox extension for the folder the user chose — the app's only
    /// route to their files now that the home-relative temporary exception is
    /// retired. Held for the **session**, not one scan: cleanup runs after a
    /// scan and reaches the same paths, so releasing at the end of the walk
    /// would make every Move to Trash fail. See `ScopedAccess.Grant`.
    private let scopedGrant = ScopedAccess.Grant()
    private var startedAt: Date?
    private var activity: NSObjectProtocol?
    private var volumeTask: Task<VolumeSpace, Never>?

    /// Whether the empty home screen still offers the launch-scan choice.
    ///
    /// Lives on the model rather than in the view so the one owner of "a scan
    /// began" — `startScan`, whatever triggered it — can retire the offer. A
    /// view-held flag would have to be cleared at all five scan entry points
    /// and would drift the moment one was added.
    var launchScanOffered = ScanModel.autoScanUnanswered

    func startScan(path: String? = nil) {
        if scanning || cleanupTrash.running { return }
        // A scan is the answer, whichever control started it: record the
        // current preference and retire the first-run offer for good. Saving
        // the value here (rather than only in the checkbox) is what makes a
        // bare "scan now" without touching the checkbox persist as "no" to
        // auto-scan.
        Self.answerAutoScan(Self.autoScanPreference)
        launchScanOffered = false
        if let path { scanRoot = path }
        tree = nil
        cleanup = []
        viewRoot = 0
        // The new tree renumbers every node id, so old picks would name
        // different folders; the selection is scoped to one tree by design.
        picks.clear()
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
        // Keep the sandbox extension held around the engine call: the engine
        // stats the scan root before walking it, so a root the sandbox denies
        // yields a one-node tree and an empty panel rather than an error. The
        // hold outlives the walk on purpose — cleanup happens afterwards.
        //
        // Acquired *before* the volume-space read is dispatched, because that
        // read asks a disk-management service about the same root and runs
        // detached: with the hold below it, the task could reach the root before
        // the extension existed, which is the contradiction the old ordering
        // left in place (the comment claimed "around", the code did not).
        //
        // **The result is load-bearing, and used to be discarded.** `hold()`
        // returns nil when nothing usable is stored — never chosen, stale, or
        // forgotten — and in that state the walk has no access to its own root.
        // Running anyway is how a partial scan reached the screen: measured in a
        // sandboxed process with the real engine, a scan root reachable only
        // through the grant yields 154.49 GB / 751 unreadable folders when it is
        // held and 54.32 GB / 27 when it is not, with the count depending on
        // *when* access was lost (releasing mid-walk gives anything from 79 to
        // 154 GB). The panel showed that partial tree as a finished scan and
        // labelled the missing space "root-only", i.e. told the user it was
        // unfixable system data (audit SW-7).
        //
        // A sandboxed build that cannot hold the grant therefore refuses to scan
        // and asks for the folder again — the picker is the only thing that can
        // create the grant, so failing here and reopening it is the one route
        // that works. A non-sandboxed build needs no grant at all and is
        // unaffected.
        let grantPath = scopedGrant.hold()
        if AppEnvironment.isSandboxed, grantPath == nil {
            scanning = false
            startedAt = nil
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            self.activity = nil
            needsFolderBeforeScan = true
            return
        }
        // Foundation may ask a disk-management service about purgeable space.
        // Read it alongside the scan, before publishing the finished tree, so
        // the main thread never waits synchronously on that service.
        let volumePath = scanRoot
        volumeTask = Task.detached(priority: .userInitiated) { VolumeSpace.read(volumePath) }
        handle = bz_scan_start(scanRoot)
        // What the grant actually covers, recorded for the scan's own diagnostic
        // line: a scan that ran with no grant (or a narrower one than the root)
        // is the difference between a partial tree and a complete one.
        grantAtScanStart = grantPath

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
        // Benchmark hook. Off unless asked for, so normal use pays only a
        // dictionary read. Environment variables do not reach an app started
        // by LaunchServices (Finder, `open`), and `launchctl setenv` does not
        // reach a process launchd did not spawn, so the switch is a preference:
        //   defaults write com.erklab.apps.appletree bz.benchTiming -bool true
        //   defaults write com.erklab.apps.appletree bz.benchResult -string /tmp/at.json
        // An app has no controlling terminal under LaunchServices, so `print`
        // would go nowhere: the line is written to the path the harness names.
        // bz.benchExit then quits, so a harness can time the app end to end.
        if UserDefaults.standard.bool(forKey: "bz.benchTiming"), let tree {
            // Positive: `timeIntervalSince` already computes later-minus-earlier,
            // unlike the `-timeIntervalSinceNow` form the live timer uses.
            let seconds = doneAt.timeIntervalSince(startedAt ?? doneAt)
            let tool = "appletree-gui"
            let secs = String(format: "%.6f", seconds)
            let files = UInt64(tree.nFiles[0])
            let bytes = tree.alloc[0]
            let errors = tree.errors
            let rss = rssBytes()
            let line = "BZ_BENCH {\"tool\":\"\(tool)\",\"path\":\"\(scanRoot)\","
                + "\"seconds\":\(secs),\"files\":\(files),\"bytes\":\(bytes),"
                + "\"errors\":\(errors),\"peak_rss_bytes\":\(rss.peak),"
                + "\"rss_bytes\":\(rss.current)}"
            if let path = UserDefaults.standard.string(forKey: "bz.benchResult"), !path.isEmpty {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            } else {
                print(line)
                fflush(stdout)
            }
            if UserDefaults.standard.bool(forKey: "bz.benchExit") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
            }
        }
        // Put the session back where it was: the folder being browsed, and the
        // trail behind it. Only meaningful once a tree exists, because the
        // recorded folders have to be looked up in it.
        if result != nil { restoreTrail() }
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
            }
            NSLog("BZ scan done: %llu nodes, %llu unreadable dirs", UInt64(tree.count), tree.errors)
        }
        freeBytes = space.free ?? 0
        // Coverage honesty: compare scanned bytes with what the volume says it
        // holds. A *small* difference is root-only space (Spotlight index,
        // unified logs, …) that no unelevated app can read, and a large one is
        // the app having lost access to a subtree it should have walked.
        //
        // Telling those apart is the point. Measured on this machine's Data
        // volume: 163.59 GB consumed, 154.50 GB reached by an unprivileged
        // walk, so genuine root-only space is ~9 GB. The screenshots that
        // prompted this work showed 30.01 GB and 23.09 GB labelled the same way
        // — impossible as root-only, and in fact a walk that came back short.
        // The label told the user "not a permission problem you can fix", which
        // is exactly backwards in that case.
        //
        // Two independent signals, because neither alone is decisive:
        //   - the gap itself, against the best coverage this launch has seen;
        //   - the engine's own unreadable-directory count, which the healthy
        //     walk keeps at ~750 here and a lost-grant walk drives into the
        //     thousands (measured: 5,904–17,759 while the grant died mid-walk).
        unscannedBytes = 0
        scanLostCoverage = false
        if let tree, let used = space.used, used > tree.alloc[0] {
            unscannedBytes = used - tree.alloc[0]
        }
        // Best coverage this launch: a later scan that reaches less than an
        // earlier one has lost something, whatever the absolute numbers say.
        bestCoverageBytes = max(bestCoverageBytes, tree?.alloc[0] ?? 0)
        if let tree {
            scanLostCoverage = lostScanCoverage(
                scannedBytes: tree.alloc[0],
                volumeUsed: space.used,
                gap: unscannedBytes,
                errors: tree.errors,
                nodeCount: UInt64(tree.count),
                bestThisLaunch: bestCoverageBytes,
                heldGrant: grantAtScanStart != nil,
                sandboxed: AppEnvironment.isSandboxed
            )
        }
        // One self-contained line per scan, so the next time a total moves the
        // cause is a grep rather than a log flood:
        //
        //   log show --last 30m --predicate 'eventMessage CONTAINS "BZ scan diag"'
        //
        // It records what the number cannot show on its own: the grant that was
        // actually held, the volume figure the gap was measured against, this
        // launch's best coverage, and the verdict. `bytes` is the figure the
        // panel displays; `volumeUsed` says what it should be near.
        if let tree {
            NSLog(
                "BZ scan diag: bytes=%llu volumeUsed=%@ gap=%llu best=%llu files=%llu nodes=%llu errors=%llu lostCoverage=%d grant=%@ root=%@",
                tree.alloc[0],
                space.used.map(String.init) ?? "unknown",
                unscannedBytes,
                bestCoverageBytes,
                UInt64(tree.nFiles[0]),
                UInt64(tree.count),
                tree.errors,
                scanLostCoverage ? 1 : 0,
                grantAtScanStart ?? "none",
                scanRoot
            )
        }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}

/// Whether a finished scan lost access to part of its root, rather than merely
/// meeting data no unelevated process may read.
///
/// Pure, so the verdict is testable without a live scan and cannot drift from
/// the numbers it is derived from. Three independent signals, because no single
/// one is decisive on its own:
///
/// 1. **The gap**, against what the volume says it consumed. Measured here:
///    163.59 GB consumed, 154.50 GB reached by an unprivileged walk, so genuine
///    root-only space is ~9 GB. A 20 GB threshold sits well clear of that and
///    well under the 30.01 / 23.09 GB the broken scans showed.
/// 2. **The unreadable-directory count.** The healthy walk reports ~750 here; a
///    walk whose grant died mid-run reported 5,904–17,759. The engine counts a
///    denied directory, so a loss of access inflates it directly.
/// 3. **This launch's own best.** A scan that reachhes materially less than an
///    earlier one in the same process has lost something, whatever the absolute
///    figures say — and unlike (1) this needs no volume figure, which a
///    sandboxed build cannot always read.
///
/// A sandboxed scan that held no grant is lossy by definition, but only if it
/// produced more than the one-node tree a wholly-unreadable root yields.
nonisolated func lostScanCoverage(
    scannedBytes: UInt64,
    volumeUsed: UInt64?,
    gap: UInt64,
    errors: UInt64,
    nodeCount: UInt64,
    bestThisLaunch: UInt64,
    heldGrant: Bool,
    sandboxed: Bool
) -> Bool {
    guard nodeCount > 1 else { return false }
    // 20 GB: clear of the ~9 GB genuine root-only figure, well under the
    // 23 GB+ a partial walk produces.
    let materialGap: UInt64 = 20_000_000_000
    if volumeUsed != nil, gap > materialGap { return true }
    if errors > 2_000 { return true }
    if bestThisLaunch > scannedBytes, bestThisLaunch - scannedBytes > materialGap { return true }
    if sandboxed, !heldGrant { return true }
    return false
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

/// Peak resident set size of this process, in bytes, and the current value.
///
/// Used only by the benchmark hook. `resident_size_max` is the kernel's own
/// high-water mark, so it is a real peak rather than whatever the process
/// happened to hold at the moment the scan finished. bench/ measures the
/// engine's own peak separately, in a process that never loads the UI.
nonisolated func rssBytes() -> (peak: UInt64, current: UInt64) {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return (0, 0) }
    return (UInt64(info.resident_size_max), UInt64(info.resident_size))
}

nonisolated enum Fmt {
    static func size(_ b: UInt64) -> String { Int64(b).formatted(.byteCount(style: .file)) }
    static func num(_ n: UInt64) -> String { n.formatted() }
}

extension Notification.Name {
    /// The launch-scan question has been answered, so any home screen still
    /// offering it should retire the offer. Posted by `answerAutoScan`, which
    /// is the only writer of the answered flag.
    static let autoScanAnswered = Notification.Name("bz.autoScanAnswered")
}
