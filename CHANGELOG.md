# Changelog

## 2.0.0 — 2026-11-07

**The app is renamed SmartTree, and it ships as a new App Store record.**

Apple rejected 1.1.3 under Guideline 5.2.5 a second time, naming the app's
metadata and the trademark it embeds. `AppleTree` is a coined word, but it
contains "Apple", which Apple's trademark policy refuses in a product name
outright — *"do not make up names that contain Apple trademarks."* The
first-round argument was made once and was not accepted, so the name changes
rather than being argued a third time.

**New identity, top to bottom.** `SmartTree` replaces `AppleTree` everywhere:
the display name, the window title, the About panel, the Help menu, the
executable, the bundled README, license and privacy policy filenames' prose,
the localized strings in all seven languages, the Rust crate and its CLI
binary, the benchmark harness, the README, the wiki pages and the GitHub
issue templates. 976 occurrences across 96 files.

One thing the rename broke and this release fixes: French elides its article
before a vowel, which `AppleTree` required and `SmartTree` does not. Seven
strings came out of the mechanical replacement as "d'SmartTree" and
"qu'SmartTree"; they now read "de SmartTree" and "que SmartTree".

**New bundle identifier: `com.erklab.apps.smarttree`.** This is a new App
Store record — the old one is abandoned with no buyers. Everything keyed to
the old ID moves with it: the preferences domain, the Keychain service prefix
for stored model-provider API keys, the security-scoped bookmark entitlement
comment, the sandbox rehearsal bundle name, and the provisioning-profile
reference in the Makefile.

**Version 2.0.0** is the marketing version and is what App Store Connect will
show. It is not 1.1.4 because the bundle identifier, the record and the
product name all change; there is no upgrade path from 1.1.x, and pretending
otherwise in the version number would misdescribe it.

**The App Store listing ID is a placeholder.** `https://apps.apple.com/app/id0000000000`
sits in `AppMenu.swift`, `README.md` and the two wiki pages, because the real
ID does not exist until the new record is created in App Store Connect. Fill it
in with `sed` once Apple issues it — the one file to change is listed in
`docs/appstore/smarttree-resubmission.md`.



**Browsing and bulk delete stop re-doing work they just finished.** Four
independent causes, all in the UI layer; the scan engine is unchanged.

*Coming back to a folder is instant.* The map re-rendered from scratch on every
folder change, including the one you had just left. `renderBitmap` is a pure
function of the tree, the folder, the tree revision, the pixel size and the free
-space setting, so its whole payload — geometry and bitmap — is now memoised. The
budget is 128 MiB, bounded in bytes rather than entries because one entry
measures 26 MiB at 1000×700 pt and 117 MiB at 2400×1600. Measured on a 1.82M-node
home scan: the return leg of root → subfolder → root went from **2,909 ms to
0.1 ms**.

*The list no longer indexes the whole disk to show one folder.* Its data source
materialised every node below the visible folder into a dictionary on every
rebuild — 1.82M objects, ~152 MB, 1.24 s — to populate 74 rows. Only the visible
rows are indexed now and the rest are filled in lazily as folders open, with the
lazy walk bounded to rows that actually exist (a collapsed row's children cannot
be the answer, and materialising them was the cost). Rebuild: **2,040 ms → 0.4
ms**.

*Deleting a batch refreshes once, not once per item.* Both removal routes forgot
each item individually, and because each delete is awaited the map, the rings and
the list rebuilt between one item and the next. `forgetPaths` cuts every link and
then invalidates once. A 12-item batch: **111 ms and 12 revisions → 24 ms and 1**.

*A finished cleanup no longer rescans the disk.* Moving ticked rows to the Trash
used to answer with a full walk (~12.5 s here), which also renumbered every node
and discarded the zoom and selection. The panel now forgets what really left, in
place. A planner run still rescans, but only when it included a tool-command card
— `npm cache clean` empties a cache folder the tree still holds, and only a walk
can re-measure that.

Also fixed while there: the partial-selection hatch (the mark on a collapsed
folder holding a pick) walked every pick's ancestry once per visible row —
**96.5 ms per row**, so seconds per screenful with a large selection. It is one
derived set now: 25 rows measured **2,412 ms → 114 ms**, and a warm redraw 0.07
ms. And the finished-cleanup line no longer claims "Rescanned.", which stopped
being true.

