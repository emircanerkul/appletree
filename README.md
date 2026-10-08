<h1 align="center"><img align="left" src="assets/icon.png" width="48" alt="AppleTree icon"><a href="https://erklab.com"><picture><source media="(prefers-color-scheme: dark)" srcset="assets/erklab-logo-white.svg"><img align="right" src="assets/erklab-logo.svg" width="112" alt="erklab"></picture></a>AppleTree</h1>

<p align="center"><strong>A native macOS disk-space treemap that scans a 250,000-file drive in under a second.</strong><br>
Shows you what's safe to delete, not just what's big.</p>

<p align="center"><strong><a href="https://apps.apple.com/app/id6819034229">Get AppleTree on the Mac App Store</a></strong> — or build it from source and use it non-commercially, free.<br>
<sub>Requires Apple Silicon and macOS 14 or later.</sub></p>

<!-- /header -->

<p align="center">
  <video src="https://github.com/user-attachments/assets/2b2eda2e-cfae-471b-b993-17f463eaa76c" width="90%" controls>
    Your browser does not support embedded video.
  </video>
</p>

## Features

**Scan any drive.** Alongside the built-in targets (the boot volume, your home
folder, `/Applications`), every local storage volume is offered for scanning,
including a second internal partition or an external drive. The list is read
fresh whenever a disk is plugged in or ejected, so a drive that appears while
the app is open shows up in the picker immediately. Network volumes and mounted
disk images are excluded by device properties rather than by name, so no list of
installer volumes has to be maintained.

**Back and forward through the folders you visited.** The toolbar arrows, ⌘[
and ⌘], and your mouse's side buttons walk the folder history. Only deliberate
folder changes are recorded, so moving the keyboard focus never fills it. The
folders visited and the one you were browsing are saved, and the next launch
opens where you left off.

**Right-click works everywhere.** The treemap, the rings and the directory list
offer the same menu for any file or folder: Reveal in Finder, Copy Path, Select
Enclosing Folder, Move to Trash, and Delete Permanently — which deletes the item
itself rather than moving it to the Trash, and says so before it does. One owner
builds that menu, so no surface can offer a different set of actions for the
same item.

**Delete means delete.** Delete or Backspace moves the selection to the Trash,
in the map, the rings and the list alike; holding Shift with either key deletes
it permanently. Both ask first — one dialog naming how many items and how much
they weigh — and the permanent one's button carries its own verb rather than a
generic "OK".

**Pick as many as you like.** ⌘-click adds an item to the selection and removes
it when clicked again; Shift-click selects the range between the anchor and the
click, on the level you are looking at; ⌘A selects everything the view is
showing you. The selection is shared, so
picking in the list and switching to the map or the rings keeps it highlighted.
Selecting a folder and a file inside it cannot both be true — whichever you
picked last wins — so the space you reclaim is never counted twice. In the rings
a selected folder lights the arcs inside it too, since one arc is the folder and
what it holds is drawn further out; in the map the folder's own box already
stands for its contents.

**A title path you can navigate.** The breadcrumb path follows the selection,
and every folder above it is one click away.

**Collapsing never loses a selection.** A folder with something selected inside
it can still be collapsed, and its row keeps a striped highlight to say so —
the pick is hidden, not cancelled, so Delete still removes it and the byte total
still counts it. Selecting anything new opens the list back up to show it.

**Keyboard navigation.** Arrow keys move the focus, Return zooms in, Escape
zooms out, and ⌘↑ selects the folder holding the focused item — useful when a
tile is too small to click: a folder drawn as nothing but its own outline still
takes the focus when you point at that outline, so ⌘↑ climbs from it rather than
from whatever sits inside it. Delete moves the selection to the Trash and
Shift+Delete deletes it permanently. ⌘-click, Shift-click and ⌘A build a
selection across all three views. Focus is chosen geometrically, so files and
folders compete for the nearest tile together.

**Clean Up panel.** Finds folders that are safe to remove — caches,
`node_modules`, Rust `target`, Xcode DerivedData and more — so they can be
moved to the Trash in one pass.

**AI cleanup, using a model you choose.** Configure a provider in Settings →
Model Providers and click "Clean up with …"; it plans what can go while the
treemap highlights those folders. AppleTree performs the cleanup itself, in two
steps you approve: move to the Trash, then delete permanently.

