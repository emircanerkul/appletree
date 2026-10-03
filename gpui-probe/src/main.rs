//! Measurement probe: AppleTree's Rust engine rendered through Ely/GPUI.
//!
//! Answers "is the app faster in GPUI?" with numbers instead of argument:
//! scans the same real paths the SwiftUI app scans, builds an Ely `Treemap`
//! and an Ely `Tree` from the flat engine arrays, and reports both the
//! engine scan time and the per-frame window cost via Ely's `FpsMeter`
//! plus a `BZ_TIMING` log line.
//!
//! Run: `cargo run --release -- /Applications` (or any path).
//! `--print-only` scans and prints timings, then exits without a window
//! (for a machine-readable comparison against the SwiftUI harness).

use std::path::PathBuf;
use std::time::Instant;

use appletree::{Progress, Tree, scan};
use ely_gpui_component::Assets;
use ely_gpui_component::charts::Treemap;
use ely_gpui_component::lists::{Tree as ElyTree, TreeNode};
use ely_gpui_component::tooling::FpsMeter;
use gpui::{
    App, AppContext, Bounds, Context, IntoElement, ParentElement, Render, SharedString, Styled,
    TitlebarOptions, Window, WindowBounds, WindowOptions, actions, div, px, size,
};
use gpui_platform::application;

actions!(probe, [Quit, Exit]);

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let print_only = args.iter().any(|a| a == "--print-only");
    let root = args
        .iter()
        .find(|a| !a.starts_with("--"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/Applications"));

    // --- Engine scan (identical engine the Swift app uses) ---------------
    let t0 = Instant::now();
    let progress = Progress::default();
    let tree = scan(&root, &progress);
    let scan_ms = t0.elapsed().as_secs_f64() * 1e3;
    let nodes = tree.len();

    // --- Flat arrays -> Ely models (the hand-off GPUI pays for) ----------
    let t1 = Instant::now();
    let (tiles, tree_nodes, labels) = build(&tree);
    let build_ms = t1.elapsed().as_secs_f64() * 1e3;
    eprintln!(
        "[probe] scan {:.1} ms ({} nodes)  build ely models {:.1} ms  ({} tiles, {} list rows, {} treemap labels)",
        scan_ms,
        nodes,
        build_ms,
        tiles.len(),
        tree_nodes.len(),
        labels
    );

    if print_only {
        println!(
            "PROBE scan_ms={:.3} build_ms={:.3} nodes={} tiles={} rows={}",
            scan_ms,
            build_ms,
            nodes,
            tiles.len(),
            tree_nodes.len()
        );
        return;
    }

    // --- Window ----------------------------------------------------------
    application()
        .with_assets(Assets)
        .run(move |cx: &mut App| {
            ely_gpui_component::init(cx);
            let options = WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                    None, size(px(1200.), px(800.)), cx,
                ))),
                titlebar: Some(TitlebarOptions {
                    title: Some(SharedString::from("AppleTree · GPUI probe")),
                    ..Default::default()
                }),
                ..Default::default()
            };
            cx.open_window(options, |_, cx| {
                cx.new(|_| ProbeWindow {
                    tiles,
                    tree: tree_nodes,
                    frames: Default::default(),
                    builds: Default::default(),
                    last: None,
                })
            })
            .unwrap();
            cx.on_action::<Exit>(|_, cx| cx.quit());
            cx.activate(true);
        });
}

/// One tile per direct child of the root, the same shape the SwiftUI
/// treemap's first zoom level shows.
fn build(tree: &Tree) -> (Vec<(SharedString, f64)>, Vec<TreeNode>, usize) {
    let mut tiles = Vec::new();
    let mut nodes = Vec::new();
    let mut labels = 0usize;

    for &kid in tree.kids(0) {
        let name = tree.name(kid as usize);
        let bytes = tree.alloc[kid as usize] as f64;
        tiles.push((SharedString::from(name.to_string()), bytes));

        nodes.push(list_node(tree, kid as usize, 3, &mut labels));
    }
    (tiles, nodes, labels)
}

