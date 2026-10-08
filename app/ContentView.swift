import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @State private var model = ScanModel()
    @State private var showTable = true
    @AppStorage("bz.showCleanup") private var showCleanup = false
    @AppStorage("bz.listWidth") private var listWidth = 390.0
    /// Scan the whole disk at launch. Default off: a first run must not start a
    /// whole-disk scan — nor raise the Full Disk Access prompt — before the
    /// user has said so. The empty home screen offers the choice once; Settings
    /// → General carries it afterwards.
    @AppStorage("bz.autoScan") private var autoScan = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: NSColor(calibratedWhite: 0.10, alpha: 1))
                // Build the empty canvases while the first scan is running,
                // so AppKit setup does not delay the finished tree. Once built,
                // the list and treemap stay alive (hidden) through
                // a rescan: tearing them down and rebuilding them made AppKit
                // redo its first-time setup and froze the window as the new
                // scan landed. A new tree only reloads into the same views.
                if model.scanning || model.tree != nil || model.hasShownTree {
                    // Not HSplitView: next to the Clean Up inspector it put AppKit
                    // in an endless constraint-update loop and crashed the app
                    // seconds after every scan with the panel open.
                    HStack(spacing: 0) {
                        if showTable {
                            // The three state values are read *here* on purpose:
                            // it is what makes SwiftUI re-run `updateNSView` when
                            // the map zooms or the tree is edited in place (see
                            // `OutlinePanel`).
                            OutlinePanel(model: model,
                                         viewRoot: model.viewRoot,
                                         selection: model.selection,
                                         revision: model.treeRevision)
                                .frame(width: listWidth)
                            ListDivider(width: $listWidth)
                        }
                        Group {
                            switch model.mapStyle {
                            case .treemap: TreemapView(model: model)
                            case .rings: SunburstView(model: model)
                            }
                        }
                        .frame(minWidth: 400, maxWidth: .infinity)
                    }
                    // Hidden by an opaque cover below, not by opacity or hit
                    // testing: SwiftUI re-inserts AppKit views when those change.
                }
                if model.tree == nil {
                    Group {
                        if model.scanning {
                            ScanProgress(model: model)
                        } else if needsFDA {
                            fdaOverlay
                        } else if needsFolderChosen {
                            folderChoiceOverlay
                        } else {
                            idleOverlay
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: NSColor(calibratedWhite: 0.10, alpha: 1)))
                    .contentShape(Rectangle())
                }
            }
            Divider()
            ScanStatusBar(model: model)
        }
        .frame(minWidth: 760, minHeight: 500)
        .inspector(isPresented: $showCleanup) {
            CleanupPanel(model: model)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
        }
        .toolbar { toolbar }
        .task {
            await model.refreshShellEnvironment()
        }
        // A drive plugged in or ejected while the window is open: keep the
        // scan pickers (toolbar menu and idle overlay) in step with the Mac.
        .onReceive(NotificationCenter.default.publisher(
            for: NSWorkspace.didMountNotification)) { _ in model.refreshDrives() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWorkspace.didUnmountNotification)) { _ in model.refreshDrives() }
        // A cleanup run always shows in the panel.
        .onChange(of: model.agentRun == nil) { if model.agentRun != nil { showCleanup = true } }
        // Settings also answers the launch-scan question. Without this the
        // offer would linger on an already-open home screen until a relaunch,
        // and the user would be asked something they just decided.
        .onReceive(NotificationCenter.default.publisher(for: .autoScanAnswered)) { _ in
            model.launchScanOffered = false
        }
        .hidingWindowTitle()
        // Mouse side buttons walk the folder trail, the way they do in a
        // browser. They arrive as `otherMouseDown` on whatever view is under
        // the pointer, and the app has several (the map, the rings, the list,
        // the toolbar), so a per-view handler would only fire over one of them.
        // A window-scoped monitor catches them wherever the pointer is.
        .background(HistoryMouseButtons(model: model))
        .onAppear {
            // Never start a whole-disk scan without FDA: every protected
            // app container would fire a permission prompt.
            // bz.autoScan defaults to off, so a first run shows the empty home
            // screen with the one-time launch-scan offer instead of scanning.
            // An explicit `AppleTree /path` argument still scans: that is a
            // deliberate choice for this launch, made before the window opened.
            // `commandLineTarget` ignores the `-psn_0_…` argument that
            // LaunchServices adds on a double-click, which is what a plain
            // `arguments.count > 1` check mistook for a target.
            guard autoScan || ScanModel.commandLineTarget != nil else { return }
            requestScan()
        }
    }

    @State private var needsFDA = false
    /// Whether the sandboxed build could not use the folder the user chose, so
    /// the pick produced no grant that covers the target. Distinct from
    /// `needsFDA`: that card asks for a permission this build can never receive,
    /// while this one reports that the choice itself gave no access and points
    /// at the pick that always works. Shown instead of re-opening the panel, so
    /// a pick that cannot succeed ends the flow rather than looping it.
    @State private var needsFolderChosen = false
    /// Re-entry guard for `chooseFolder()`. The panel runs modally, so this is
    /// not a thread guard but a flow guard: a pick that still leaves the target
    /// uncovered must surface the card below, never prompt again.
    @State private var choosingFolder = false
    /// The path the FDA card is asking permission for, so "Scan without it"
    /// resumes the target the user actually picked instead of silently
    /// switching to the whole disk.
    @State private var pendingScanPath: String? = nil

    /// The one way a scan starts from the UI.
    ///
    /// A whole-disk scan without Full Disk Access makes macOS fire a
    /// permission prompt for every protected app container, so the launch path
    /// has always refused to start one — and README promises exactly that
    /// ("A whole-disk scan is never started without Full Disk Access"). With
    /// auto-scan off by default the first run reaches the scan buttons
    /// directly, so that guard has to live here, where every button passes,
    /// rather than only on the launch path.
    ///
    /// A narrower target (Home, Applications, a drive) raises no such prompts,
    /// so it starts immediately even without the grant.
    private func requestScan(path: String? = nil) {
        // A plan belongs to the scan it came from, so no user-initiated scan
        // may replace that tree while a run is on screen. Enforced here, at the
        // one path every button and menu item passes through, rather than
        // repeated on each control — the last-added control is the one that
        // would otherwise forget it.
        guard model.canScan else { return }
        let target = path ?? model.scanRoot
        // The sandboxed build cannot read the user's files until they have handed
        // it a folder, so a request for a target outside its own container goes
        // straight to the picker.
        //
        // Measured on a build with only the sandbox, picker and bookmark
        // entitlements (the home-relative exception is now retired): `~/` and
        // `/System/Volumes/Data/Users` are DENIED, while `/Applications`,
        // `/System/Volumes/Data/Library` and `/Volumes` are readable. The denied
        // ones would silently produce the empty panel that reads as "Nothing
        // large to clean up" rather than as a missing permission.
        //
        // The gate is `covers(_:)`, not "is a bookmark stored". Existence was
        // the bug (B3): one grant of `/Applications` disabled the gate for Home
        // and for the whole disk, so clicking Home raised no panel, scanned a
        // subtree it had no access to, and showed an empty tree while
        // `grantedPath` still said `/Applications`. Coverage asks the only
        // question that matters here — does the grant the app holds actually
        // authorize *this* target.
        //
        // **Coverage is the ONLY condition.** A second predicate used to narrow
        // this to the targets the UI's own list happened to name (Macintosh HD,
        // Home, `/Volumes/*`). Everything else — a folder the user picked in the
        // panel, which is then what `model.scanRoot` holds and what Rescan and
        // the next launch request — was declared "not gated", skipped this
        // branch, and started a scan the sandbox denied. Measured in a sandboxed
        // bundle: such a target produced a 1-node tree with `errors=1`, i.e. the
        // panel showed "Nothing large to clean up" for a folder the user had
        // explicitly handed over (audit SW-2). A target allowlist beside the
        // coverage test can only ever disagree with it; there is no reason for
        // one to exist.
        //
        // `/Applications` therefore prompts now too, and that is the right
        // trade: an unnecessary panel costs one click, while a silently empty
        // scan costs the feature. Measured, `/Applications` is readable on the
        // entitlements alone, so the common case still resolves in one click —
        // and a grant made for it is remembered like any other.
        //
        // Opening the panel here, rather than showing a card that tells the user
        // to open it, is the point: only the panel can extend the sandbox, so a
        // button that merely displays instructions cannot make the click work.
        if AppEnvironment.isSandboxed, !ScopedAccess.covers(target) {
            chooseFolder()
            return
        }
        // A sandboxed build must never raise the FDA card, because it can never
        // satisfy it. Measured with the same bundle identifier and the same
        // signing identity, so the same TCC grant applied to both builds: the
        // unsandboxed one reported `FDA.isActive() == true` and could read
        // ~/Library/Messages, while the sandboxed one reported false and was
        // denied. tccd logged the grant (`Modify kTCCServiceSystemPolicyAllFiles`
        // for this bundle), so the denial is App Sandbox's own and no amount of
        // granting or restarting clears it: the card would loop forever.
        guard !AppEnvironment.isSandboxed,
              target == ScanTargets.macintoshHD.path, !FDA.isActive() else {
            model.startScan(path: path)
            return
        }
        pendingScanPath = path
        needsFDA = true
    }

    /// The sandboxed build's "that choice gave no access" card.
    ///
    /// Shown when a pick still leaves the requested target uncovered. The
    /// alternative — opening the panel again — is the loop this replaces: the
    /// same unsatisfiable choice is offered forever, exactly like the FDA card
    /// a sandboxed build can never clear. One sentence of explanation ends it.
    private var folderChoiceOverlay: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(String(localized: "AppleTree could not use that folder"),
                  systemImage: "folder.badge.questionmark")
                .font(.title3.weight(.semibold))
            Text(String(localized: "The folder you chose did not give AppleTree access. Choose a different folder — Macintosh HD always works."))
                .multilineTextAlignment(.leading)
                .foregroundStyle(.secondary)
                .font(.callout)
            Button("Choose Folder…") {
                needsFolderChosen = false
                chooseFolder()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: 480, alignment: .leading)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 56)
    }

    private var fdaOverlay: some View {
        // Top-anchored like the window's other states: dead-center made the
        // permission card float in the middle of an empty scan area.
        VStack(alignment: .leading, spacing: 14) {
            Label("AppleTree needs Full Disk Access", systemImage: "lock.shield")
                .font(.title3.weight(.semibold))
            Text("System Settings → Privacy & Security → Full Disk Access.\nRemove any old AppleTree rows, then add \(Bundle.main.bundleURL.path).\nmacOS only applies the permission to a freshly launched app.")
                .multilineTextAlignment(.leading)
                .foregroundStyle(.secondary)
                .font(.callout)
            HStack(spacing: 12) {
                Button("Open System Settings") { openFDASettings() }
                Button("I granted it — Relaunch") { FDA.relaunch() }
                    .buttonStyle(.borderedProminent)
            }
            Button("Scan without it") {
                needsFDA = false
                // The target the FDA card interrupted, or the default whole
                // disk when the launch path raised it.
                model.startScan(path: pendingScanPath)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: 480, alignment: .leading)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 56)
    }

    // MARK: toolbar

    @ViewBuilder
    private var titleCrumbs: some View {
        // Its own view so the selection read below invalidates only the
        // crumbs, not the whole window body on every arrow keypress.
        TitleCrumbs(model: model)
    }

    /// Back, forward and up through the folders visited.
    ///
    /// Beside the title path, because that is the state they move through. They
    /// are the visible twin of ⌘[ and ⌘]: the buttons and the keyboard both
    /// call the same two model methods, so the pair cannot drift apart.
    ///
    /// Up sits last, right of the two arrows: back/forward retrace the trail
    /// while up leaves the trail behind by climbing to the parent folder, and
    /// the same control is a mouse middle click. It disables itself once the
    /// scan root is on screen, so the control never fires into nothing.
    @ViewBuilder
    private var historyButtons: some View {
        Button {
            model.goBack()
        } label: {
            Label("Back", systemImage: "chevron.backward")
        }
        .disabled(!model.canGoBack)
        .help("Back")

        Button {
            model.goForward()
        } label: {
            Label("Forward", systemImage: "chevron.forward")
        }
        .disabled(!model.canGoForward)
        .help("Forward")

        Button {
            model.goUp()
        } label: {
            Label("Parent Folder", systemImage: "arrow.up")
        }
        .disabled(!model.canGoUp)
        .help("Parent Folder")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // macOS 26+: crumbs sit bare in the Liquid Glass toolbar, pushed apart
        // from the controls by a flexible spacer. Older systems lay out the
        // classic toolbar themselves.
        if #available(macOS 26, *) {
            ToolbarItem(placement: .navigation) { titleCrumbs }
                .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible)
        } else {
            ToolbarItem(placement: .navigation) { titleCrumbs }
        }

        // Right-aligned, on their own so they do not read as part of the scan
        // controls: the path stays where the eye starts and the arrows sit at
        // the right edge of the title area, next to the controls.
        ToolbarItemGroup(placement: .automatic) {
            historyButtons
        }

        ToolbarItemGroup(placement: .automatic) {
            Menu {
                ForEach(model.scanTargets) { target in
                    Button(target.title) { requestScan(path: target.path) }
                }
                Divider()
                Button("Choose Folder…") { chooseFolder() }
            } label: {
                Label("Scan", systemImage: "folder")
            }
            .disabled(!model.canScan)
            .help("Choose what to scan")

            Button {
                requestScan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(!model.canScan)
            .help("Rescan")
        }

        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .automatic)
        }

        ToolbarItem(placement: .automatic) {
            Picker("View", selection: $model.mapStyle) {
                Label("Treemap", systemImage: "square.grid.2x2").tag(MapStyle.treemap)
                Label("Rings", systemImage: "circle.circle").tag(MapStyle.rings)
            }
            .pickerStyle(.segmented)
            // Neutral wording, deliberately: a tooltip is user-visible content,
            // so naming a competitor here carries the same 5.2.1 exposure as
            // naming one in the App Store metadata. The old string said
            // "(WizTree-style)" / "(DaisyDisk-style)" in all seven languages.
            .help("Treemap or concentric rings")
        }

        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .automatic)
        }

        ToolbarItemGroup(placement: .automatic) {
            Toggle(isOn: $model.showFreeSpace) {
                Label("Free Space", systemImage: "square.dashed")
            }
            .help("Show free space in the map")

            Toggle(isOn: $showTable) {
                Label("Directory List", systemImage: "sidebar.leading")
            }
            .help("Show directory list")

            Toggle(isOn: $showCleanup) {
                Label("Clean Up", systemImage: "sparkles")
            }
            // Off by default, and unavailable until a scan has produced
            // something to show: the panel is the AI cleanup offer plus the
            // reclaimable folders, so with no tree it would be an empty drawer.
            //
            // Never disabled while it is OPEN. A rescan clears the tree, so
            // gating purely on the scan state would disable the only control
            // that closes the drawer and strand the user with an empty panel
            // they cannot dismiss.
            .disabled(!model.canShowCleanup && !showCleanup)
            .help(model.canShowCleanup || showCleanup
                  ? "Show folders that are safe to clean up"
                  : "Scan first — the Clean Up panel needs a finished scan")
        }
    }

    // MARK: overlays

    private var idleOverlay: some View {
        // The toolbar Scan menu, repeated here: with no tree on screen this
        // overlay is the app's whole surface, so the scan targets belong at
        // the point of the empty state, not only the toolbar. Bounded width,
        // so the flow wraps drives onto further rows instead of running off
        // the window; `fallbackWidth` must match this frame.
        VStack(spacing: 14) {
            Image(systemName: "internaldrive")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Pick a target and scan")
                .foregroundStyle(.secondary)
            // The one-time launch-scan question, above the targets because it
            // decides what happens on *future* launches while the buttons below
            // act on this one. Shown only until the first scan answers it, and
            // never again after — not even after a Settings change.
            if model.launchScanOffered {
                launchScanOffer
            }
            FlowLayout(spacing: 10) {
                ForEach(model.scanTargets) { target in
                    Button(target.title) { requestScan(path: target.path) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
            // Bounded by the layout's own default, so the wrap width and the
            // frame can never disagree: a flow measured with no width limit
            // cannot wrap and reports one row wider than the window.
            .frame(width: FlowLayout.defaultWidth)
            // Its own row, and a quieter style: picking an arbitrary folder is
            // the uncommon case next to the listed targets. Reads as a
            // continuation of that row ("or choose a folder"), not as another
            // target; the toolbar menu keeps the plain "Choose Folder…" label,
            // where an menu item should read as an action.
            Button("or Choose a Folder") { chooseFolder() }
                .buttonStyle(.plain)
                .controlSize(.large)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    /// The first-run launch-scan choice.
    ///
    /// Same checkbox and wording as Settings → General, so the two surfaces
    /// teach one concept rather than two. Reading it here and later finding it
    /// in Settings should feel like the same switch moving, not a second
    /// question. Flipping it only stores the value; the offer is retired when a
    /// scan actually starts, so quitting before scanning keeps the choice
    /// visible next launch.
    private var launchScanOffer: some View {
        VStack(spacing: 6) {
            // @AppStorage persists to bz.autoScan on its own, so flipping this
            // stores the value without retiring the offer: the question is
            // answered when a scan starts, not when the box is ticked.
            Toggle("Scan when AppleTree opens", isOn: $autoScan)
                .toggleStyle(.checkbox)
            Text("Scan the whole disk at launch. Turn off to pick a folder yourself first.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Asks the user for a folder, then scans it — or reports that the choice
    /// gave no access.
    ///
    /// The panel extends this process's sandbox for the session; the bookmark
    /// is what makes the choice survive a relaunch. Measured: without one, a
    /// sandboxed build cannot read the folder at all next launch, so the scan
    /// would come back empty with no explanation.
    ///
    /// Three things this does that a bare `remember` did not:
    ///
    /// 1. **Normalises what the sandbox cannot bookmark.** Measured, the
    ///    sidebar's "Macintosh HD" row yields `file:///`; the difference between
    ///    `/` and its Data volume is a firmlink, not a subtree, and the raw
    ///    bookmark of `/` came back 460 bytes against 508 for
    ///    `/System/Volumes/Data`. The Data volume is the spelling
    ///    `ScanTargets.macintoshHD` scans, so a root pick becomes that path
    ///    before it is bookmarked — one spelling reaches the engine, not two.
    /// 2. **Checks what was actually stored.** `remember` reports whether
    ///    `bookmarkData` succeeded; the gate reads `grantedPath`. Verifying the
    ///    stored root with `covers` means a "successful" write that the gate
    ///    cannot use is treated as the failure it is, instead of scanning on
    ///    and coming back empty.
    /// 3. **Cannot re-prompt.** The `choosingFolder` guard makes the flow
    ///    one-shot: if the outcome still is not covered, the card explains it
    ///    and stops. Without that, an unsatisfiable pick re-entered this method
    ///    through `requestScan` and offered the same panel forever (the loop
    ///    that retired `needsScopedRoot` once already).
    ///
    /// A target that is not gated at all (`/Applications`, measured readable on
    /// the entitlements alone) still starts after a pick, since the pick was
    /// about a different folder and refusing it would strand the user.
    /// A pick that cannot be used reports it; it never silently becomes another
    /// scan. The retry this used to carry — bookmark the chosen folder, else
    /// bookmark `/System/Volumes/Data` and scan *that* — was worse than a
    /// failed pick: measured in a sandboxed bundle, choosing `/opt`,
    /// `/private/var` or an unmounted `/Volumes/Ghost` made `remember` fail with
    /// error 256, the retry then succeeded for the Data volume, the coverage
    /// check below passed because it was now asking about a different path, and
    /// the app scanned the whole disk. The user asked for one folder and got an
    /// unrelated multi-minute scan with no explanation (audit SW-3).
    private func chooseFolder() {
        guard !choosingFolder else { return }
        choosingFolder = true
        defer { choosingFolder = false }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // The panel normalises the sidebar's "Macintosh HD" row to `file:///`;
        // the Data volume is the spelling this app scans and bookmarks.
        let scanPath = url.path == "/" ? ScanTargets.macintoshHD.path : url.path
        _ = ScopedAccess.remember(URL(fileURLWithPath: scanPath))
        // What matters is the stored root, not the write's return value: a
        // bookmark that no longer resolves (or resolves elsewhere) authorizes
        // nothing. `grantedPath` is the resolved truth the gate itself reads.
        if ScopedAccess.grantedPath == nil || !ScopedAccess.covers(scanPath) {
            needsFolderChosen = true
            return
        }
        needsFolderChosen = false
        // The user may have changed their mind about scanning while the panel
        // was open; the gate ran before it, so ask again (audit SW-8).
        guard model.canScan else { return }
        // Scan the folder the grant actually covers — the normalised pick, not
        // the raw `file:///` the panel may have handed back. `choosingFolder`
        // is still set here, so even a re-entrant gate match cannot re-prompt.
        requestScan(path: scanPath)
    }

    private func openFDASettings() { openFullDiskAccessSettings() }
}

/// Observe 60 Hz counters here so progress updates do not rebuild the toolbar.
private struct ScanProgress: View {
    let model: ScanModel
    var body: some View {
        VStack(spacing: 14) {
            Text(Fmt.size(model.bytes))
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text("\(Fmt.num(model.files)) files · \(Fmt.num(model.dirs)) folders · \(String(format: "%.2f", model.elapsed))s")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        // No spinner: the counters are the progress, and a ProgressView is an
        // AppKit view whose insertion recomputed the window's key-view loop
        // (laying out the hidden list) just as each scan started.
        // No numeric-text transition: its blur is rasterized on the CPU and
        // stalled the main thread for most of a short scan. Plain digits
        // updated at the 60 Hz poll count up smoothly on their own.
    }
}

/// Pointer movement changes only the status text, not the window's view graph.
private struct ScanStatusBar: View {
    let model: ScanModel
    var body: some View {
        HStack(spacing: 8) {
            if let tree = model.tree {
                if let sel = model.hovered ?? model.selection {
                    Text(tree.displayPath(sel))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    let a = tree.alloc[sel]
                    let rootA = max(tree.alloc[model.viewRoot], 1)
                    Text("\(Fmt.size(a)) · \(String(format: "%.1f%%", 100 * Double(a) / Double(rootA)))")
                        .monospacedDigit()
                } else {
                    Text("\(Fmt.num(UInt64(tree.nFiles[model.viewRoot]))) files · \(Fmt.size(tree.alloc[model.viewRoot]))")
                    Spacer()
                    if tree.errors > 0 {
                        if FDA.isActive() || AppEnvironment.isSandboxed {
                            // Either the grant is held, or this is the sandboxed
                            // build where it cannot be held at all (see
                            // `requestScan`). Both cases are root-owned or
                            // sandbox-denied system folders: unreadable by
                            // design, not a permission problem the user can fix.
                            let gap = model.unscannedBytes > 1_000_000_000
                                ? " · ~\(Fmt.size(model.unscannedBytes)) root-only" : ""
                            Text("\(String(tree.errors)) system folders unreadable\(gap)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            Button {
                                openFullDiskAccessSettings()
                            } label: {
                                Label("\(String(tree.errors)) folders skipped — grant Full Disk Access", systemImage: "lock.shield")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Text("scanned in \(String(format: "%.1fs", model.elapsed))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                Text("AppleTree").foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private func openFullDiskAccessSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
        NSWorkspace.shared.open(url)
    }
}

/// Left panel: a real NSOutlineView — the same control as Finder's list
/// view. Native disclosure triangles, real file icons, alternating rows,
/// keyboard navigation.
/// The draggable line between the list and the treemap (210–400 pt).
private struct ListDivider: View {
    @Binding var width: Double
    @State private var dragStart: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = dragStart ?? width
                                dragStart = start
                                width = min(400, max(210, start + drag.translation.width))
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
    }
}

/// Wraps its children onto as many rows as they need, left-aligned. Used for
/// the idle screen's scan targets: how many drives are mounted is not known
/// when the layout is written, so a fixed HStack would overflow the window.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    /// Width the idle overlay gives this layout, used to wrap when the parent
    /// proposes no width. It lives here so the caller's frame and this
    /// fallback cannot drift apart — a flow measured with no width limit
    /// cannot wrap, reports one row wider than the window, and is then centred
    /// outside it with both ends cut off.
    static let defaultWidth: CGFloat = 460

    private func wrapWidth(_ proposal: ProposedViewSize) -> CGFloat {
        guard let width = proposal.width, width.isFinite, width > 0 else { return Self.defaultWidth }
        return width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = wrapWidth(proposal)
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > limit {
                widest = max(widest, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += rowWidth > 0 ? spacing + size.width : size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        widest = max(widest, rowWidth)
        // Never claim more width than the limit, or the row cannot fit.
        return CGSize(width: min(widest, limit), height: totalHeight + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        // Wrap at the space actually given, so a narrowed window wraps rather
        // than drawing outside its bounds.
        let limit = min(bounds.width, wrapWidth(proposal))
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.minX + limit {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                       proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// An outline view that can build the shared node menu for a row.
///
/// `menu(for:)` is the AppKit hook for a right-click (and for the context-menu
/// key): returning nil leaves the row with no menu, which is why the list had
/// none — the map and the rings built their own in `rightMouseDown`, and the
/// list never did. The coordinator holds the model the menu needs.
final class NodeOutlineView: NSOutlineView {
    weak var menuCoordinator: OutlinePanel.Coordinator?

    /// Highlight exactly the rows the model has selected.
    ///
    /// The outline is told what to highlight rather than deciding it, so a
    /// selection made in the map or the rings shows up here. Called after any
    /// gesture that changes the selection from outside the outline.
    /// True while this view is pushing a model selection INTO AppKit.
    ///
    /// `selectRowIndexes` posts `NSOutlineViewSelectionDidChange`, whose delegate
    /// handler writes the row set back to the model — which would re-enter this
    /// push and, on any model-side reduction, oscillate. The flag makes the echo
    /// a no-op so the sync flows one way per gesture.
    var isSyncingFromModel = false

    func syncHighlightFromModel() {
        guard !isSyncingFromModel, let model = menuCoordinator?.model else { return }
        isSyncingFromModel = true
        defer { isSyncingFromModel = false }
        let wanted = Set(model.picks.members)
        var rows = IndexSet()
        for row in 0..<numberOfRows {
            guard let item = item(atRow: row) as? OutlinePanel.Item,
                  wanted.contains(item.id) else { continue }
            rows.insert(row)
        }
        guard rows != selectedRowIndexes else { return }
        selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { scrollRowToVisible(first) }
    }

    /// Declare what a click means BEFORE AppKit acts on it, so the selection
    /// notification that follows can be read correctly instead of guessed at.
    ///
    /// The three gestures are told apart by geometry, which is certain:
    ///
    /// - a click in a row's disclosure triangle opens/closes a folder and must
    ///   not change the selection at all;
    /// - a click with Cmd or Shift adds to the selection;
    /// - any other click on a row replaces it.
    ///
    /// A click that misses every row (empty space below the last row) is left
    /// undeclared: AppKit keeps the selection, and `.unknown` asserts only what
    /// the rows already say.
    override func mouseDown(with event: NSEvent) {
        declareGesture(for: event)
        super.mouseDown(with: event)
    }

    /// Classify the click and hand it to the coordinator.
    private func declareGesture(for event: NSEvent) {
        guard let coordinator = menuCoordinator else { return }
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return }

        // The disclosure triangle has its own rect, so a click inside it is a
        // folder open/close and nothing else. `frameOfOutlineCell` is the only
        // reliable way to ask: comparing x against the indentation would guess.
        let cell = frameOfOutlineCell(atRow: row)
        if !cell.isEmpty, cell.contains(point) {
            coordinator.noteGesture(.disclosure)
            return
        }
        let flags = event.modifierFlags.intersection([.command, .shift])
        coordinator.noteGesture(flags.isEmpty ? .replace : .extend)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let coordinator = menuCoordinator, let model = coordinator.model,
              let tree = model.tree else { return nil }
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let item = self.item(atRow: row) as? OutlinePanel.Item else { return nil }
        // Right-clicking a row OUTSIDE the selection focuses it, so the menu's
        // actions and the list's highlight cannot disagree about which item was
        // meant. Right-clicking a row INSIDE the selection keeps the whole
        // selection: the user sees several rows highlighted and the menu is the
        // way to act on all of them, so collapsing to one row here would make
        // the menu act on something other than what is highlighted.
        if !selectedRowIndexes.contains(row) {
            self.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            // Tell the model inline rather than waiting for the selection
            // notification: the menu is built on the very next line, so
            // `NodeActions` would read the OLD rows and act on one set while the
            // list highlighted another.
            model.setSelection([item.id])
        }
        return NodeMenu.menu(node: item.id, tree: tree, model: model)
    }

    /// Every node this list currently renders as a row.
    ///
    /// Used to tell an off-screen pick from a row the user has just deselected:
    /// a member absent from `highlightedNodes` because it has no row here must
    /// stay selected, while one that HAS a row and is not highlighted was really
    /// un-picked.
    func renderedNodes() -> [Int] {
        (0..<numberOfRows).compactMap { (item(atRow: $0) as? OutlinePanel.Item)?.id }
    }

    /// Every highlighted row's node, outermost-first order preserved.
    ///
    /// AppKit's own multi-select answers "which rows", and this is the one
    /// conversion from rows to nodes. The model is then told, so the map and the
    /// rings ring the same items — the outline never keeps a second copy of the
    /// selection (see `SelectionSet`: one owner is what stops the views
    /// disagreeing).
    var highlightedNodes: [Int] {
        selectedRowIndexes.compactMap { (item(atRow: $0) as? OutlinePanel.Item)?.id }
    }

    /// Delete and Backspace remove every highlighted row — Shift with either
    /// deletes them permanently — exactly as on the map and the rings.
    ///
    /// The ROWS, not `model.selection`: they can disagree while no row is
    /// highlighted — collapsing the selected row's parent clears AppKit's
    /// selection without the model hearing about it — and Delete must name what
    /// the screen shows as chosen. `model.pickedNodes` is the fallback for the
    /// case the outline is focused while the selection was made elsewhere: the
    /// same shared set is then acted on, which is what one selection means.
    ///
    /// Cmd+A selects every row at the current level, never recursing: the list
    /// shows one folder's children and a recursive select-all would tick
    /// millions of nodes the user cannot see. Cmd-Up climbs out of the
    /// selection, matching the map and the rings. Everything else stays
    /// AppKit's.
    override func keyDown(with event: NSEvent) {
        if let kind = RemovalKeys.intent(for: event),
           let model = menuCoordinator?.model, let tree = model.tree {
            let rows = highlightedNodes
            let nodes = rows.isEmpty ? model.pickedNodes : rows
            NodeActions.remove(nodes: nodes, kind: kind, tree: tree, model: model)
            return
        }
        // Cmd+A: everything this view currently renders.
        //
        // ONE definition, shared by all three views: "every node the view draws
        // right now, reduced to the outermost". The reduction (owned by
        // `SelectionSet`) is what makes the three agree despite drawing
        // differently — the list renders an expanded folder AND its contents, so
        // the folder collapses them to itself; the map and the rings draw one
        // level, so their order is already the level. The previous comment
        // claimed "the current level, never recursing", which was never what
        // this code did and is not what a list can do: a row the user can see and
        // click is a row Cmd+A must be able to name.
        if event.modifierFlags.contains(.command), event.keyCode == 0,
           let model = menuCoordinator?.model {
            let all = (0..<numberOfRows).compactMap { (item(atRow: $0) as? OutlinePanel.Item)?.id }
            guard !all.isEmpty else { return }
            model.setSelection(all)
            syncHighlightFromModel()
            return
        }
        // Cmd-[ / Cmd-] walk the trail of folders visited, as on the map. The
        // list follows the new root through its own reload, so this only has
        // to re-select the row for the folder now on screen.
        if event.modifierFlags.contains(.command), event.keyCode == 33 || event.keyCode == 30,
           let model = menuCoordinator?.model {
            let moved = event.keyCode == 33 ? model.goBack() : model.goForward()
            if moved {
                menuCoordinator?.syncSelection()
                return
            }
        }
        if event.keyCode == 126, event.modifierFlags.contains(.command),
           let model = menuCoordinator?.model,
           model.selectEnclosingFolder() == true {
            menuCoordinator?.syncSelection()
            return
        }
        super.keyDown(with: event)
    }
}

/// A row that can say "something inside me is selected" while collapsed.
///
/// A collapsed folder is one row, so a pick inside it has no row of its own and
/// the selection would be invisible — yet the pick still exists: Delete removes
/// it and the byte total counts it. The row therefore draws the accent as
/// translucent strips rather than a solid bar, which is how AppKit itself shows
/// a partially selected container, and the user can see that opening it will
/// reveal a selection rather than nothing.
final class PartialRowView: NSTableRowView {
    static let reuseID = NSUserInterfaceItemIdentifier("partial-row")

    /// A pick lives strictly inside this row's folder.
    ///
    /// AppKit recycles row views, so a reused row could otherwise keep the
    /// previous item's stripes: `didAdd`/`refreshPartialRows` set this for every
    /// row they touch, and this clears on reuse so a stale `true` cannot survive
    /// into a row that does not want it.
    var holdsPick = false {
        didSet { if holdsPick != oldValue { needsDisplay = true } }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        holdsPick = false
    }

    /// Draw the selection in the accent whenever the WINDOW is active — even
    /// when another view holds keyboard focus.
    ///
    /// AppKit's stock row view picks its selection colour from `isEmphasized`,
    /// which is false whenever the table is not first responder. Since the
    /// selection here is SHARED across three views, a pick made in the treemap
    /// left the list showing a grey bar while the map ringed the same item in
    /// accent blue — the same selection looking like two different things, and
    /// the list looking like it had merely lost focus rather than that the item
    /// was chosen. The selection is not a focus indicator here; it is the app's
    /// selection, so it keeps its colour while the window is active.
    ///
    /// A genuinely inactive window (the user is in another app) still dims, via
    /// the system's own unemphasized colour, so this does not fight the platform.
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected, selectionHighlightStyle != .none else { return }
        let active = window?.isKeyWindow ?? false
        let fill = active ? NSColor.controlAccentColor
                          : NSColor.unemphasizedSelectedContentBackgroundColor
        fill.setFill()
        bounds.fill()
    }

    /// The partial look is drawn as the row's BACKGROUND, not as its selection.
    ///
    /// `drawSelection` only runs when the row is actually selected — and the row
    /// that needs this is the one that is NOT selected, holding a collapsed
    /// folder over picks inside it. Drawing here means the strips appear whether
    /// or not AppKit considers the row highlighted.
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard holdsPick, selectionHighlightStyle != .none else { return }
        // A lighter blue than the selection accent: a partial mark must not
        // compete with the solid bar of a genuinely selected row, and the accent
        // is also what the rows above and below use when they really are picked.
        let stripeColor = NSColor.controlAccentColor.blended(withFraction: 0.35, of: .white)
            ?? NSColor.controlAccentColor
        // A very faint wash, purely so the row reads as touched at all.
        let wash: CGFloat = 0.06
        stripeColor.withAlphaComponent(wash).setFill()
        bounds.fill()
        // 45° DIAGONAL hatching, the conventional "partly selected" texture.
        // Strokes are drawn and clipped to the row, which keeps the spacing
        // honest at 45 degrees instead of foreshortening it the way a vertical
        // pass would.
        let stripe: CGFloat = 0.45
        let drawAlpha = (stripe - wash) / (1 - wash)
        stripeColor.withAlphaComponent(drawAlpha).setStroke()
        let band: CGFloat = 3
        let gap: CGFloat = 8            // wider spacing: the hatch reads as texture
        let path = NSBezierPath()
        path.lineWidth = band
        // One diagonal per (gap + band) of horizontal travel. A 45° line spans
        // the row's height as it crosses, so the sweep must start a full height
        // to the left and run a full height to the right of the bounds.
        let step = band + gap
        var x = bounds.minX - bounds.height
        while x < bounds.maxX + bounds.height {
            path.move(to: NSPoint(x: x, y: bounds.minY))
            path.line(to: NSPoint(x: x + bounds.height, y: bounds.maxY))
            x += step
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).setClip()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// List cells laid out by frame, not Auto Layout: AppKit re-lays out every
/// row as it reloads, and solving constraints per row made reloads stall.
final class NameCell: NSTableCellView {
    private static let font = NSFont.systemFont(ofSize: 13)
    private static let lineHeight = ceil(font.ascender - font.descender + font.leading)

    override init(frame: NSRect) {
        super.init(frame: frame)
        let iv = NSImageView()
        let tf = NSTextField(labelWithString: "")
        tf.font = Self.font
        tf.lineBreakMode = .byTruncatingMiddle
        addSubview(iv)
        addSubview(tf)
        imageView = iv
        textField = tf
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let h = bounds.height
        imageView?.frame = NSRect(x: 2, y: ((h - 16) / 2).rounded(), width: 16, height: 16)
        textField?.frame = NSRect(x: 23, y: ((h - Self.lineHeight) / 2).rounded(),
                                  width: max(0, bounds.width - 25), height: Self.lineHeight)
    }
}

/// A right-aligned figure (size or percentage) in the list.
final class ValueCell: NSTableCellView {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let lineHeight = ceil(font.ascender - font.descender + font.leading)

    override init(frame: NSRect) {
        super.init(frame: frame)
        let tf = NSTextField(labelWithString: "")
        tf.font = Self.font
        tf.textColor = .secondaryLabelColor
        tf.alignment = .right
        addSubview(tf)
        textField = tf
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        textField?.frame = NSRect(x: 0, y: ((bounds.height - Self.lineHeight) / 2).rounded(),
                                  width: max(0, bounds.width - 2), height: Self.lineHeight)
    }
}

struct OutlinePanel: NSViewRepresentable {
    let model: ScanModel

    /// The model state this list RENDERS, passed in as a value.
    ///
    /// `NSViewRepresentable` only calls `updateNSView` when a dependency the
    /// enclosing `body` actually reads changes. `body` reads `tree`,
    /// `scanning`, `mapStyle` and `hasShownTree` — not `viewRoot`, `selection`
    /// or `treeRevision` — so navigating the map left this list showing the
    /// previous folder: the breadcrumb said `… › GrandPerspective.app ›
    /// Contents` while the list still held one `Contentts` row, and a
    /// disclosure triangle there did nothing until a map click happened to
    /// trigger `syncSelection()`.
    ///
    /// Reading these here makes the list depend on them, so every zoom,
    /// selection and in-place removal redraws it. `viewRoot` is the folder the
    /// list should be rooted at; `treeRevision` changes when the tree was
    /// edited in place.
    let viewRoot: Int
    let selection: Int?
    let revision: Int

    /// An NSObject so the outline hashes and compares items by pointer: as a
    /// plain Swift class every lookup went through the Swift runtime's
    /// conformance checks, a third of expanding a 100k-item folder.
    final class Item: NSObject {
        private(set) var id: Int
        private(set) var tree: Tree
        private var kids: [Item]?
        init(id: Int, tree: Tree) {
            self.id = id
            self.tree = tree
        }
        var children: [Item] {
            if kids == nil { kids = tree.children(id).map { Item(id: Int($0), tree: tree) } }
            return kids!
        }

        /// Only an untouched, collapsed item can be rebound without leaving
        /// stale child identities in AppKit's outline cache.
        func canRebind(to id: Int, in tree: Tree) -> Bool {
            kids == nil && self.tree.isDir(self.id) == tree.isDir(id)
                && self.tree.children(self.id).count == tree.children(id).count
                && self.tree.name(self.id) == tree.name(id)
        }

        func rebind(to id: Int, in tree: Tree) {
            precondition(kids == nil)
            self.id = id
            self.tree = tree
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var model: ScanModel?
        var tree: Tree?
        var viewRoot = -1
        /// The `treeRevision` these rows were built from: an in-place removal
        /// keeps the same `Tree` object, so identity alone cannot tell this
        /// data source that any size changed.
        var revision = -1
        /// The picks the list has already opened ancestors for, so expansion
        /// happens once per NEW pick instead of on every redraw. Without this a
        /// collapsed folder was re-opened the moment anything invalidated the
        /// view, which made the disclosure triangle look broken.
        private var lastSyncedPicks: Set<Int> = []



        var roots: [Item] = []
        weak var outline: NSOutlineView?
        private var iconCache: [String: NSImage] = [:]

        func rebuildIfNeeded() {
            guard let model, let t = model.tree else { return }
            if t !== tree || model.viewRoot != viewRoot || model.treeRevision != revision {
                let childIDs = t.children(model.viewRoot)
                // Bound name comparisons for extremely wide directories.
                let reuseRows = t !== tree && model.viewRoot == viewRoot
                    && roots.count <= 4_096
                    && outline?.numberOfRows == roots.count && childIDs.count == roots.count
                    && zip(roots, childIDs).allSatisfy { item, id in
                        item.canRebind(to: Int(id), in: t) && outline?.isItemExpanded(item) == false
                    }
                // Rows are about to be thrown away, and AppKit keys expansion and
                // selection to the Item objects being discarded. Remember what was
                // open first, by NODE ID — an in-place removal keeps every other
                // id stable, so the same id names the same folder afterwards.
                // Without this, deleting one row collapsed every folder the user
                // had opened and dropped the row they were on.
                let openIDs = reuseRows ? [] : expandedIDs()
                // Every highlighted row, not just `selectedRow`: a reload throws
                // the row objects away, and restoring only the primary's row made
                // the whole multi-selection collapse on the next in-place removal.
                let selectedIDs = reuseRows ? [] : selectedItems.map(\.id)
                tree = t
                viewRoot = model.viewRoot
                revision = model.treeRevision
                let started = Date()
                if reuseRows, let outline {
                    // A rescan often has the same top-level shape. Keep row
                    // views/disclosure buttons and refresh only their cells.
                    for (item, id) in zip(roots, childIDs) { item.rebind(to: Int(id), in: t) }
                    outline.deselectAll(nil)
                    outline.enumerateAvailableRowViews { rowView, row in
                        guard self.roots.indices.contains(row) else { return }
                        for (column, definition) in outline.tableColumns.enumerated() {
                            if let cell = rowView.view(atColumn: column) as? NSTableCellView {
                                self.configure(cell, column: definition.identifier.rawValue, item: self.roots[row])
                            }
                        }
                    }
                } else {
                    roots = childIDs.map { Item(id: Int($0), tree: t) }
                    outline?.reloadData()
                    // Put the user's own tree back exactly as they left it.
                    // Rows stay COLLAPSED by default: entering a folder shows
                    // that folder's direct children and nothing deeper, which is
                    // what a file browser is for — the map is where depth is
                    // read at a glance. An id that no longer has children simply
                    // fails to expand, so a removed subtree needs no special
                    // case here.
                    restore(open: openIDs, selected: selectedIDs)
                }
                if ProcessInfo.processInfo.environment["BZ_TIMING"] != nil {
                    NSLog("BZ list reload: %.1f ms", -started.timeIntervalSinceNow * 1000)
                }
            }
        }

        /// The node ids of every row currently expanded, outermost first.
        ///
        /// Recurses only into expanded rows, whose children AppKit has already
        /// materialised, so the cost is bounded by what is actually open rather
        /// than by the size of the tree.
        private func expandedIDs() -> [Int] {
            guard let outline else { return [] }
            var open: [Int] = []
            func walk(_ items: [Item]) {
                for item in items where outline.isItemExpanded(item) {
                    open.append(item.id)
                    walk(item.children)
                }
            }
            walk(roots)
            return open
        }

        /// Every item the outline currently has selected.
        private var selectedItems: [Item] {
            guard let outline else { return [] }
            return outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? Item }
        }

        /// Re-open each remembered id (parents before children) and restore the
        /// selected ROWS. Ids absent from the new tree are skipped, so this needs
        /// no knowledge of what was removed.
        private func restore(open: [Int], selected: [Int]) {
            guard let outline else { return }
            let wanted = Set(open)
            if !wanted.isEmpty {
                func walk(_ items: [Item]) {
                    for item in items where wanted.contains(item.id) {
                        // Guard on real children: `expandItem` on a leaf would
                        // draw an empty disclosure row.
                        guard !item.tree.children(item.id).isEmpty else { continue }
                        outline.expandItem(item)
                        walk(item.children)
                    }
                }
                walk(roots)
            }
            // Every remembered row, so a multi-selection survives the reload.
            // A node absent from the new tree simply has no item to match, so a
            // removed subtree needs no special case here.
            var rows = IndexSet()
            for id in selected {
                guard let match = find(id) else { continue }
                let row = outline.row(forItem: match)
                if row >= 0 { rows.insert(row) }
            }
            if !rows.isEmpty {
                outline.selectRowIndexes(rows, byExtendingSelection: false)
                outline.scrollRowToVisible(rows.first!)
            }
        }

        /// The item for a node id, searching only the rows that exist.
        private func find(_ id: Int) -> Item? {
            func walk(_ items: [Item]) -> Item? {
                for item in items {
                    if item.id == id { return item }
                    if let hit = walk(item.children) { return hit }
                }
                return nil
            }
            return walk(roots)
        }

        func icon(for name: String, isDir: Bool) -> NSImage {
            let key: String
            if isDir {
                key = "/folder"
            } else if let dot = name.lastIndex(of: "."), dot != name.startIndex {
                key = String(name[name.index(after: dot)...]).lowercased()
            } else {
                key = "/plain"
            }
            if let hit = iconCache[key] { return hit }
            let img: NSImage
            if key == "/folder" {
                img = NSWorkspace.shared.icon(for: .folder)
            } else if key == "/plain" {
                img = NSWorkspace.shared.icon(for: .data)
            } else {
                img = NSWorkspace.shared.icon(for: UTType(filenameExtension: key) ?? .data)
            }
            // Pre-render to a small bitmap: workspace icons are lazy, and every
            // row asking IconServices for one again made list reloads slow.
            let scale = outline?.window?.backingScaleFactor ?? 2
            let px = Int(16 * scale)
            let flat: NSImage
            if let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) {
                rep.size = NSSize(width: 16, height: 16)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                img.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
                NSGraphicsContext.restoreGraphicsState()
                flat = NSImage(size: NSSize(width: 16, height: 16))
                flat.addRepresentation(rep)
            } else {
                flat = img
            }
            iconCache[key] = flat
            return flat
        }

        // MARK: data source
        func outlineView(_ v: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let item = item as? Item else { return roots.count }
            // AppKit asks counts without expanding a row. The flat tree
            // already knows this; do not allocate wrappers for its children.
            return item.tree.children(item.id).count
        }
        func outlineView(_ v: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            item == nil ? roots[index] : (item as! Item).children[index]
        }
        func outlineView(_ v: NSOutlineView, isItemExpandable item: Any) -> Bool {
            let it = item as! Item
            return it.tree.isDir(it.id) && !it.tree.children(it.id).isEmpty
        }

        /// A reusable row view, so the partial-selection look is decided in one
        /// place instead of by recolouring every cell.
        func outlineView(_ v: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            (v.makeView(withIdentifier: PartialRowView.reuseID, owner: nil) as? PartialRowView)
                ?? {
                    let r = PartialRowView()
                    r.identifier = PartialRowView.reuseID
                    return r
                }()
        }

        /// Mark every row whose folder holds a hidden pick.
        ///
        /// Called with the highlight, because the two describe the same state:
        /// which rows are picked outright, and which merely contain a pick the
        /// collapsed row is hiding.
        func refreshPartialRows() {
            guard let outline, let tree, let model else { return }
            outline.enumerateAvailableRowViews { rowView, row in
                guard let partial = rowView as? PartialRowView,
                      let item = outline.item(atRow: row) as? Item else { return }
                partial.holdsPick = needsPartialMark(item, tree: tree, model: model)
            }
        }

        /// Whether a row shows the "something inside me is selected" hatch.
        ///
        /// Only a COLLAPSED folder needs it. An expanded one already shows the
        /// selected child, on its own solid row, so hatching the parent too would
        /// be a second, contradictory statement about the same fact — and on a
        /// tree with many open folders it hatched most of the visible rows, which
        /// is what made the list look broken rather than informative.
        ///
        /// A picked row never needs it either: `SelectionSet`'s antichain rule
        /// means a folder and something inside it can never both be picked, so
        /// `contains` is enough to exclude it.
        private func needsPartialMark(_ item: Item, tree: Tree, model: ScanModel) -> Bool {
            guard !model.picks.contains(item.id) else { return false }
            guard outline?.isItemExpanded(item) != true else { return false }
            return model.picks.holdsPick(inside: item.id, in: tree)
        }

        // MARK: cells
        func outlineView(_ v: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
            let it = item as! Item
            let colID = col?.identifier.rawValue ?? "name"
            let reuse = NSUserInterfaceItemIdentifier("cell-\(colID)")

            if colID == "name" {
                let cell = (v.makeView(withIdentifier: reuse, owner: nil) as? NameCell) ?? {
                    let c = NameCell()
                    c.identifier = reuse
                    return c
                }()
                configure(cell, column: colID, item: it)
                return cell
            }

            let cell = (v.makeView(withIdentifier: reuse, owner: nil) as? ValueCell) ?? {
                let c = ValueCell()
                c.identifier = reuse
                return c
            }()
            configure(cell, column: colID, item: it)
            return cell
        }

        private func configure(_ cell: NSTableCellView, column: String, item it: Item) {
            let tree = it.tree
            if column == "name" {
                let name = tree.name(it.id)
                cell.textField?.stringValue = name
                cell.imageView?.image = icon(for: name, isDir: tree.isDir(it.id))
            } else if column == "size" {
                cell.textField?.stringValue = Fmt.size(tree.alloc[it.id])
            } else {
                let parent = Int(tree.parents[it.id])
                let pAlloc = parent == Int(UInt32.max) ? tree.alloc[0] : tree.alloc[parent]
                let pct = pAlloc > 0 ? 100 * Double(tree.alloc[it.id]) / Double(pAlloc) : 0
                cell.textField?.stringValue = pct < 0.5 ? "–" : String(format: "%.0f%%", pct)
                cell.textField?.textColor = .tertiaryLabelColor
            }
        }


        /// Rows come and go as folders open and close, so a freshly revealed row
        /// needs its partial mark. Cheap: it only touches rows AppKit currently
        /// has on screen.
        func outlineView(_ v: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
            guard let partial = rowView as? PartialRowView, let tree, let model,
                  let item = v.item(atRow: row) as? Item else { return }
            partial.holdsPick = needsPartialMark(item, tree: tree, model: model)
        }

        /// Opening or closing a folder changes whether its hatch belongs, and no
        /// selection change fires — a collapse keeps the picks, by design — so
        /// the two disclosure notifications are the only signal that the mark is
        /// now stale.
        ///
        /// EXPANDING also has to put the selection back. AppKit restores the rows
        /// a collapse removed but NOT their selection, and it posts no
        /// `selectionDidChange` for the restore — so after a collapse/expand the
        /// rows came back unhighlighted and the picks looked lost, even though
        /// the model still held them. `syncHighlightFromModel` re-applies the
        /// model's own selection to the freshly revealed rows, which is the same
        /// path every other cross-view push uses.
        func outlineViewItemDidExpand(_ notification: Notification) {
            (notification.object as? NodeOutlineView)?.syncHighlightFromModel()
            refreshPartialRows()
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            refreshPartialRows()
        }



        /// What the user just did in this list, so a selection notification can
        /// be read for what it MEANS instead of being guessed from timing.
        ///
        /// Earlier attempts recognised a collapse from the notifications
        /// themselves: first "is some pick hidden?" (state, so it excused every
        /// later click), then a "collapse in flight" window drained on the next
        /// runloop turn (racy — AppKit posts a BURST for one collapse and the
        /// drain could land between them, losing the pick again). Both inferred
        /// intent from the symptom.
        ///
        /// The gesture is known exactly when it happens: a click in the
        /// disclosure triangle cannot be confused with a click on a row, because
        /// they are different rects. So the view declares it here and the handler
        /// reads it. No timing, no burst counting.
        enum ListGesture {
            /// A folder was opened or closed: what is selected is unchanged.
            case disclosure
            /// A plain click: replaces the whole selection.
            case replace
            /// Cmd+click or Shift+click: adds to the selection.
            case extend
            /// No gesture recorded (a programmatic change, or a selection made in
            /// another view): infer nothing, and keep what cannot be shown.
            case unknown
        }

        /// The gesture being handled, consumed by the next selection change.
        ///
        /// Single-use on purpose: a stale value must never excuse a later real
        /// click, which is how the first version of this went wrong.
        private var pendingGesture: ListGesture = .unknown

        /// Record what the user just did. Called by the view, which owns the
        /// click and so knows the answer for certain.
        func noteGesture(_ gesture: ListGesture) {
            pendingGesture = gesture
        }

        private func takeGesture() -> ListGesture {
            defer { pendingGesture = .unknown }
            return pendingGesture
        }

        func outlineViewSelectionDidChange(_ n: Notification) {
            // While a rescan runs the list still shows the old tree, hidden.
            guard let outline, let model, model.tree != nil, model.tree === tree else { return }
            // An echo of our own push, not a user gesture.
            if let list = outline as? NodeOutlineView, list.isSyncingFromModel { return }
            guard let list = outline as? NodeOutlineView else { return }

            // What the user just did, declared at the click. This is what makes
            // the handler correct without reasoning about AppKit's timing: a
            // disclosure click never means "deselect", and a plain click always
            // means "replace", whether or not a collapse happened first.
            let gesture = takeGesture()
            let rows = list.highlightedNodes
            let rendered = Set(list.renderedNodes())
            let hidden = model.picks.members.filter { !rendered.contains($0) }

            switch gesture {
            case .disclosure:
                // Opening or closing a folder changes nothing about WHAT is
                // selected. AppKit reports an empty row set here — the rows it hid
                // are gone — and reading that as a deselect is what lost the
                // selection inside a collapsed folder.
                return

            case .replace:
                // A plain click replaces the WHOLE selection, hidden picks
                // included: this is the gesture that must be able to clear a pick
                // inside a closed folder.
                model.setSelection(rows)

            case .extend:
                // Cmd+click / Shift+click adds. A pick with no row cannot be in
                // `rows`, so it is carried — otherwise extending would silently
                // discard what a collapsed folder is hiding.
                model.setSelection(hidden + rows, anchor: model.picks.primary)

            case .unknown:
                // Nothing was declared: assert only the rows the list can show,
                // and keep what it cannot. Guessing here is what made this area
                // fragile.
                let combined = hidden + rows
                if Set(combined) != Set(model.picks.members) {
                    model.setSelection(combined, anchor: model.picks.primary)
                }
            }
            list.syncHighlightFromModel()
        }

        /// Expand the ancestors of every picked node and highlight all their
        /// rows.
        ///
        /// Every member, not just the primary. This used to select the primary's
        /// row alone, and because `selectRowIndexes` fires the selection
        /// notification whose handler writes the row set back, the model
        /// collapsed to that one row on the next SwiftUI update — so a
        /// Cmd+click or Shift+range in the map or the rings survived only until
        /// the next redraw. The push also sets `isSyncingFromModel`, so its own
        /// echo is not mistaken for a user gesture.
        ///
        /// The rows must match the folder on screen before any row is looked up:
        /// a zoom (keyboard "up", a crumb) changes `viewRoot` and the reload
        /// only lands later in `updateNSView`.
        func syncSelection() {
            rebuildIfNeeded()
            guard let outline, let tree, let model else { return }
            let wanted = Set(model.picks.members)

            // A member with no row — a deep file under a collapsed folder, or
            // one outside the folder on screen — is left to the model rather
            // than dropped from it: the selection is shared across views on
            // purpose, and narrowing it to what this list happens to show would
            // silently discard the rest.
            var targets: [Item] = []
            for id in wanted where tree.isAttached(id) {
                if let item = revealRow(for: id, in: outline, tree: tree) { targets.append(item) }
            }
            // `revealRow` opens ancestors so a nested pick has a row at all.
            // That is right when the pick ARRIVES from another view, and wrong
            // on every later redraw: this runs from `updateNSView` whenever the
            // model changes, so it re-opened a folder the user had just
            // collapsed and the disclosure triangle looked broken. Expansion is
            // therefore driven by the picks themselves, in `picksDidChange`.
            // Highlight through the model's own push, so the row set it writes
            // and the echo suppression are the ones already proven to converge.
            let list = outline as? NodeOutlineView
            list?.isSyncingFromModel = true
            defer { list?.isSyncingFromModel = false }
            var rows = IndexSet()
            for item in targets {
                let row = outline.row(forItem: item)
                if row >= 0 { rows.insert(row) }
            }
            if rows != outline.selectedRowIndexes {
                outline.selectRowIndexes(rows, byExtendingSelection: false)
            }
            if rows.isEmpty, !wanted.isEmpty {
                // Every pick is off-screen here: clear the highlight rather than
                // leaving the previous rows blue.
                outline.deselectAll(nil)
            }
            if let first = rows.first { outline.scrollRowToVisible(first) }
            refreshPartialRows()
        }

        /// The item for `id`, when its ancestors are already open.
        ///
        /// Returns nil for a pick with no row: a file under a collapsed folder,
        /// or anything outside the folder on screen. It does NOT expand anything
        /// — see `syncSelection`; opening happens once per new pick in
        /// `picksDidChange`, so a collapsed folder stays collapsed.
        private func revealRow(for id: Int, in outline: NSOutlineView, tree: Tree) -> Item? {
            var chain: [Int] = []
            var cur = id
            while cur != viewRoot {
                if cur == Int(UInt32.max) { return nil } // outside this view root
                chain.append(cur)
                cur = Int(tree.parents[cur])
            }
            chain.reverse()
            var level = roots
            var target: Item?
            for node in chain {
                guard let it = level.first(where: { $0.id == node }) else { return nil }
                target = it
                level = it.children
            }
            return target
        }

        /// Open the ancestors of picks that arrived from OUTSIDE this list, and
        /// leave the user's own disclosure state alone.
        ///
        /// Called when the selection itself changes (a Cmd+A, a click in the map
        /// or the rings), not on every redraw. Two rules make collapsing usable:
        /// a folder is only opened when the pick is genuinely new, and a folder
        /// the user has collapsed is never re-opened by a redraw — only by a
        /// new pick landing inside it.
        func picksDidChange() {
            guard let outline, let tree, let model else { return }
            let current = Set(model.picks.members)
            guard current != lastSyncedPicks else { return }
            let added = current.subtracting(lastSyncedPicks)
            lastSyncedPicks = current
            guard !added.isEmpty else { return }
            for id in added where tree.isAttached(id) {
                expandAncestors(of: id, in: outline, tree: tree)
            }
        }

        /// Open every ancestor of `id` up to the folder on screen.
        private func expandAncestors(of id: Int, in outline: NSOutlineView, tree: Tree) {
            var chain: [Int] = []
            var cur = id
            while cur != viewRoot {
                if cur == Int(UInt32.max) { return }
                chain.append(cur)
                cur = Int(tree.parents[cur])
            }
            chain.reverse()
            var level = roots
            for node in chain.dropLast() {
                guard let it = level.first(where: { $0.id == node }) else { return }
                if !outline.isItemExpanded(it) { outline.expandItem(it) }
                level = it.children
            }
        }

        @objc func doubleClicked(_ sender: NSOutlineView) {
            guard let it = sender.item(atRow: sender.clickedRow) as? Item else { return }
            if it.tree.isDir(it.id) {
                // Through `navigate`, so the title path re-anchors here too.
                model?.navigate(to: it.id)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: it.tree.path(it.id))])
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NodeOutlineView()
        // Multi-selection is AppKit's: Cmd+click toggles a row, Shift+click
        // selects the visible range, and Cmd+A is handled in `keyDown`. The
        // delegate mirrors the resulting row set into the model, so the map and
        // the rings highlight the same items.
        outline.allowsMultipleSelection = true
        outline.style = .plain
        outline.rowSizeStyle = .default
        outline.usesAlternatingRowBackgroundColors = true
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 13
        outline.autoresizesOutlineColumn = false

        let name = NSTableColumn(identifier: .init("name"))
        name.title = String(localized: "Name")
        name.minWidth = 120
        let size = NSTableColumn(identifier: .init("size"))
        size.title = String(localized: "Size")
        size.width = 92; size.minWidth = 84; size.maxWidth = 116
        let pct = NSTableColumn(identifier: .init("pct"))
        pct.title = "%"
        pct.width = 34; pct.minWidth = 30; pct.maxWidth = 44

        outline.addTableColumn(name)
        outline.addTableColumn(size)
        outline.addTableColumn(pct)
        outline.outlineTableColumn = name
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let coord = context.coordinator
        coord.model = model
        coord.outline = outline
        outline.menuCoordinator = coord
        outline.dataSource = coord
        outline.delegate = coord
        outline.target = coord
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        coord.rebuildIfNeeded()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.rebuildIfNeeded()
        // Open ancestors for picks that just arrived (from the map, the rings or
        // Cmd+A) BEFORE highlighting, so a newly selected nested item gets a row.
        context.coordinator.picksDidChange()
        context.coordinator.syncSelection()
    }
}

/// The window title: the enclosing path down to what is picked, or to the
/// folder on screen when nothing is.
///
/// The path follows the *selection*, so picking a small tile — or a folder
/// header — still leaves every folder above it one click away in the crumbs.
/// Without that, going back up meant re-zooming the map or hunting for the
/// tile by hand.
///
/// Its own view on purpose: a selection change invalidates this alone, not
/// the whole window body (which owns the AppKit list and map).
private struct TitleCrumbs: View {
    let model: ScanModel

    var body: some View {
        if let tree = model.tree {
            crumbs(tree: tree)
        } else {
            Text(model.displayRootName)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 8)
        }
    }

    private func crumbs(tree: Tree) -> some View {
        // The chain is built by the model, which guarantees the folder on
        // screen and its ancestors are never the part that gets dropped.
        let path = model.crumbPath
        return HStack(spacing: 4) {
            if path.elidedAbove {
                Text("…").foregroundStyle(.tertiary)
                chevron
            }
            ForEach(path.nodes.indices, id: \.self) { i in
                if i > 0 { chevron }
                crumb(tree: tree, node: path.nodes[i], isLast: i == path.nodes.count - 1)
            }
            // The pick sits below the folder on screen and the depth cap
            // dropped the folders in between. Without this mark the trail read
            // as complete, so the last crumb looked like the file's own folder
            // rather than several levels above it.
            if path.elidedBelow {
                chevron
                Text("…").foregroundStyle(.tertiary)
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    private func crumb(tree: Tree, node: Int, isLast: Bool) -> some View {
        Button {
            // Every crumb is the same gesture: show that folder. A file has
            // no map of its own, so its crumb opens the folder holding it —
            // matching what double-clicking the file's tile does.
            if tree.isDir(node) {
                model.navigate(to: node)
            } else {
                let parent = Int(tree.parents[node])
                if parent != Int(UInt32.max) { model.navigate(to: parent) }
            }
        } label: {
            Text(node == 0 ? model.displayRootName : tree.name(node))
                .font(.system(.body, design: .rounded).weight(isLast ? .semibold : .regular))
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isLast ? .primary : .secondary)
        .help(tree.displayPath(node))
    }
}

private extension View {
    /// The breadcrumbs are the title; drop the duplicate window title.
    @ViewBuilder
    func hidingWindowTitle() -> some View {
        if #available(macOS 15, *) {
            toolbar(removing: .title)
        } else {
            navigationTitle("")
        }
    }
}

/// Mouse extra buttons drive the folder navigation.
///
/// `NSEvent.buttonNumber` is zero-indexed: 0 is the left button, 1 the right,
/// 2 the middle (wheel) click, then 3 and 4 the "back" and "forward" thumb
/// buttons on every mouse macOS treats this way (the same mapping Safari and
/// Finder use). The wheel click goes up to the parent folder, pairing with the
/// Parent Folder toolbar button; the thumb pair stays back/forward. They arrive
/// as left-side `otherMouseDown` events, so a local monitor sees them before
/// any view does — which is the point: the pointer can be over the map, the
/// rings, the list or the toolbar, and the gesture has to work from all of
/// them.
///
/// A monitor is the right owner rather than an override on each view: the app
/// builds one map, one rings view and one list, any of which can be under the
/// pointer, and the toolbar is AppKit's own view that the app never touches.
/// One window-scoped handler covers all of them and cannot be forgotten when a
/// surface is added.
private struct HistoryMouseButtons: NSViewRepresentable {
    let model: ScanModel

    func makeNSView(context: Context) -> NSView {
        // Zero-size: this view is never seen or pointed at, it only owns the
        // monitor's lifetime alongside the window.
        let view = NSView(frame: .zero)
        context.coordinator.attach()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.model = model
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        var model: ScanModel
        private var monitor: Any?

        init(model: ScanModel) { self.model = model }

        func attach() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
                guard let self else { return event }
                let moved: Bool
                switch event.buttonNumber {
                case 2: moved = model.goUp()
                case 3: moved = model.goBack()
                case 4: moved = model.goForward()
                // Any other extra button (a gaming button) is not a navigation
                // gesture: pass it on untouched.
                default: return event
                }
                // Swallowed only when it did something, so a click that cannot
                // navigate still reaches whatever is under the pointer.
                return moved ? nil : event
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