**Then the list itself: focus, scroll, and the per-expand cost.** Everything below
is the same theme — work repeated per row or per item that had one answer already —
plus the interaction bugs that made the list feel like it lost the user's place.

*Coming back to a folder keeps your focus, and your scroll.* Two separate losses.
The selection was cleared on every folder change and never restored, so entering a
folder, picking something, stepping out and returning dropped the highlight;
`ScanModel` now remembers what was focused in each folder by path (a node id means
nothing after a rescan), with an empty selection remembered as empty so a folder
left with nothing focused cannot resurrect an old pick. And the reload that every
folder change performs shifted the rows it re-inserted above the viewport, so the
list jumped for a frame: measured 200 pt of movement deleting one row in a folder
with 36 folders open, now anchored to the row that was at the top of the viewport
instead. Focus also lands a third of the way down the list rather than flush against
the bottom edge, and selecting a row that is already visible no longer scrolls the
list at all — measured `scrollY` 598 → 598.

*A delete focuses the row that took the removed one's place.* Focusing the parent
kept the highlight on the folder already on screen, which in a long list means the
eye has to find its place again. The next sibling now takes the highlight, falling
back to the previous one at the end of a list, to the parent when there is no
sibling, and never to a node the same batch removed. A partly-deleted selection
keeps its survivors rather than being replaced.

*Revealing a nested pick and restoring an open folder set are each ONE update pass.*
Every `expandItem` separately runs AppKit's row bookkeeping
(`-[NSTableRowData endUpdates]` → `_updateVisibleViewsBasedOnUpdateItems` →
`_preparedRowViewForRow`), re-walking the row set each time. Focusing
`…/node_modules/prettier-linter-helpers` therefore paid it once per ancestor —
**449 ms → 59 ms** end to end — and returning to a folder re-opened every folder the
user had expanded one at a time: a round trip back to `/` with 40 folders open
(1,777 rows) went **217 ms → 45 ms**.

*Resizing the window no longer re-renders the map per drag step.* Both render
caches are keyed by pixel size, so every intermediate width of a drag was a
guaranteed miss and there was no debounce anywhere: a 40-step drag cost **49.5 s**
in the treemap. Both views now lay out at the last rendered size while a drag is in
progress and render once when it ends — the same drag is **1 ms with zero renders,
then exactly one render on settle**, asserted to match the final window size.

*The ring view caches what it draws.* The treemap had a render cache; the rings had
none, so every folder change re-derived the whole arc layout and repainted. Measured
on a 2.97M-node scan, three round trips: treemap 0 ms (cached) against rings
**82–90 ms for every trip**, now **1 ms**. A cached return is verified byte-identical
to a fresh render on both the arc geometry and the raw pixels, and `treeRevision` is
part of the key so a delete is never served stale.

*The render cache no longer evicts the folder you are about to return to.* Pure LRU
dropped the scan root first, because it is the first folder you leave and therefore
the least recently used — after a ten-folder session the next return to it was a
**1,042 ms re-render**. Eviction is now tiered: the root and its direct children are
evicted last, everything deeper is ordinary LRU, and the protected entries are still
evicted if they alone exceed the budget.

*The breadcrumb shows every folder, and shortens only what a tool made long.* The
title dropped the scan root to make room; it keeps it now and elides in the middle
instead. Names a package manager generated (`zod@4.4.3`,
`…_76bc68c0ac7ac91512ade9464ffbf90a`) are shortened at the version or digest, while
ordinary names are returned byte-identical.

*A big delete says it is working.* Deleting a large folder did not update anything
until it finished, which reads as a dead app; the status bar now reports progress
and the size in flight. Deleting the folder you are inside steps out one level
rather than to the scan root, and a delete whose row disappears no longer jumps the
list. Clicking a Clean Up row keeps your place in the list.

## 1.1.2 — 2026-10-08


**The duplicate privacy policy is gone.** `docs/appstore/privacy-policy.md` was an
untracked second copy of the policy, referenced by nothing: the app reads
`Contents/Resources/PrivacyPolicy.md`, which `make build` copies from
`docs/wiki/Privacy-Policy.md`. It had drifted 95 lines from that source — missing
the entire section on the Mac App Store build and claiming Full Disk Access is
required to scan, which is false for the sandboxed build — and being gitignored
meant no diff and no test could see it. One policy now, at
`docs/wiki/Privacy-Policy.md`. `docs/appstore/app-store-metadata.md` remains, as
the submission notes the Makefile points at.