**Every planner stays reachable.** The Clean Up button carries a menu listing
every configured provider, plus the row that adds another. Switching is always
one click, and Settings → General lists the same choices as one "Clean Up
planner" row. Both surfaces read one list, so the planner Settings shows is
always the one the panel runs.

**Or plan with any model.** Settings → Model Providers connects any OpenAI- or
Anthropic-compatible endpoint — a relay, a self-hosted server (Ollama, LM
Studio) or a gateway — by its base URL, protocol and model. API keys are held in
the Keychain, never in preferences. The endpoint receives the scan summary and
nothing else: it runs no tools and never reads your disk, so file contents stay
local. AppleTree still performs and re-checks every deletion itself.

**Scan when AppleTree opens.** Off by default. The first launch shows the empty
home screen with a one-time checkbox to turn launch scanning on; whatever you
choose is saved and the offer is never shown again. Change it later in
Settings → General.

**Full Disk Access**, in the Developer-ID build, is required for a whole-disk
scan: picking **Macintosh HD** without the grant shows the permission card
first, while Home, Applications and a specific drive scan straight away. The
**Mac App Store build never asks for it** — Full Disk Access cannot lift App
Sandbox (measured: the same TCC grant applied to both builds, and only the
unsandboxed one could read the protected paths), so that build reaches your
files by asking you to pick a folder once in the open panel. The
security-scoped bookmark that creates covers the folder and everything below
it, which is what makes a whole-disk scan work there.

**Two ways to see the disk.** A cushion-shaded treemap colored by file type,
with a synced Finder-style outline list, or DaisyDisk-style rings: click a
folder to zoom in, the middle to go back.

**Seven languages.** English, Türkçe, Deutsch, Français, Español, 简体中文 and
日本語, selected in Settings. The prompt sent to the planner stays in English
while the interface follows your choice.

**Native, and quiet.** AppKit and SwiftUI throughout, with the Liquid Glass
design on macOS 26 and later. Live progress while scanning, an optional
free-space block, and no telemetry of any kind.

## Performance

Every figure below was measured on **Apple M1, 16 GB, macOS 27.0**, scanning
`/Applications` (247,465 files, 12.6 GB). AppleTree and every tool compared
against it report the **same allocated bytes** (12,618,940,416).

**[Full method, every raw sample, and what these figures deliberately do not
measure →](docs/benchmarks/BENCHMARKS.md)**

### Scan engine

Timing the scan engine alone, in its own process, with AppleTree and disktree
alternated round by round (7 rounds × 5 sessions):

| scan engine | Scan time | Peak memory |
|---|---|---|
| **AppleTree** | **0.53–0.69 s** | **20.5–22.3 MB** |
| disktree 0.10.1 | 0.94–1.42 s | 69.0–69.3 MB |

AppleTree uses **3.1× less memory** and is **1.8–2.1× faster** here. Memory is
the stable figure; scan time varies with machine load, which is why both are
given as a range.

### Whole app

Timing the complete running application — launch, scan, and hand-off to the UI —
with every app given the same target and 5 rounds × 3 sessions:

| app | Scan finished after | Peak memory |
|---|---:|---:|
| **AppleTree** | **0.79–0.85 s** | **137.1–138.5 MB** |
| disktree 0.10.1 | 2.43–4.40 s * | 152.4–156.6 MB |
| GrandPerspective 3.7.2 | 5.21–5.82 s | 154.7–160.2 MB |
| QDirStat 2.0.01 | 5.95–6.42 s | 199.4–214.2 MB |

AppleTree is the fastest of the four, and the lightest of the four.

* disktree's GUI reports no timing anywhere, so it is measured from outside
until the process stops using CPU. That method has roughly a second of
resolution and also counts window and render work, so it is an **upper bound**,
not an equal measurement; the other three rows are each app's own "scan
finished" statement. Peak memory for the three non-AppleTree apps is sampled
every 50 ms, so those are floors on the true peak; AppleTree's is the kernel's
own high-water mark.

Whole-app memory is much larger than engine memory because it includes the
entire UI, which the engine-only figures above never load.

### Reproduce it

```sh
cd bench && ./run.sh                                            # engine comparison
cd bench && cargo run --release --bin btbench -- scan --compare-apps   # add the GUI apps
```

The first run fetches the pinned `disktree-core` (needs network once); add
`--no-disktree` to benchmark AppleTree alone, offline.

