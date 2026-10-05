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
            await model.refreshAgents()
            model.openPanelAfterLaunchScan()
        }
        // A drive plugged in or ejected while the window is open: keep the
        // scan pickers (toolbar menu and idle overlay) in step with the Mac.
        .onReceive(NotificationCenter.default.publisher(
            for: NSWorkspace.didMountNotification)) { _ in model.refreshDrives() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWorkspace.didUnmountNotification)) { _ in model.refreshDrives() }
        // An agent run or the setup offer always shows in the panel.
        .onChange(of: model.agentRun == nil) { if model.agentRun != nil { showCleanup = true } }
        .onChange(of: model.panelRequests) { showCleanup = true }
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
        guard target == ScanTargets.macintoshHD.path, !FDA.isActive() else {
            model.startScan(path: path)
            return
        }
        pendingScanPath = path
        needsFDA = true
    }

    private var fdaOverlay: some View {
        // Top-anchored like the window's other states: dead-center made the
        // permission card float in the middle of an empty scan area.
        VStack(alignment: .leading, spacing: 14) {
            Label("AppleTree needs Full Disk Access", systemImage: "lock.shield")
                .font(.title3.weight(.semibold))
            Text("System Settings → Privacy & Security → Full Disk Access.\nRemove any old AppleTree rows, then add /Applications/AppleTree.app.\nmacOS only applies the permission to a freshly launched app.")
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
            .help("Treemap (WizTree-style) or rings (DaisyDisk-style)")
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

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            requestScan(path: url.path)
        }
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
                        if FDA.isActive() {
                            // Root-owned system dirs: unreadable by design,
                            // not a permissions problem the user can fix.
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

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let coordinator = menuCoordinator, let model = coordinator.model,
              let tree = model.tree else { return nil }
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let item = self.item(atRow: row) as? OutlinePanel.Item else { return nil }
        // Right-clicking a row also focuses it, so the menu's actions and the
        // list's highlight cannot disagree about which item was meant.
        if self.selectedRow != row {
            self.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return NodeMenu.menu(node: item.id, tree: tree, model: model)
    }

    /// Cmd-Up climbs out of the selection, matching the map and the rings.
    /// A selected file's enclosing folder is then revealed as a row here, so
    /// every surface offers the same way up. Everything else stays AppKit's.
    override func keyDown(with event: NSEvent) {
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
                let selectedID = reuseRows ? nil : selectedItem?.id
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
                    restore(open: openIDs, selected: selectedID)
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

        /// The item the outline currently has selected, if any.
        ///
        /// `row(forItem:)`/`item(atRow:)` is used rather than indexing `roots`,
        /// because a selection is usually a child several levels deep inside an
        /// expanded parent.
        private var selectedItem: Item? {
            guard let outline, outline.selectedRow >= 0 else { return nil }
            return outline.item(atRow: outline.selectedRow) as? Item
        }

        /// Re-open each remembered id (parents before children) and restore the
        /// selected row. Ids absent from the new tree are skipped, so this needs
        /// no knowledge of what was removed.
        private func restore(open: [Int], selected: Int?) {
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
            if let selected, let match = find(selected) {
                let row = outline.row(forItem: match)
                if row >= 0 {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                }
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

        func outlineViewSelectionDidChange(_ n: Notification) {
            // While a rescan runs the list still shows the old tree, hidden.
            guard let outline, let model, model.tree != nil, model.tree === tree else { return }
            if let it = outline.item(atRow: outline.selectedRow) as? Item {
                model.selection = it.id
            }
        }

        /// Treemap click → expand ancestors, select and reveal the row here.
        func syncSelection() {
            // The roots must match the folder on screen before any row is
            // looked up: a zoom (keyboard "up", a crumb) changes `viewRoot`
            // and the reload only lands later in `updateNSView`.
            rebuildIfNeeded()
            guard let outline, let tree, let sel = model?.selection else { return }
            if let cur = outline.item(atRow: outline.selectedRow) as? Item, cur.id == sel { return }

            var chain: [Int] = []
            var cur = sel
            while cur != viewRoot {
                if cur == Int(UInt32.max) { return } // outside current view root
                chain.append(cur)
                cur = Int(tree.parents[cur])
            }
            chain.reverse()

            var level = roots
            var target: Item?
            for id in chain {
                guard let it = level.first(where: { $0.id == id }) else { return }
                target = it
                if id != chain.last {
                    outline.expandItem(it)
                    level = it.children
                }
            }
            if let target {
                let row = outline.row(forItem: target)
                if row >= 0 {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                }
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
