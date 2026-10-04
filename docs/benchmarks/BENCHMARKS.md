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
**Target:** `/Applications`, 247,465 files / 42,409 dirs / 12,618,919,936 bytes allocated
**Method:** 5 measured rounds per engine, 1 warmup, ABBA alternation

| | AppleTree | disktree 0.10.1 | ratio |
|---|---:|---:|---:|
| median scan | **0.512 s** | 1.121 s | **2.19× faster** |
| range | 0.489–0.528 s | 0.903–1.128 s | |
| peak RSS | **21.2 MB** | 70.0 MB | **3.30× less** |
| allocated bytes | 12,618,919,936 | 12,618,919,936 | identical |

Full machine-readable data, including every individual sample:
[`results/2026-10-04-apple-m1-macos27.0/`](results/2026-10-04-apple-m1-macos27.0/)
(`run.json`, plus `run-fixture.json` for the deterministic synthetic tree).

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
