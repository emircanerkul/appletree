<img src="assets/icon.png" width="128" alt="AppleTree icon">

# AppleTree

A fast, native disk-space treemap for macOS, in the spirit of WizTree. Scan a
disk, see exactly what is consuming it, and reclaim the space — without handing
your file list to anyone.

<p>
  <img src="assets/screenshot.png" width="49%" alt="AppleTree treemap view of /Applications">
  <img src="assets/screenshot-rings.png" width="49%" alt="AppleTree rings view of /Applications">
</p>

Requires Apple Silicon and macOS 14 or later.

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
Enclosing Folder, and Move to Trash. One owner builds that menu, so no surface
can offer a different set of actions for the same item.

**A title path you can navigate.** The breadcrumb path follows the selection,
and every folder above it is one click away.

**Keyboard navigation.** Arrow keys move the focus, Return zooms in, Escape
zooms out, and ⌘↑ selects the folder holding the focused item — useful when a
tile is too small to click. Focus is chosen geometrically, so files and folders
compete for the nearest tile together.

**Clean Up panel.** Finds folders that are safe to remove — caches,
`node_modules`, Rust `target`, Xcode DerivedData and more — so they can be
moved to the Trash in one pass.

**AI cleanup, using your own agent.** Click "Clean up with Claude Code" (or
Codex) and the agent plans what can go while the treemap highlights those
folders. AppleTree performs the cleanup itself, in two steps you approve: move
to the Trash, then delete for good. If no agent is installed, one click installs
and signs in to Codex (free with a ChatGPT account) or Claude Code.

**Every planner stays reachable.** The Clean Up button carries a menu listing
all of them: each installed agent, each custom provider, the agents that still
need an install or a sign-in, and the account actions. Signing in to one agent
therefore never hides or disables the others — switch planners at any time, and
sign an agent out again from the same menu when you want to change account.
Settings → General lists the same choices as one "Clean Up planner" row, and
names whatever the picked one still needs. Both surfaces read one list, so the
planner Settings shows is always the one the panel runs.

**Or plan with any model.** Settings → Model Providers connects any OpenAI- or
Anthropic-compatible endpoint — a relay, a self-hosted server (Ollama, LM
Studio) or a gateway — by its base URL, protocol and model. API keys are held in
the Keychain, never in preferences. Such an endpoint receives the scan summary
and nothing else: it runs no tools and never reads your disk, so it is the
option to pick if you want file contents to stay local. AppleTree still performs
and re-checks every deletion itself.

**Scan when AppleTree opens.** On by default. Turn it off in Settings → General
to choose a folder yourself before anything is scanned. A whole-disk scan is
never started without Full Disk Access.

**Two ways to see the disk.** A cushion-shaded treemap colored by file type,
with a synced Finder-style outline list, or DaisyDisk-style rings: click a
folder to zoom in, the middle to go back.

**Seven languages.** English, Türkçe, Deutsch, Français, Español, 简体中文 and
日本語, selected in Settings. The agent prompt stays in English while the
interface follows your choice.

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

File counts differ from some tools, and not because of an accuracy problem.
AppleTree lists every name of a hard-linked file and counts symlinks as files;
disktree counts a hard-linked file once. AppleTree therefore reports more files
for identical byte totals — 247,465 against 235,540 on `/Applications`.
AppleTree also counts only the directories inside the scan root, where disktree
includes the root itself, so the directory counts differ by one. Neither
affects the bytes, which match exactly.

## AI cleanup

Nothing here can write to your disk. The planner is invited only to read: a CLI
agent is given inspection commands (`du`, `ls`, `stat`, `docker system df`,
`xcrun simctl list`, `ollama list`) and `Read`, with no write or edit tool, and
a custom model provider gets no tools at all. The planner writes a plan, and
AppleTree then acts on that plan behind its own checks, whatever the plan says:

