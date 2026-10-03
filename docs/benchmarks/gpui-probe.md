# GPUI+Ely probe — measured, same machine, same engine

Date: 2026-10-03 · M4, 10 cores, 16 GB, macOS 27.0, Rust 1.98
Probe: `gpui-probe/` (throwaway, not shipped) — `appletree::scan` in-process, Ely `Treemap` + `Tree`, 1200×800 window.
Reference: `docs/benchmarks/PERFORMANCE_AUDIT.md` (v0.5.0, same machine).

## What was measured

| Quantity | SwiftUI app (v0.5.0 audit) | GPUI+Ely probe |
|---|---|---|
| Engine scan, /Applications (289,866 nodes in probe run) | 0.597 s median | 1.09–1.38 s wall* |
| Flat tree → UI models hand-off | (Swift reads in place) | **1.1–2.9 ms** |
| Treemap layout | ~5 ms (1600×1600) | inside build p50 0.13 ms† |
| Treemap paint | ~3 ms | (GPU, per-frame) |
| Steady per-frame cost | (event-driven, idle = 0) | **p50 0.13 ms build; vsync-bound 16.67 ms frames** |
| Worst observed frame | — | 95–118 ms (first-seconds warm-up spikes) |
| Peak resident memory | 58.98 MB | **120.3 MB** |
| First-result visible | 96.8 ms | not measured (no equivalent harness) |

\* Probe scan includes Rust-side allocation of 290k nodes the Swift side reads
without copying; the engine's own `walk 0.98–1.19s finish 3.7–4.4ms` line shows
the difference is measurement framing, not a slower engine.
† `build` = time in `Render::render` to construct the Ely element tree
(37 tiles + 2035-row list rebuild each frame, deliberately worst-case).

## Frame behavior

- Steady state: frames tick at exactly 16.67 ms (60 Hz vsync) because GPUI
  redraws every vsync while the FpsMeter/animation loop is active. The actual
  element-build work per frame is **0.13 ms p50 / 0.23 ms max**.
- Warm-up: first ~2 s show p99 17–77 ms spikes (Metal shader compile, font
  load, first layout). Settles afterwards.
- Hover/interaction cost was not separately measured in this probe; the
  SwiftUI app's hover path is already 0 extra work (measured in ui.md).

## Honest comparison

- **Per-frame paint work**: GPUI's build cost (0.13 ms) is *not* directly
  comparable to SwiftUI's 5 ms layout + 3 ms paint — different pipelines.
  The honest statement: at this tree size, both are far under the 16.7 ms
  frame budget. Neither is user-perceptibly faster.
- **Memory**: GPUI probe peaks at ~120 MB vs SwiftUI's 59 MB — roughly 2×,
  measured with the same engine underneath. The GPUI window (shaders, text
  system, glyph cache) carries real overhead.
- **Scan time**: identical engine, so identical (the probe's higher wall time
  is Rust-side ownership, not engine cost).
- **First-result latency**: probe has no equivalent harness; unmeasured.

## Verdict

GPUI+Ely works with the engine directly (1.2 ms hand-off, zero-copy access
proven possible) and frames cheaply (0.13 ms). But the SwiftUI app is
already event-driven-idle at 0 cost, well under frame budget, and uses half
the memory. Nothing measured justifies a rewrite: the SwiftUI app is not
the bottleneck, and a GPUI port would trade 6,338 lines of working,
localizable, a11y-tested code for a 2× memory penalty and an immature,
git-pinned dependency (`ZacharyZhang-NY/Ely-GPUI-Components` @ Zed rev
`1a28cff`, not on crates.io, macOS-only tested).

## Risks recorded (from docs review, not measured here)

- Ely is git-pinned to one Zed GPUI revision; API moves when GPUI does.
- Not on crates.io; no versioning story.
- Windows/Linux untested.
- Early stage; 43 chapters but component churn is expected.

# Scale test: 100k, 250k, and 1M files in one folder

Real files created on disk (`/tmp/scale/flat-100k`, `flat-250k`, `flat-1m`),
`PROBE_MAX_KIDS=0` so nothing is capped, same machine.

## Results