Three things do the work:

- `getattrlistbulk(2)` reads a whole directory's metadata in one syscall instead of one `stat` per file.
- A Rust worker pool keeps many directories in flight. Its workers run at user-initiated QoS, so they stay on performance cores without outranking the UI and the compositor.
- The treemap is laid out once and painted on every core in parallel, so zooming redraws in a couple of frames.

## Accuracy

Sizes are allocated bytes, matching `du`. An inode with several hard links is
counted once, whichever name the scan reaches first, so byte totals do not
depend on traversal order. The scan stays on one volume, and cloud-only iCloud
folders are never downloaded. Root-only system data that no app can read is
reported in the status bar instead of being hidden.

**APFS clones are counted per name, like `du`, and that is not the same as space
you get back.** A clone is a separate inode sharing blocks with its original, so
each copy reports the full allocated size: a 512 MB clone shows as 512 MB in
every tool here, while deleting it frees roughly nothing. Both `du` and this
scanner behave that way, which is why the totals match — but the Clean Up panel's
figures are read as *reclaimable* space, and for a folder full of clones they are
not. macOS produces clones routinely (the installer, `cp -c`, Xcode caches, Time
Machine locals), so treat a suspiciously round figure as a clone before expecting
the disk back. Hard links do not have this problem: those genuinely are one inode
and this scanner counts their bytes once.

File counts differ from some tools, and not because of an accuracy problem.
AppleTree lists every name of a hard-linked file and counts symlinks as files;
disktree counts a hard-linked file once. AppleTree therefore reports more files
for identical byte totals — 247,465 against 235,540 on `/Applications`.
AppleTree also counts only the directories inside the scan root, where disktree
includes the root itself, so the directory counts differ by one. Neither
affects the bytes, which match exactly.

## AI cleanup

Nothing here can write to your disk. The planner is invited only to read the
scan summary: a custom model provider gets no tools at all. It writes a plan,
and AppleTree then acts on that plan behind its own checks, whatever the plan
says:

- Only paths inside your home folder, never Documents, Desktop, Photos, iCloud Drive, Mail, keychains or `~/.ssh` (build output such as `node_modules` inside them is allowed), never a git repository, never a whole folder such as `~/Library/Caches`, and never anything inside a signed app bundle — a bundle's own folders are sealed by its code signature, so removing one invalidates the app
- Only each tool's own cleanup commands (`npm cache clean`, `brew cleanup`, `docker system prune` and similar, plus `xcrun simctl` for Xcode simulator runtimes and device data), with no shell syntax
- Every cache is offered as the folder it is, found by the tool's own location and structure — the pnpm store, the npm cache, Homebrew's, Cargo's — so cleanup needs no external command. The Mac App Store build runs no commands at all, and offers no command item
- Projects you used in the last 2 days are left alone
- Caches belonging to apps that are open are skipped until you quit them
- "Delete permanently" removes only what this cleanup moved to the Trash

## Trust, privacy and permissions

**Developer-ID build.** AppleTree asks for Full Disk Access so the scan can read
every folder on the disk, including the system-protected ones that normally stay
out of reach. Every allowlisted cleanup command it runs inherits that same grant
while it runs; what that command does with it is the tool's own behaviour, not a
policy AppleTree sets.

**Mac App Store build.** No Full Disk Access is requested, because it cannot
lift App Sandbox. Instead the app asks you to choose a folder in the open panel;
the security-scoped bookmark that creates lets it enumerate, Trash and delete
inside that folder, and it is held only for the session you granted it in. That
build also runs no cleanup commands at all — a sandboxed process cannot launch
another tool — so the planner offers folder moves only. `bz.scopedBookmark` in
the preference domain is where the chosen folder is recorded.

Cleanup commands (`npm cache clean`, `brew cleanup` and so on) are resolved
through the shell's PATH, by design: these tools live in Homebrew, `~/.local/bin`,
nvm and other tool-manager locations, and AppleTree does not guess where they
are installed. Only commands matching a small allowlist of tool-specific
cleanup invocations are ever run, but what runs is whatever the PATH resolves —
the trust in your own PATH is residual.

There is no telemetry. AppleTree contacts the network only when you explicitly
ask it to: fetching a model list, or running an AI cleanup. **Moving folders to
the Trash yourself — from the map, the rings, the list or the Clean Up panel —
is entirely local and sends nothing.**