- Only paths inside your home folder, never Documents, Desktop, Photos, iCloud Drive, Mail, keychains or `~/.ssh` (build output such as `node_modules` inside them is allowed, and so are the Codex app's chat folders in `~/Documents/Codex`), never a git repository, and never a whole folder such as `~/Library/Caches`
- Only each tool's own cleanup commands (`uv cache clean`, `brew cleanup`, `npm cache clean` and similar, plus `xcrun simctl` for Xcode simulator runtimes and device data), with no shell syntax
- Codex chats and projects you used in the last 2 days are left alone
- Caches belonging to apps that are open are skipped until you quit them
- "Delete for good" removes only what this cleanup moved to the Trash

## Trust, privacy and permissions

AppleTree asks for Full Disk Access so the scan can read every folder on the
disk, including the system-protected ones that normally stay out of reach.
Everything it launches — the agent CLIs and each allowlisted cleanup command —
inherits that same grant while it runs. The agent CLIs' own sandbox settings
are a CLI-level policy, not an OS guarantee for anything they spawn.

Cleanup commands (`uv cache clean`, `brew cleanup` and so on) are resolved
through the shell's PATH, by design: these tools live in Homebrew, `~/.local/bin`,
nvm and other tool-manager locations, and AppleTree does not guess where they
are installed. Only commands matching a small allowlist of tool-specific
cleanup invocations are ever run, but what runs is whatever the PATH resolves —
the trust in your own PATH is residual.

There is no telemetry. AppleTree contacts the network only when you explicitly
ask it to: installing or signing in to an agent, fetching a model list, or
running an AI cleanup. **Moving folders to the Trash yourself — from the map,
the rings, the list or the Clean Up panel — is entirely local and sends
nothing.**

When you do run an AI cleanup, AppleTree itself sends the planner a *summary* of
the scan, never file contents: the largest folder and file paths with their
sizes (up to a few hundred entries), your home path, the scan root, and which
apps are currently running. This holds for every planner.

The two kinds of planner differ in what else can reach the network, and the
difference is worth knowing:

- **A custom model provider** receives that summary over HTTP and nothing else.
  It runs no tools and never sees the disk, so with a provider you connect
  yourself, file contents are never sent.
- **A CLI agent (Claude Code or Codex)** is a full agent with a `Read` tool, and
  AppleTree cannot restrict what it chooses to read. AppleTree hands it the same
  summary, but the agent can inspect further on its own, and what it reads
  becomes part of its conversation with Anthropic or OpenAI. Codex runs in a
  read-only sandbox and Claude Code is held by a tool allowlist, so neither can
  write — but that is a CLI-level policy, not a guarantee about what they read.

Either way, AppleTree performs and re-checks every deletion itself.

## Build from source

Requires Xcode 16.3 or later (Swift 6.1) and Rust. The build probes your
toolchain and stops with a clear message if the Swift version is too old.

```sh
make help              # every target
make build             # build/AppleTree.app
make deploy            # build and install to /Applications
make open              # build and launch
make release V=x.y.z   # notarize, package a .dmg, publish a GitHub release
make test              # cleanup-guard unit tests
cargo test --release   # engine tests
```

The Rust engine hands the finished tree to the Swift UI as flat arrays over a C
interface, with no copying. `AppleTree <path>` scans a specific folder.

Sign the bundle with a real `Apple Development` or `Developer ID` identity if you
intend to grant it Full Disk Access. An ad-hoc signature pins its identity to a
hash that changes on every rebuild, so macOS drops the grant each time you
rebuild; the build warns when it has to fall back to ad-hoc for this reason.

## JSON CLI for agents and scripts

An optional, read-only CLI uses the same scan engine without opening the GUI
or launching an AI agent:

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

## License

AppleTree is dual-licensed by history: the code inherited from BlitzTree is MIT,
and work on top of that snapshot is CC BY-NC-SA 4.0 (non-commercial). See
[LICENSE](LICENSE) for the exact boundary between the two.
