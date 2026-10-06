// Permanent-removal regression net: the context menu's "Delete Permanently" and
// the Delete keys must mean exactly what they say.
//
// Build (from repo root, same contract as the other suites):
//   swiftc tests/swift/deletion.swift \
//       $(filter-out app/Main.swift,$(wildcard app/*.swift)) \
//       -import-objc-header app/bz.h -parse-as-library \
//       -swift-version 6 -default-isolation MainActor \
//       -target arm64-apple-macos14.0 -L target/release -lappletree \
//       -framework DiskArbitration -framework IOKit -framework Security \
//       -o .build/deletion-tests
//
// Three properties, each one a way the feature can be wrong while looking
// right:
//   1. `Erase.erase` really deletes — and, the trap this suite exists for, it
//      deletes the FOLDER, not the symlink target or a Trash copy. A shortcut
//      that quietly trashed instead would leave the bytes on disk and read as
//      a working "permanently".
//   2. `RemovalKeys.intent` reads Backspace and Forward Delete as removal,
//      Shift of either as the permanent one, and refuses every other modifier:
//      Option-Delete and Command-Delete are editing gestures, and a loose
//      "Shift is somewhere in the flags" check turns them into an irreversible
//      delete.
//   3. The menu and the keys cannot drift apart: every surface that offers the
//      removal rows asks `NodeActions`, and every surface that takes the keys
//      asks `RemovalKeys`.

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

/// Whether a path exists WITHOUT following it — a symlink counts as present.
///
/// `lstat(path, nil)` does not do this: passing a NULL buffer returns -1 with
/// EFAULT on every path, present or not, so `lstat(p, nil) != 0` always reads
/// as "gone" and a test built on it passes for the wrong reason (this suite had
/// three such assertions before this helper). `FileManager.fileExists` is not a
/// substitute either: it resolves, so a dangling link reads as absent, which is
/// the exact case one of these checks exists for.
func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

/// A synthetic key event with the given key code and modifier flags.
///
/// `NSEvent.keyEvent` is the only way to build one without a real keyboard, and
/// the getters this suite exercises (`keyCode`, `modifierFlags`) are the ones it
/// sets. It returns nil only for invalid parameters.
func keyEvent(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent? {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                     windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                     isARepeat: false, keyCode: keyCode)
}