/// Cap on children listed per directory; overridable for scale tests:
/// `PROBE_MAX_KIDS=0` (or huge) lists everything, e.g. a 100k-file folder.
fn max_kids() -> usize {
    std::env::var("PROBE_MAX_KIDS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(64)
}

/// Recursively turn one engine node into an Ely TreeNode.
/// `depth` caps recursion so the probe's list stays tractable; the engine tree is huge.
fn list_node(tree: &Tree, index: usize, depth: u8, labels: &mut usize) -> TreeNode {
    let name = tree.name(index);
    let mut node = TreeNode::new(format!("n{index}"), name.to_string())
        .note(human(tree.alloc[index]));
    *labels += 1;

    if tree.is_dir(index) && depth > 0 {
        let cap = max_kids();
        let kids: Vec<TreeNode> = if cap == 0 {
            tree.kids(index)
                .iter()
                .map(|&k| list_node(tree, k as usize, depth - 1, labels))
                .collect()
        } else {
            tree.kids(index)
                .iter()
                .take(cap)
                .map(|&k| list_node(tree, k as usize, depth - 1, labels))
                .collect()
        };
        if !kids.is_empty() {
            node = node.children(kids);
        }
    }
    node
}

fn human(bytes: u64) -> String {
    const K: f64 = 1024.0;
    let b = bytes as f64;
    if b >= K * K * K {
        format!("{:.1} GB", b / (K * K * K))
    } else if b >= K * K {
        format!("{:.1} MB", b / (K * K))
    } else if b >= K {
        format!("{:.1} KB", b / K)
    } else {
        format!("{b} B")
    }
}

struct ProbeWindow {
    tiles: Vec<(SharedString, f64)>,
    tree: Vec<TreeNode>,
    frames: std::collections::VecDeque<f64>,
    builds: std::collections::VecDeque<f64>,
    last: Option<Instant>,
}

impl Render for ProbeWindow {
    fn render(&mut self, window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        // Frame-time probe: intervals between successive renders, reported
        // every 120 frames as avg / p50 / p99 / max in ms.
        let now = Instant::now();
        if let Some(prev) = self.last.replace(now) {
            self.frames.push_back((now - prev).as_secs_f64() * 1e3);
            while self.frames.len() > 600 {
                self.frames.pop_front();
            }
            if self.frames.len() % 120 == 0 {
                let mut xs: Vec<f64> = self.frames.iter().copied().collect();
                xs.sort_by(|a, b| a.partial_cmp(b).unwrap());
                let n = xs.len();
                let (p50, p99) = (xs[n / 2], xs[(n as f64 * 0.99) as usize % n]);
                let max = xs[n - 1];
                let avg = xs.iter().sum::<f64>() / n as f64;
                let mut builds: Vec<f64> = self.builds.iter().copied().collect();
                builds.sort_by(|a, b| a.partial_cmp(b).unwrap());
                let bn = builds.len();
                let bp50 = builds[bn / 2];
                let bmax = builds[bn - 1];
                eprintln!(
                    "[probe] frames n={n} avg={avg:.2}ms p50={p50:.2}ms p99={p99:.2}ms max={max:.2}ms | build n={bn} p50={bp50:.2}ms max={bmax:.2}ms"
                );
            }
        }
        window.request_animation_frame();

        let build_t0 = Instant::now();
        let parts = std::env::var("PROBE_PARTS").unwrap_or_else(|_| "both".into());
        let mut treemap_opt = None;
        let mut list_opt = None;
        if parts == "both" || parts == "tiles" {
            let mut treemap = Treemap::new("treemap");
            for (name, value) in self.tiles.iter() {
                treemap = treemap.tile(name.clone(), *value);
            }
            treemap_opt = Some(treemap.format(|v| human(v as u64)));
        }
        if parts == "both" || parts == "list" {
            list_opt = Some(ElyTree::new("tree", self.tree.clone()).open(["n0"]));
        }
        let build_ms = build_t0.elapsed().as_secs_f64() * 1e3;
        self.builds.push_back(build_ms);
        while self.builds.len() > 600 {
            self.builds.pop_front();
        }

        div()
            .flex()
            .flex_col()
            .size_full()
            .children(treemap_opt.map(|treemap| div().flex_1().child(treemap)))
            .children(list_opt.map(|list| div().h(px(280.)).child(list)))
            .child(FpsMeter::new("fps"))
    }
}
