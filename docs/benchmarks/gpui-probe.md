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