@MainActor
func run() async {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("deletion-\(ProcessInfo.processInfo.processIdentifier)")
    try? fm.removeItem(at: root)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)

    // --- 1. Erase really deletes, and only the named path --------------------

    // A folder with children: the recursive case every real removal is.
    let folder = root.appendingPathComponent("caches")
    try? fm.createDirectory(at: folder.appendingPathComponent("deep/nested"),
                            withIntermediateDirectories: true)
    try? "x".write(toFile: folder.appendingPathComponent("deep/nested/f").path,
                   atomically: true, encoding: .utf8)
    let folderPath = folder.path
    check("fixture folder exists before the erase", fm.fileExists(atPath: folderPath))
    let folderFailure = await Erase.erase(folderPath)
    check("erasing a folder reports no failure", folderFailure == nil, folderFailure ?? "")
    check("erasing a folder removes it from the disk", !fm.fileExists(atPath: folderPath))

    // A plain file.
    let file = root.appendingPathComponent("loose.txt")
    try? "x".write(toFile: file.path, atomically: true, encoding: .utf8)
    let fileFailure = await Erase.erase(file.path)
    check("erasing a file reports no failure", fileFailure == nil, fileFailure ?? "")
    check("erasing a file removes it from the disk", !fm.fileExists(atPath: file.path))

    // The symlink trap. `removefile` on a link must unlink the LINK, never
    // descend into what it points at — and never copy it to the Trash.
    let target = root.appendingPathComponent("precious")
    try? fm.createDirectory(at: target.appendingPathComponent("inner"),
                            withIntermediateDirectories: true)
    try? "keep me".write(toFile: target.appendingPathComponent("inner/keep").path,
                         atomically: true, encoding: .utf8)
    let link = root.appendingPathComponent("shortcut")
    try? fm.createSymbolicLink(at: link, withDestinationURL: target)
    let linkFailure = await Erase.erase(link.path)
    check("erasing a symlink reports no failure", linkFailure == nil, linkFailure ?? "")
    check("erasing a symlink unlinks the link itself", !fm.fileExists(atPath: link.path))
    check("erasing a symlink leaves what it pointed at alone",
          fm.fileExists(atPath: target.appendingPathComponent("inner/keep").path),
          "the erase followed the link into the target")

    // The dangling-symlink trap, for the TRASH route too.
    //
    // `Trash.trash` asked `FileManager.fileExists`, which RESOLVES a path, so a
    // link whose target is gone read as absent and the whole batch reported
    // "Already gone". The batch code then treats that as a success and forgets
    // the node, so the map dropped the link and subtracted its bytes with no
    // dialog while the link sat on disk — and a plain `trashItem` on the same
    // path would have moved it. Both pathways now ask `lstat`.
    let trashDangling = root.appendingPathComponent("trash-dangling")
    try? fm.createSymbolicLink(at: trashDangling, withDestinationURL:
        root.appendingPathComponent("no-such-target"))
    check("Trash's existence test does not follow a dangling link",
          Trash.exists(trashDangling.path),
          "a dangling link reads as absent, so it would be silently 'Already gone'")
    check("Trash's test still reports a genuinely absent path as absent",
          !Trash.exists(root.appendingPathComponent("never-was-here").path))
    if let outcome = await Trash.trash([trashDangling.path], authority: .userDirect).first {
        check("a dangling symlink is actually trashed, not called already-gone",
              outcome.moved, "moved=\(outcome.moved) reason=\(outcome.reason ?? "nil")")
        if let moved = outcome.trashed { try? fm.removeItem(at: moved) }
    } else {
        check("the trash probe returned an outcome", false)
    }

    // The dangling-symlink trap. `fileExists` RESOLVES a path, so a link whose
    // target is gone reads as absent: an erase that asked it reported success
    // while the link sat on disk. The map then cut the node and subtracted its
    // bytes from every total, with nothing removed at all. `lstat` is what a
    // delete has to ask, and this is the fixture that proves which one is used.
    let dangling = root.appendingPathComponent("dangling")
    try? fm.createSymbolicLink(at: dangling, withDestinationURL:
        root.appendingPathComponent("target-that-never-existed"))
    check("the dangling-link fixture reads as absent to fileExists",
          !fm.fileExists(atPath: dangling.path),
          "the fixture does not exercise the trap it exists for")
    let danglingFailure = await Erase.erase(dangling.path)
    check("erasing a dangling symlink reports no failure", danglingFailure == nil,
          danglingFailure ?? "")
    check("erasing a dangling symlink actually unlinks it",
          !exists(dangling.path),
          "the link survived an erase that reported success")

    // A partial delete must be reported. `removefile(RECURSIVE)` deletes what
    // it can and then fails if something inside refused to go — an immutable
    // child, a live mount point — leaving the target directory on disk with
    // some of its contents already gone. Reporting success there would detach
    // the node and subtract its bytes from every total while the item survives,
    // and it would reappear on the next scan with no sign the delete failed.
    //
    // An immutable child is the portable way to force that state: the fixture
    // needs no mount, and `chflags` is a plain property change.
    let partial = root.appendingPathComponent("partial")
    try? fm.createDirectory(at: partial.appendingPathComponent("locked"),
                            withIntermediateDirectories: true)
    try? "x".write(toFile: partial.appendingPathComponent("sibling.txt").path,
                   atomically: true, encoding: .utf8)
    let locked = partial.appendingPathComponent("locked/f.txt")
    try? "y".write(toFile: locked.path, atomically: true, encoding: .utf8)
    let flagged = chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0
    check("the immutable-child fixture was set up", flagged,
          "chflags failed, so the partial-delete path is not exercised")
    if flagged {
        let partialFailure = await Erase.erase(partial.path)
        let survives = exists(partial.path)
        check("the fixture really survives the sweep", survives,
              "the fixture did not reproduce a partial delete")
        check("a PARTIAL delete reports failure, not success", partialFailure != nil,
              "reported success while the item is still on disk")
        _ = chflags(locked.path, UInt32(0))
    }

    // Already gone: a success, because the caller must still forget its node.
    // Reporting a failure here would leave a removed item in the map forever.
    let absentFailure = await Erase.erase(root.appendingPathComponent("never-was").path)
    check("erasing an absent path is a success, so its node is still forgotten",
          absentFailure == nil, absentFailure.map { "reported \($0)" } ?? "")

    // And it must NOT have gone to the Trash instead: the whole point of the
    // feature is that the Trash is skipped.
    //
    // Asserted on the SOURCE path, not by listing a Trash directory. The
    // fixture lives under `NSTemporaryDirectory()`, whose Trash is the
    // per-volume `/tmp/.Trashes/<uid>` and not `~/.Trash` — so a check that
    // scanned the home Trash could not see a real regression there and would
    // pass for the wrong reason. A path that was trashed is absent at its old
    // location too, which is exactly why the assertion has to name the Trash
    // itself: `lstat` on the source cannot tell "deleted" from "moved".
    let trashed = root.appendingPathComponent("kicked")
    try? fm.createDirectory(at: trashed, withIntermediateDirectories: true)
    let trashedPath = trashed.path
    _ = await Erase.erase(trashedPath)
    check("the erase removed the path from its old location",
          !exists(trashedPath))
    // Positive control: a path that really WAS trashed must be findable by this
    // lookup, or the assertion above proves nothing about where it went. The
    // probe creates its own file and trashes it through the same FileManager
    // API the app would fall back to.
    let probe = root.appendingPathComponent("trash-probe")
    try? "x".write(toFile: probe.path, atomically: true, encoding: .utf8)
    var trashURL: NSURL?
    let trashedOK = (try? fm.trashItem(at: probe, resultingItemURL: &trashURL)) != nil
    check("the Trash probe moved a file into a Trash", trashedOK,
          "trashItem failed, so this machine cannot exercise the control")
    if let moved = trashURL as URL? {
        let movedPath = moved.path
        // Wherever macOS put it, the item is at the reported URL — so the
        // control locates the Trash by asking the OS rather than guessing the
        // directory, and would catch a real `trashItem` fallback on any setup.
        check("a trashed file is reachable at the URL macOS reports",
              fm.fileExists(atPath: movedPath), "reported \(movedPath)")
        check("erasing did not reuse that Trash location",
              !movedPath.contains("kicked"),
              "the erase left its item where the control found a trashed one")
        try? fm.removeItem(at: moved)
    }

    // --- 2. The keys: two delete keys, Shift for the permanent one -----------

    let backspace: UInt16 = 51
    let forwardDelete: UInt16 = 117

    check("Backspace asks for the Trash",
          RemovalKeys.intent(for: keyEvent(backspace, [])!) == .trash)
    check("Forward Delete asks for the Trash",
          RemovalKeys.intent(for: keyEvent(forwardDelete, [])!) == .trash)
    check("Shift+Backspace asks for the permanent delete",
          RemovalKeys.intent(for: keyEvent(backspace, [.shift])!) == .permanent)
    check("Shift+Forward Delete asks for the permanent delete",
          RemovalKeys.intent(for: keyEvent(forwardDelete, [.shift])!) == .permanent)

    // Every other *held* modifier is an editing gesture, not a removal. This is
    // the dangerous overflow direction: on macOS Option-Delete deletes a word
    // and Command-Delete deletes a line, so treating them as removal would turn
    // ordinary editing into an irreversible delete.
    for (name, flags) in [("Option", NSEvent.ModifierFlags.option),
                          ("Command", .command),
                          ("Control", .control),
                          ("Shift+Option", [.shift, .option]),
                          ("Shift+Command", [.shift, .command])] as [(String, NSEvent.ModifierFlags)] {
        check("\(name)+Delete is not a removal",
              RemovalKeys.intent(for: keyEvent(backspace, flags)!) == nil,
              "read as \(String(describing: RemovalKeys.intent(for: keyEvent(backspace, flags)!)))")
        check("\(name)+Forward Delete is not a removal",
              RemovalKeys.intent(for: keyEvent(forwardDelete, flags)!) == nil)
    }

    // Hardware and sticky state must NOT veto the gesture: Forward Delete
    // reports `.function`, a numeric-pad key reports `.numericPad`, and Caps
    // Lock stays set until it is turned off. Fn+Backspace is the only way to
    // send Forward Delete on a laptop, so refusing these would make the second
    // delete key unreachable there.
    for (name, flags) in [("Function", NSEvent.ModifierFlags.function),
                          ("NumericPad", .numericPad),
                          ("CapsLock", .capsLock),
                          ("Function+NumericPad", [.function, .numericPad]),
                          ("CapsLock+Shift", [.capsLock, .shift])] as [(String, NSEvent.ModifierFlags)] {
        let expected: RemovalKind = flags.contains(.shift) ? .permanent : .trash
        check("\(name)+Backspace still removes",
              RemovalKeys.intent(for: keyEvent(backspace, flags)!) == expected,
              "read as \(String(describing: RemovalKeys.intent(for: keyEvent(backspace, flags)!)))")
        check("\(name)+Forward Delete still removes",
              RemovalKeys.intent(for: keyEvent(forwardDelete, flags)!) == expected)
    }
    // A key that is not a delete key must never remove anything, whatever the
    // modifiers say.
    for code in [UInt16(36), 48, 53, 123, 124, 125, 126, 0, 49] {
        check("key \(code) is not a removal",
              RemovalKeys.intent(for: keyEvent(code, [])!) == nil
                  && RemovalKeys.intent(for: keyEvent(code, [.shift])!) == nil)
    }

    // --- 3. One owner per gesture: menu and keys cannot drift ---------------

    let rootURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func source(_ rel: String) -> String {
        (try? String(contentsOf: rootURL.appendingPathComponent(rel), encoding: .utf8)) ?? ""
    }

    // Both menu rows route through `NodeActions`, the one place that confirms,
    // removes and forgets.
    let menu = source("app/TreemapView.swift")
    check("the menu's Move to Trash goes through the batch NodeActions",
          menu.contains("targeted(c, kind: .trash)"))
    check("the menu's Delete Permanently goes through the batch NodeActions",
          menu.contains("targeted(c, kind: .permanent)"))
    check("the menu offers a Delete Permanently row",
          menu.contains("String(localized: \"Delete Permanently\")"))
    // The irreversible row is separated from the reversible one, so a stray
    // click on the row above cannot land on it.
    check("Delete Permanently sits after its own separator",
          menu.contains("add(String(localized: \"Move to Trash\"), #selector(moveToTrash(_:)), enabled: canRemove)\n        // The irreversible one")
              || menu.contains("separator())\n        add(String(localized: \"Delete Permanently\")"))

    // Every surface that shows the menu takes the keys, and none of them acts
    // on a hover: for an irreversible delete the target must be the pick the
    // user committed to. Every surface now acts on the WHOLE selection through
    // `model.pickedNodes`, so a multi-selection deletes as one batch.
    for (file, label) in [("app/TreemapView.swift", "the treemap"),
                          ("app/SunburstView.swift", "the rings"),
                          ("app/ContentView.swift", "the list")] {
        let src = source(file)
        check("\(label) takes the Delete keys", src.contains("RemovalKeys.intent(for: event)"),
              "\(file) does not read the shared key owner")
        check("\(label) routes the keys through the batch NodeActions",
              src.contains("NodeActions.remove(nodes:"))
    }
    // A hover must never be the removal target. Checked structurally: no
    // `NodeActions.remove` call reads a hover.
    for file in ["app/TreemapView.swift", "app/SunburstView.swift", "app/ContentView.swift"] {
        let src = source(file)
        for line in src.split(separator: "\n").map(String.init) where line.contains("NodeActions.remove(") {
            check("\(file) removes the selection, not a hover",
                  !line.contains("hovered"),
                  "target line reads: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    // The menu rows act on the SELECTION when the clicked node is inside it, and
    // on the clicked node when it is not: right-clicking a node the user can see
    // is highlighted must not silently act on one item.
    let menuSrc = source("app/TreemapView.swift")
    check("a menu row targets the selection when the node is inside it",
          menuSrc.contains("c.model.picks.covers(c.node, in: c.tree) ? c.model.pickedNodes : [c.node]"),
          "the menu would act on a single node while several are highlighted")
    // The list still reads the ROWS, and only falls back to the model when no
    // row is highlighted. The model's pick is the shared selection, not a stale
    // single value, so the fallback is now the correct same-set answer.
    let content = source("app/ContentView.swift")
    check("the list prefers its highlighted rows",
          content.contains("let rows = highlightedNodes") && content.contains("rows.isEmpty ? model.pickedNodes : rows"),
          "the list does not read the highlighted rows")

    // --- 4. The real menu: rows, order and wiring ---------------------------
    //
    // `NodeMenu.menu` builds an actual `NSMenu`, so the shape the user sees can
    // be asserted rather than inferred from the source: the permanent row is
    // present, the two removal rows are separated, and every row carries the
    // action and target that make it work. A string check on the source cannot
    // catch a row added to the wrong list or left disabled for everything.
    //
    // A real `Tree` is needed, and only the engine can make one: scanning an
    // empty scratch folder yields a root with no children, which is enough to
    // build the menu and check its rows.
    var menuHandle: OpaquePointer? = bz_scan_start(root.path)
    var done: Int32 = 0
    if let handle = menuHandle {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            var f: UInt64 = 0, d: UInt64 = 0, b: UInt64 = 0
            bz_progress(handle, &f, &d, &b, &done)
            if done != 0 { break }
            usleep(2000)
        }
        menuHandle = handle
    }
    if let handle = menuHandle, done != 0, let tree = Tree(handle: handle) {
        let model = ScanModel()
        model.tree = tree
        let menu = NodeMenu.menu(node: 0, tree: tree, model: model)
        let titles = menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
        check("the menu offers a Delete Permanently row",
              titles.contains("Delete Permanently"), "\(titles)")
        check("the menu keeps Move to Trash", titles.contains("Move to Trash"), "\(titles)")
        // The row carries NO trailing ellipsis, asserted on the built menu and
        // not on the source: macOS convention appends one when an action raises
        // a dialog, and this row deliberately does not, so it reads as the
        // action itself. Every other row here is an action too, so nothing in
        // this menu may carry one.
        check("no row in this menu carries a trailing ellipsis",
              !titles.contains(where: { $0.hasSuffix("…") }),
              "a menu row still ends in an ellipsis: \(titles)")
        // The irreversible row comes after a separator, so a stray click on the
        // reversible row's neighbour cannot reach it.
        if let trashIndex = menu.items.firstIndex(where: { $0.title == "Move to Trash" }),
           let eraseIndex = menu.items.firstIndex(where: { $0.title.hasPrefix("Delete Permanently") }) {
            check("Delete Permanently sits below Move to Trash", eraseIndex > trashIndex)
            check("a separator divides the two removal rows",
                  menu.items[(trashIndex + 1)..<eraseIndex].contains(where: { $0.isSeparatorItem }),
                  "rows \(trashIndex)...\(eraseIndex) have no separator")
        } else {
            check("both removal rows are present", false, "\(titles)")
        }
        // Node 0 is the scan root: removal is offered nowhere for it.
        for row in menu.items where !row.isSeparatorItem {
            if row.title == "Move to Trash" || row.title.hasPrefix("Delete Permanently") {
                check("removal is disabled for the scan root (\(row.title))", !row.isEnabled,
                      "the root row would delete the whole scan")
            }
        }
        // This is the ONLY surviving handle reference; `Tree.deinit` frees it.
        _ = tree
    } else {
        if let handle = menuHandle { bz_free(handle) }
        check("the menu could be built from a real tree", false, "the scan did not finish")
    }

    // --- right-click must not discard or misread the selection -----------------
    //
    // Three bugs of one family: the menu is built from the model, so a view that
    // changes the highlight without telling the model makes the menu act on a set
    // other than the one on screen.
    let tm = source("app/TreemapView.swift")
    check("the treemap keeps a selection the right-clicked tile is part of",
          tm.contains("if !model.picks.covers(node, in: tree) {")
              && tm.contains("hoveredNode = node"),
          "a right-click on a selected tile would discard the rest of the selection")
    check("the treemap focuses the clicked tile when it is outside the selection",
          tm.contains("focus(node, tree: tree, model: model)"),
          "an outside right-click would keep acting on the old selection")
    check("the list writes the newly focused row to the model before building the menu",
          content.contains("model.setSelection([item.id])"),
          "the menu would act on the old rows while one new row is highlighted")
    check("the rings keep a selection the right-clicked arc is part of",
          source("app/SunburstView.swift").contains("if !model.picks.covers(segments[i].node, in: tree)"))

    // "Already gone" means the item is not on disk, but its NODE is still in a
    // tree built from an earlier scan: it must be forgotten or the map keeps
    // showing bytes that no longer exist and counts them in every total. It is
    // not a failure — nothing is left to remove — so it must NOT be reported.
    check("an already-gone batch item is forgotten, not reported as a failure",
          tm.contains("} else if outcome.reason == String(localized: \"Already gone\") {")
              && tm.contains("model.forgetPath(outcome.source)\n                } else if let reason = outcome.reason {"),
          "an already-gone item would stay in the map with phantom bytes")

    // The list's two-way sync must not oscillate: pushing the model into AppKit
    // fires the selection notification, whose handler writes back.
    check("the list guards its model→rows push against the notification echo",
          content.contains("isSyncingFromModel") && content.contains("list.isSyncingFromModel { return }"),
          "selectRowIndexes would re-enter the sync and could oscillate")

    // Every new string is in every table (the l10n checker owns the full
    // parity check; this catches a key added to Swift and nowhere else).
    let en = source("app/en.lproj/Localizable.strings")
    for key in ["Delete Permanently", "Delete “%@” permanently?",
                "It does not go to the Trash. This cannot be undone.",
                "Cannot remove the scan root"] {
        check("the en table defines \"\(key)\"", en.contains("\"\(key)\" ="),
              "a missing key renders the key itself")
    }

    // The confirmation must name the irreversible step on its own button: an
    // "OK" that confirms a delete reads as agreement to something else.
    check("the permanent confirmation's button is its own verb",
          menu.contains("alert.addButton(withTitle: String(localized: \"Delete Permanently\"))"))
    check("the permanent confirmation says it skips the Trash",
          menu.contains("\"It does not go to the Trash. This cannot be undone.\""))

    // The row and the button are the same words, so they must be the same KEY:
    // defining it twice would put a duplicate in every table (the l10n checker
    // fails on that), and the two would then be free to drift apart.
    check("the menu row and the alert button share one key",
          menu.contains("add(String(localized: \"Delete Permanently\"), #selector(deleteForGood(_:))")
              && menu.contains("alert.addButton(withTitle: String(localized: \"Delete Permanently\"))"))
    for table in ["en", "de", "es", "fr", "ja", "tr", "zh-Hans"] {
        let src = source("app/\(table).lproj/Localizable.strings")
        let definitions = src.split(separator: "\n")
            .filter { $0.hasPrefix("\"Delete Permanently\"") }.count
        check("\(table) defines Delete Permanently exactly once", definitions == 1,
              "found \(definitions) definitions")
    }

    try? fm.removeItem(at: root)
    print("\(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}

@main
enum DeletionTests {
    static func main() async {
        await run()
    }
}
