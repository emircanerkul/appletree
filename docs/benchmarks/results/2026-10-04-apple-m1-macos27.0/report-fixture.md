# Scan benchmark

**Target** `/var/folders/km/l2g6y3zn1q16n0hw63_fb9b80000gn/T//btbench-fixture-small`

**Host** Apple M1 · 16 GB RAM · macOS 27.0

**Method** 5 measured run(s) per engine after one unmeasured warmup, alternating engines each round (ABBA), each engine in its own process. Timings cover the engine call only; memory is that process's peak RSS after the scan, with the tree still loaded.

## Results

| | AppleTree | disktree | ratio |
|---|---:|---:|---:|
| median scan | **0.003 s** | 0.004 s | 1.38× faster |
| range | 0.002–0.003 s | 0.004–0.005 s | |
| peak RSS | **2.7 MB** | 6.9 MB | 2.57× |
| files | 1503 | 1502 | 1 more links |
| dirs | 177 | 178 | |
| allocated bytes | 13811712 | 13811712 | **identical** |
| read errors | 0 | 0 | |

Two count differences are expected and are not accuracy problems; both engines report identical allocated bytes, which is the number that matters for disk space:

1. **File count.** AppleTree counts every name of a hardlinked file, and counts symlinks as files; disktree counts a hardlinked file once. AppleTree therefore reports more files for the same bytes.
2. **Directory count.** disktree counts the scan root itself as a directory; AppleTree counts only the directories inside it, so disktree is one higher.

## What this does not measure

- **GUI time.** Application launch, treemap layout, painting, hover and outline performance are not measured here.
- **Whole-disk accuracy.** Only paths this process can read are counted. Without Full Disk Access, root-only system data is invisible to *every* tool in the table; that undercounts all engines equally and is not a comparison of them.
- **Memory beyond peak RSS.** The reported figure is a process peak, not the resident size of the loaded tree over time.

## Reproduce

```sh
cd bench && ./run.sh
```
