# Benchmarks

AppleTree's scan engine, measured against [disktree](https://github.com/tobi/disktree)
on the same machine, in the same run, by one command.

**Run it:**

```sh
cd bench && ./run.sh
```

The first build fetches the pinned `disktree-core` (needs network once). To
benchmark AppleTree alone, offline: `./run.sh --no-disktree`.

## What is measured

The **scan engine only**: the call that walks a directory tree and returns the
flat tree the UI reads. Two numbers per engine:

- **Wall time** of the engine call, excluding process start.
- **Peak RSS** of that engine's own process after the scan, with the tree still
  loaded. Each engine runs in a separate process, so the two figures are not
  added together.

Both engines are alternated round by round (ABBA) after one unmeasured warmup,
because cache warmth and background load drift over a run, and a block of
AppleTree runs followed by a block of disktree runs would charge that drift to
whichever engine went second.

If the two engines disagree on allocated bytes, the run **fails**: the
filesystem changed underneath it or an engine regressed, and a speed number
from that run would be meaningless.

## Results — 2026-10-04

**Host:** Apple M1 · 16 GB RAM · macOS 27.0 (8 cores)
**Method:** 7 measured rounds per engine, 1 warmup, ABBA alternation, engine
call only, warm cache. The machine was in normal use, so these are local
measurements under background load, not a quiet-lab figure.

### Memory is the stable, reproducible result

Peak RSS barely moved across five separate sessions on the same target
(`/Applications`, 247,465 files):

| | AppleTree | disktree 0.10.1 | ratio |
|---|---:|---:|---:|
| peak RSS across 5 sessions | **20.5–22.3 MB** | **69.0–69.3 MB** | **3.1× less** |

That spread is small enough to state as a single claim, and both engines report
**identical allocated bytes** on every target.

### Scan time varies with machine load

On the same target, median scan time across those sessions ranged:

| target | AppleTree | disktree 0.10.1 | speed |
|---|---:|---:|---:|
| `/Applications` (5 sessions) | 0.53–0.69 s | 0.94–1.42 s | **1.8–2.1×** |
| `~/Library/Developer`, 51,235 files | 0.367 s | 0.420 s | **1.14×** |
| `~/Documents`, 8,628 files | 0.014 s | 0.023 s | 1.59× |
| `~/Downloads`, 122 files | 0.001 s | 0.001 s | 1.25× |

Report a **range**, not a headline number: both engines slow down together under
load, so the ratio is steadier than either absolute time. The margin is also
workload-dependent — widest on file-heavy trees, narrowest on directory-heavy
ones (`~/Library/Developer` is 1.8 files per directory and only 1.14×).

### GUI-mode comparison (opt-in, `--compare-apps`)

Same host and target, 5 rounds each, every app given the same target:

| app | scan finished after | peak memory | how measured |
|---|---:|---:|---|
| **AppleTree** | **0.752 s** | **137.6 MB** | app-reported; peak is the kernel high-water mark |
| disktree 0.10.1 | ~3.3 s | 156.5 MB | external wall-clock (upper bound); memory sampled |
| GrandPerspective 3.7.2 | 7.02 s | 151.6 MB | app-reported; memory sampled |
| QDirStat 2.0.01 | 8.09 s | 212.9 MB | app-reported; memory sampled |

**Memory is not measured identically across these rows.** AppleTree reports its
own `resident_size_max`, the kernel's true high-water mark. The other three are
sampled from outside every 50 ms, so their figures are floors that can miss a
spike between samples. Process memory also includes the whole UI, which is why
these numbers are much larger than the engine-tier figures above — those come
from a process that never loads the UI.

Do not read the disktree row as equivalent: its GUI prints no timing anywhere,
so it is timed from outside until the process stops using CPU — a method with
roughly a second of resolution that also counts window and render work. The
other three rows are each app's own "scan finished" statement, and only
GrandPerspective and QDirStat are directly comparable to each other.

### Expected count differences

Both engines agree on allocated bytes. Two counts differ, and neither is an
accuracy problem:

- **Files.** AppleTree counts every name of a hardlinked file and counts
  symlinks as files; disktree counts a hardlinked file once. AppleTree therefore
  reports more files for the same bytes (247,465 vs 235,540 here).
- **Directories.** disktree counts the scan root itself as a directory; AppleTree
  counts only the directories inside it, so disktree is one higher.

## What this does not measure

- **GUI time.** App launch, treemap layout, painting, hover and outline
  performance. The earlier UI, rendering and agent harnesses were retired with
  the rest of the old benchmark surface; nothing here replaces them.
- **Whole-disk accuracy.** Only paths the process can read are counted. Without
  Full Disk Access, root-only system data is invisible to *every* tool, which
  undercounts all engines equally rather than comparing them.
- **Memory beyond peak RSS.** The figure is a process peak, not the resident
  size of the loaded tree over time.
- **Other machines.** These are one M1's numbers, not a claim about every Mac.

## Reproducing

```sh
cd bench && ./run.sh                          # fixture + /Applications, 5 rounds
./run.sh --path "$HOME/Downloads"             # any folder you can read
./run.sh --runs 10 --fixture-size medium      # more rounds, bigger fixture
./run.sh --help                               # every option
```

Results land in `docs/benchmarks/results/<date>-<chip>-macos<version>/`.
Re-running overwrites that directory's files; nothing else is touched.

The synthetic fixtures (`--fixture-size small|medium|large`) are deterministic
from a seed and carry a manifest beside the tree, so two people on two machines
measure the same tree. `bench/` also exposes `fixture`, `verify`, `scan` and
`host` directly if you want to drive it yourself.

## Running the GUI comparison

```sh
cd bench
cargo run --release -- --help                       # every option
cargo run --release -- scan --path /Applications --compare-apps
```

`--compare-apps` also drives the installed GUI apps and writes
`gui-comparison.md` beside `run.json`:

| app | how its time is obtained |
|---|---|
| AppleTree | the app writes its own finish time (preference-gated hook, `bz.benchTiming`) |
| disktree 0.10.1 | **nothing to read** — timed externally until CPU goes idle |
| GrandPerspective | its own `Done scanning: … in Xs` line on stderr |
| QDirStat | its own `Reading finished after X sec` line in its log |

**The rows are not all the same interval**, and the report says so per row. The
three `app-reported` numbers are each app's own view of "scan finished"; the
disktree row is an external upper bound and must not be read as equivalent.

Two constraints worth knowing before relying on this tier:

- It **launches real apps**, so a round takes seconds, not milliseconds. It is
  deliberately not part of the default `./run.sh` path.
- Every app is launched through `open` so that **launchd, not your terminal, is
  the TCC-responsible process** — otherwise the app's own Full Disk Access grant
  would not apply and AppleTree would silently refuse to scan.

### A note on signing and Full Disk Access

AppleTree's GUI row needs `/Applications/AppleTree.app` to hold Full Disk
Access. If the app is **ad-hoc signed**, its designated requirement is a
`cdhash`, which changes on every rebuild, so macOS revokes the grant each time
you rebuild. Build with a real identity (any `Apple Development` or
`Developer ID` certificate) and the requirement becomes stable, so the grant
survives rebuilds. `make build` now warns loudly when it has to fall back to
ad-hoc signing for this reason.