| Quantity | 37 tiles (baseline) | 100,000 | 250,000 | 1,000,000 |
|---|---|---|---|---|
| Engine scan | 1.1 s | 0.15 s | 0.59 s | 44–54 s* |
| Flat tree → Ely models | 1.2 ms | 22 ms | 55 ms | 236 ms |
| Frame p50 (steady, both views) | 16.67 ms | 16.67 ms | **42 ms (~24 fps)** | **135 ms (~7 fps)** |
| Element-build p50 per frame | 0.13 ms | 5.6 ms | 14 ms | 60 ms |
| Frame p99 | 17.7 ms | 20 ms | 69 ms | 242 ms |
| Peak resident (windowed) | 120 MB | 814 MB | **1.27 GB** | **3.4 GB** |
| Peak resident (models only, no window) | — | 34 MB | — | — |
| First paint | — | ~1–2 s | several seconds | **never within a 4-minute run** (combined view; each half alone first-paints after ~10 s of 65–80 ms frames) |

\* Engine-side: `getattrlistbulk` over 1M files plus sorting a 1M-child
directory. Framework-independent — the SwiftUI app pays the same scan; but note
the engine itself has an O(n log n) per-directory sort that a flat million-entry
folder exposes.

## What breaks, precisely

- **The Ely `Tree` list scales well but not freely.** It virtualizes via GPUI's
  `uniform_list`: at 100k rows the list alone builds in **1.0 ms/frame** and
  frames hold 16.67 ms. At 250k rows alone frames drift to ~49 ms p50 despite
  only 2.6 ms builds — virtualization keeps element count bounded, but
  something in the per-frame row bookkeeping (keyed-state diff over 250k
  keys) still grows. At 1M rows alone: 10.5 ms build, 65 ms frames. The
  engine's `child_off`/`children` arrays still map onto a virtualized list
  cleanly; the ceiling is Ely's tree-list machinery, not virtualization.
- **The Ely `Treemap` does not scale.** Its `RenderOnce` sorts all tiles,
  squarifies all tiles, and creates a label `Div` for every tile that passes
  the size filter — every frame, no virtualization, no capping. At 100k tiles
  the treemap alone pushes frames to 33–49 ms p50 (degrading over time as
  label count grows); at 250k alone it holds ~33 ms p50 (~30 fps); at 1M it
  dominates the failure (47–60 ms build per frame). Paint is a canvas quad
  per tile, also unbounded.
- **Per-frame model clone** (probe's fault, not Ely's): `Tree::new` consumes
  nodes by value, so the probe rebuilds/clones 1M `TreeNode`s per frame. A
  real port would hold them in an `Entity` and render via reference. The
  build-time column above includes this; even so the treemap dominates.

## Context: what the SwiftUI app does at the same scale

The SwiftUI treemap is not capped by count — `Squarify.items` takes every
direct child — but `layoutItems` breaks out of the squarify loop once a
child's area drops below a quarter pixel (`size * scale < 0.25`), so a flat
250k-entry folder only lays out the tiles big enough to see, and paint goes
straight into a pixel buffer (`paint_quad`-free, one raster pass) with labels
only for tiles ≥ 90×30 px. The list virtualizes. That is why the whole app
first-paints 290k nodes in 96.8 ms using 59 MB. The GPUI probe's 100k window
uses **814 MB** — 10× more — because Ely's treemap materializes a `Div` label
per tile and re-sorts/re-squarifies everything every frame.

## Verdict at scale

- A GPUI+Ely port of the *list* is viable at 100k rows and workable at 250k
  (virtualization holds; ~49 ms p50 at 250k needs investigation or a lighter
  row type). No measured win over SwiftUI, and SwiftUI's list held its
  numbers at the same scales — but no loss either.
- A GPUI+Ely port of the *treemap* would need Ely's component replaced with
  the same ¼-pixel-early-exit + pixel-buffer-paint approach the Swift app
  already uses — at which point the layout algorithm is framework-neutral
  and GPUI's advantage is zero, since the Swift implementation already runs
  it in ~5 ms.
- 1M nodes in one view is a pathology for both frameworks; the engine itself
  (44 s scan of a flat million-child directory — worth its own fix, e.g.
  deferring or chunking the per-directory sort) is the larger problem there,
  and neither UI can rescue it.