When you do run an AI cleanup, AppleTree sends the planner a *summary* of the
scan, never file contents: the largest folder and file paths with their sizes
(up to a few hundred entries), your home path, the scan root, and which apps are
currently running. A custom model provider receives that summary over HTTP and
nothing else: it runs no tools and never sees the disk, so file contents are
never sent.

Either way, AppleTree performs and re-checks every deletion itself.

## Build from source

Requires Xcode 16.3 or later (Swift 6.1) and Rust. The build probes your
toolchain and stops with a clear message if the Swift version is too old.

```sh
make help              # every target
make build             # build/AppleTree.app
make deploy            # build and install to /Applications
make open              # build and launch
make package           # notarize when possible, and package AppleTree.dmg locally
make test              # the full suite: Rust engine tests, Swift suites, JSON CLI, l10n
make test-rust         # cargo test --release only (also runs inside `make test`)
```

The Rust engine hands the finished tree to the Swift UI as flat arrays over a C
interface, with no copying. `AppleTree <path>` scans a specific folder.

Sign the bundle with a real `Apple Development` or `Developer ID` identity if you
intend to grant it Full Disk Access. An ad-hoc signature pins its identity to a
hash that changes on every rebuild, so macOS drops the grant each time you
rebuild; the build warns when it has to fall back to ad-hoc for this reason.

## JSON CLI for agents and scripts

An optional, read-only CLI uses the same scan engine without opening the GUI
or running an AI cleanup:

```sh
cargo build --locked --release --features cli --bin appletree
./target/release/appletree scan --root "$HOME/Downloads"
./target/release/appletree quick-wins --root "$HOME" --limit 20
```

`scan` lists the largest directories and files as JSON. `quick-wins` adds the
Clean Up panel's folder candidates — the same name/structure heuristics, with no
new criteria and no safety assessment — which you should review before acting.
Both report incomplete scans; allocated bytes are not a promise of reclaimable
space, and the root itself is never a candidate. Neither command modifies the
scanned files. Exit code 0 is a report, 1 an I/O or scan failure, and 2 invalid
arguments; `coverage.complete` should be checked even on exit 0.

The CLI is built from source separately from the app; its JSON dependency is
only compiled with the `cli` feature. Its behaviour is covered by
[`tests/test_cli.py`](tests/test_cli.py).

## Benchmarks

The full benchmark suite, method and raw results live in
**[`docs/benchmarks/BENCHMARKS.md`](docs/benchmarks/BENCHMARKS.md)**. It covers
the scan engine, the whole-app comparison, why the tools report different file
counts for identical bytes, and — just as importantly — what is **not** measured:

- GUI interactions: hover, outline scrolling and zoom are not timed.
- Whole-disk accuracy: without Full Disk Access, root-only system data is
  invisible to every tool, which undercounts them all rather than comparing them.
- Memory over time: the figures are peaks, not the resident size of a loaded tree.

Results are regenerated with `cd bench && ./run.sh` and land in
[`docs/benchmarks/results/`](docs/benchmarks/results/).

## Getting help

AppleTree has no manual — it is one window and a button, and this README covers
the rest. The **Help** menu carries the places that are actually useful instead:

| Menu item | Where it goes |
|---|---|
| Bug Report | the issue form, with fields for your version, macOS and setup |
| Report a security vulnerability | [SECURITY.md](.github/SECURITY.md), for private reporting |
| Feature request | the feature-request issue form |
| Question | the question issue form |
| AppleTree on GitHub | the source, releases and issues |

**AppleTree → About AppleTree** carries the version and links to the project and
its license.

## License

AppleTree is licensed in two parts by history: the code inherited from BlitzTree
is MIT, and work on top of that snapshot is CC BY-NC-SA 4.0. Non-commercial use
is free under those terms.

**Commercial use of the compiled app is granted by purchase.** Buying AppleTree
on the [Mac App Store](https://apps.apple.com/app/id6819034229) lets that
purchaser use their copy commercially, on their own devices. That grant is
personal to the purchase: it does not cover the source code, redistribution,
reselling, or bundling AppleTree into another product. The source stays
CC BY-NC-SA 4.0 without exception, for everyone.

For anything wider than one buyer running their own purchased copy, ask about a
separate licence at licensing@appletree.apps.erklab.com. See [LICENSE](LICENSE)
for the exact wording and the boundary between the two parts.