The policy's §5.2 also now lists the field the planner actually receives: the
owning tool's name beside the cache's kind, which 1.1.0 began sending.

## 1.1.1 — 2026-10-08

**A rebuilt package can be uploaded again.** `CFBundleVersion` and
`CFBundleShortVersionString` were both pinned to the marketing version, so every
re-upload of one version was a duplicate: App Store Connect requires the build
number to be unique per version and to increase. A second 1.1.0 delivery was
rejected for exactly that reason. The build number is now its own value, defaulting
to a UTC timestamp to the second, so `make pkg` twice in a row produces two
distinct, increasing builds. Override with `make pkg APP_BUILD=42`.

Export compliance is now declared in `Info.plist`
(`ITSAppUsesNonExemptEncryption = false`), so App Store Connect stops asking the
App Encryption Documentation question on every submission. Verified the app
implements no cryptography of its own — no CryptoKit or CommonCrypto, no crypto
crate in `Cargo.toml`, no custom trust evaluation — and uses only the
operating system's HTTPS and Keychain, which is the mass-market exemption.

## 1.1.0 — 2026-10-08

**The scan no longer comes back short.** A file descriptor was leaked for every
directory visited — 1,012,423 of them on a whole-disk walk — until the process
hit its limit. A GUI app is allowed 256 descriptors (`launchctl limit maxfiles`)
while a shell gets 1,048,575, so the app died partway through a scan and reported
whatever it had reached when allocations started failing: **a different total
every time**, anywhere from 17 GB to 158 GB. Measured on a 245 GB Mac, the same
whole-disk scan now reports 157.98 GB with 750 unreadable folders, stable across
runs, and holds 9 descriptors instead of 254.

Cleanup works in the App Store build. The blocker was never only the shell: a
sandboxed app cannot reach the user's caches by *file access* either, so the
command path was half the problem.

**Cleanup recognises caches by structure, not by name.** The engine matched
folder names, so `~/Library/pnpm/store` — 4.0 GB on the machine this was
measured on — and `~/Library/Caches/Homebrew` (689 MB) were never offered: it did
not know the words `store` or `Homebrew`. A tool cache is now found by the tool's
own fixed location *plus* the structure that tool creates, across eight rows:
`~/.cache/uv` and `~/.cargo/registry` (`CACHEDIR.TAG`), `~/.cargo/git/db`
(`*/FETCH_HEAD`), `~/Library/pnpm/store` (`v*/files` **and** `v*/index.db`),
`~/Library/Caches/pip` (`http-v2`, or `http/` before 2020),
`~/Library/Caches/Homebrew` (`api`), `~/Library/Caches/CocoaPods` (`Pods`) and
`~/Library/Caches/org.swift.swiftpm` (`manifests`). A folder that merely resembles
a cache is still not proposed. `~/.npm` keeps its existing name-based rule, so no
npm row is added: `find` never descends into a recognised folder, and a row for
`~/.npm/_cacache` could therefore never be consulted. A row is added only when its
marker was observed on a real machine; a row that could not be confirmed is left
out rather than guessed.

**A folder scan now finds the caches inside it.** Scanning one folder — the
panel's own "choose a folder" — found nothing at all before: the rules were
home-relative and a scan rooted below the home had no home ancestor to measure
from. Selecting `~/Library/Caches` offered neither pip nor Homebrew even though a
home scan offered both. The location test is now anchored to the home boundary,
so a home, whole-disk and folder scan agree, while a scan outside your home still
never offers your caches.

**The App Store build can actually clean.** Two changes that only work together.
A file-access grant lets a sandboxed SmartTree enumerate, write, Trash and delete
a cache folder — measured on a bundle signed with the shipping entitlements. And
`AppEnvironment` becomes the single owner of "where is home": `NSHomeDirectory()`
is the container's `Data` directory under the sandbox, so the guard was refusing
every real cache as "Outside your home folder" and the "Home" scan target scanned
an empty container. The grant alone would have fixed nothing.

**The sandboxed build reaches your whole disk through one folder you pick.** It
cannot read `/Users`, `/private/var` or `/opt` on any entitlement, and Full Disk
Access does not lift App Sandbox — measured with the same bundle identifier and
signing identity, the unsandboxed build read `~/Library/Messages` while the
sandboxed one was denied, with the grant logged by the system. So `Macintosh HD`
(or Home) now asks you to choose the folder once; the choice is stored as a
security-scoped bookmark and later scans need no prompt. Measured, that one
choice covers the entire disk.

Because of that, the **home-relative temporary exception is retired**: the
bookmark route subsumes it, it never covered the whole disk anyway, and removing
it drops the item-by-item justification from App Store review. The sandboxed
build now carries only Apple's sanctioned keys.

**The sandboxed build no longer offers commands it cannot run.** The planner was
shown all the allowlisted cleanup commands regardless of build, so in the App
Store build it proposed "command" cards that silently did nothing — the panel
reported success while the bytes stayed on disk. The prompt is now told the
sandbox forbids a command and asks only for folders.

**Five cleanup commands were retired** because a folder now carries them:
`uv cache clean`, `bun pm cache rm`, `pip cache purge`, `pip3 cache purge` and
`pod cache clean --all`. Each one's target *is* the tool's own cache directory
(measured for uv: it empties `uv cache dir` entirely), so the command was just
another way to need `exec`. The forms a folder cannot express stay: `npm cache
clean` (npm's folder also holds `_npx` and `_logs`), `yarn cache clean`,
`uv cache prune` and `pnpm store prune` (both remove only unreferenced entries),
and the `brew`/`gem`/`go`/`conda`/`docker`/`xcrun simctl` forms.

**The Clean Up panel says which tool a cache belongs to.** The JSON CLI's
candidate objects gain an additive `tool` field (`"pnpm"`, `"Homebrew"`,
`"Cargo"`, …) beside the unchanged `category`, and the panel row and the planner
prompt now name the tool too instead of only "Caches, rebuilt or re-downloaded
when needed". `category` keeps reporting `tool_caches` for every row, so an
existing consumer of that key is unaffected; a consumer that asserts an exact
candidate key-set would need updating, and none in-repo does.

### Fixed in the 2026-10-08 audit

Six defects of one shape — a predicate that answered a question adjacent to the
real one — found by re-reading the whole repository rather than the last commit.
`make test` was green throughout, which is why they survived.

- **A scan of `/Users` offered every app's live cache.** The home was recognised
  only when the `Users` directory was a direct child of the scan root, which
  cannot hold when the root *is* `/Users`; `~/Library/Caches` and `~/.cache`
  became candidates. The panel's Move does not re-check the guard (your tick is
  the authorization), so that row could really be trashed.
- **A folder scan missed the cache it was pointed at.** The shape rules compared
  a bare parent *name*, but a scan root's name is its whole path — so scanning
  `~/Library/Developer/Xcode` never saw the 2.0 GB `DerivedData` inside it.
- **The sandbox scan gate asked the wrong question.** It named the targets it
  considered gated rather than testing whether the held grant covered the target,
  so a folder you picked yourself — the only route to files outside the
  container — scanned with no access and reported "Nothing large to clean up".
- **Recognition and authorization disagreed on the default whole-disk target.**
  24 of 57 candidates were refused by the guard and still handed to the planner.
  The guard now judges every path in one spelling, and `Cleanup.find` filters the
  list so the two owners cannot drift again.
- **The engine stopped at `PATH_MAX`.** Paths longer than 1024 bytes lost their
  whole tail silently (`complete: false`, one error): on a 1830-byte-deep fixture
  the old code found 33 directories and no leaf, the new one finds 60 and the
  leaf. Deep build trees are exactly where this happens. The walk descends by
  `openat(2)` now.
- **`make test` never ran the Rust suite.** `test-rust` was not a prerequisite
  and there is no CI, so all 31 engine tests were skipped by the only gate there
  is, while `make help` advertised them twice under a heading claiming the
  opposite.

Also fixed: the rings drew real arcs for 0-byte siblings and overran the circle
by 30 %; a click in the map's blank space selected the whole-disk root instead of
clearing; every markdown table reused the first table's column alignment; an
unclosed HTML block could eat the rest of a document; the treemap's click and
hover disagreed about which node was under the pointer; `Tree::path` panicked on
a node whose subtree had been removed; and trashing the one unreadable folder
left the scan flagged partial forever.

`make test` runs 812 assertions across 20 suites with no failures, and the Rust
suite grew 31 → 36 tests.

## 1.0.1 — 2026-10-07

One planner instead of three, and four fixes that each removed a way the app
could show you something it could not act on.

**One planner, and it is the one you configure.** The bundled CLI agents
(Claude Code, Codex) are gone. The sandbox rehearsal settled the question the
App Store notes had only argued: a sandboxed build cannot exec an unbundled
program at all, so the feature could never ship there, and its one-click setup
downloaded a binary that build could not run. Rather than ship two planners with
different abilities, SmartTree has one — a model provider you configure, which
is plain outbound HTTPS on both distribution routes. `AgentLocator`,
`AgentSetup` and the Claude/Codex output parsing are removed; the allowlisted
tool cleanups survive unchanged, and the planner picker keeps its single
observable owner so the checkmark still follows the choice.

**Cleanup no longer offers a folder inside an app.** An Applications scan
proposed Bitwarden's and Openship's bundled `node_modules`, then refused both as
"Outside your home folder" — cards you could not select, for folders you never
scanned. Those folders are shipped, not rebuilt: an app loads them at runtime,
and removing one makes `codesign` report *"a sealed resource is missing or
invalid"*. The guard now refuses anything inside a signed app bundle for that
reason, which also closed a real hole rather than only a confusing message:
`~/Library/Application Support/…/Raycast.app/…/node_modules` sits inside the
home folder, so it was permitted and actionable. Recognition and the planner
prompt no longer propose bundle internals at all.

**A cleanup says what it scanned, and nothing else.** An Applications scan also
planned Xcode's simulator runtimes from `/System/Library/AssetsV2/…` — genuinely
reclaimable, but a plan headed "Here's the plan" for Applications, listing two
folders from outside it. The simulator rows now appear only when the scan
covered them, so a whole-disk scan still offers them and a folder scan describes
that folder.

**The Clean Up panel no longer proposes work it cannot do.** One consequence
worth stating: an Applications scan now offers nothing at all, where it used to
offer two unselectable cards. Those bytes are not safely reclaimable, so an
empty plan is the honest answer.

**Fixes.** The Model Providers pane indented its rows inside the pane's own
padding, so they sat 16pt right of the header and the buttons stopped 16pt short
of "Add provider". Two test suites (`test-readme`, `test-doclinks`) compiled but
never ran, so 66 assertions had never executed. And `make release` republished a
GitHub release as a side effect of wanting a dmg; packaging is now `make
package`, which publishes nothing.

**Privacy policy.** §5.2 and §5.5 are statements of fact about what the app
sends and refuses, and both had drifted from the code — §5.5 did not mention the
new signed-app-bundle rule, and §5.2 still implied the simulator details were
always sent. Both are corrected, and the claims are now asserted against the
sources that decide them, so the next change to either must update the policy.

## 1.0.0 — 2026-10-06

First Mac App Store release.

One selection is shared by the map, the rings and the list, and every gesture
that builds it was measured against the real renderer rather than assumed.

**Delete means delete.** Delete or Backspace moves the selection to the Trash,
in all three views alike; Shift with either key deletes it permanently. Both ask
first, in one dialog naming how many items and how much they weigh.

**Pick as many as you like.** ⌘-click toggles an item, Shift-click selects the
range between the anchor and the click, ⌘⇧-click extends that range without
replacing it, and ⌘A selects everything the view is showing. Selecting a folder
and a file inside it cannot both be true — whichever you picked last wins — so
the space you reclaim is never counted twice.

**Collapsing never loses a selection.** A folder with something selected inside
it keeps a striped highlight to say so: the pick is hidden, not cancelled, so
Delete still removes it and the byte total still counts it.

**Fixes.** Shift-click in the map selected items the sweep never crossed: the
reading order held every drawn depth, so a range could swallow grandchildren of
a folder that was only passed over — 42% of top-level sweeps on a realistic
layout. The order is now the level on screen, generated by the renderer that
decides what is drawn. A folder whose only paint is its own outline was
clickable but not hoverable, so ⌘↑ climbed from the wrong item. And ⌘⇧-click was
read as a plain ⌘-click, toggling the item under the pointer instead of
extending to its folder.

## 0.0.1 — 2026-09-27

First release of this fork.

- History starts from a snapshot of BlitzTree by Ahmed Khaleel (up through the flat-engine / third performance pass work), squashed into a single root commit.
- Version numbering restarts at 0.0.1.
- Licensing changed: the squashed snapshot remains MIT; all work from the snapshot onward is CC BY-NC-SA 4.0. See [LICENSE](LICENSE).
