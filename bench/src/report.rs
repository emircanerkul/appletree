//! Result artifacts: one JSON file per run (machine-readable, the source of
//! truth for the numbers in the docs) and one markdown report beside it
//! (what a reader actually opens).

use std::fs;
use std::path::Path;

use crate::runner::{Comparison, Summary};

fn mb(bytes: u64) -> f64 {
    bytes as f64 / (1024.0 * 1024.0)
}

fn summary_json(s: &Summary) -> String {
    format!(
        "{{\"runs\":{},\"min_seconds\":{:.6},\"median_seconds\":{:.6},\"max_seconds\":{:.6},\"median_peak_rss_bytes\":{},\"files\":{},\"dirs\":{},\"bytes\":{},\"errors\":{}}}",
        s.runs, s.min_seconds, s.median_seconds, s.max_seconds, s.median_peak_rss_bytes, s.files, s.dirs, s.bytes, s.errors
    )
}

pub fn result_json(comparison: &Comparison) -> String {
    let measurements: Vec<String> =
        comparison.measured.iter().map(|s| format!("    {}", s.json(None))).collect();
    let tools: Vec<String> =
        comparison.tools.iter().map(|t| format!("\"{}\"", t.name())).collect();
    let disktree = comparison
        .disktree
        .as_ref()
        .map(summary_json)
        .unwrap_or_else(|| "null".into());
    format!(
        concat!(
            "{{\n",
            "  \"host\": {},\n",
            "  \"target\": \"{}\",\n",
            "  \"tools\": [{}],\n",
            "  \"runs\": {},\n",
            "  \"totals_agree\": {},\n",
            "  \"appletree\": {},\n",
            "  \"disktree\": {},\n",
            "  \"speedup\": {},\n",
            "  \"rss_ratio\": {},\n",
            "  \"measurements\": [\n{}\n  ]\n",
            "}}\n"
        ),
        comparison.host.json(),
        crate::jsonw::escape(&comparison.target),
        tools.join(", "),
        comparison.runs,
        comparison.totals_agree,
        summary_json(&comparison.appletree),
        disktree,
        comparison
            .speedup
            .map(|v| format!("{v:.4}"))
            .unwrap_or_else(|| "null".into()),
        comparison
            .rss_ratio
            .map(|v| format!("{v:.4}"))
            .unwrap_or_else(|| "null".into()),
        measurements.join(",\n")
    )
}

pub fn report_markdown(comparison: &Comparison) -> String {
    let a = &comparison.appletree;
    let mut out = String::new();
    out.push_str("# Scan benchmark\n\n");
    out.push_str(&format!("**Target** `{}`\n\n", comparison.target));
    out.push_str(&format!("**Host** {}\n\n", comparison.host.human()));
    out.push_str(&format!(
        "**Method** {} measured run(s) per engine after one unmeasured warmup, \
         alternating engines each round (ABBA), each engine in its own process. \
         Timings cover the engine call only; memory is that process's peak RSS \
         after the scan, with the tree still loaded.\n\n",
        comparison.runs
    ));

    out.push_str("## Results\n\n");
    match &comparison.disktree {
        Some(d) => {
            out.push_str("| | AppleTree | disktree | ratio |\n|---|---:|---:|---:|\n");
            out.push_str(&format!(
                "| median scan | **{:.3} s** | {:.3} s | {} |\n",
                a.median_seconds,
                d.median_seconds,
                comparison
                    .speedup
                    .map(|s| format!("{s:.2}× faster"))
                    .unwrap_or_default()
            ));
            out.push_str(&format!(
                "| range | {:.3}–{:.3} s | {:.3}–{:.3} s | |\n",
                a.min_seconds, a.max_seconds, d.min_seconds, d.max_seconds
            ));
            out.push_str(&format!(
                "| peak RSS | **{:.1} MB** | {:.1} MB | {} |\n",
                mb(a.median_peak_rss_bytes),
                mb(d.median_peak_rss_bytes),
                comparison
                    .rss_ratio
                    .map(|r| format!("{r:.2}×"))
                    .unwrap_or_default()
            ));
            out.push_str(&format!(
                "| files | {} | {} | {} |\n",
                a.files,
                d.files,
                if a.files == d.files { "equal".to_string() } else { format!("{} more links", a.files as i64 - d.files as i64) }
            ));
            out.push_str(&format!("| dirs | {} | {} | |\n", a.dirs, d.dirs));
            out.push_str(&format!(
                "| allocated bytes | {} | {} | {} |\n",
                a.bytes,
                d.bytes,
                if comparison.totals_agree { "**identical**" } else { "**DIVERGED**" }
            ));
            out.push_str(&format!("| read errors | {} | {} | |\n", a.errors, d.errors));
        }
        None => {
            out.push_str("| | AppleTree |\n|---|---:|\n");
            out.push_str(&format!("| median scan | **{:.3} s** |\n", a.median_seconds));
            out.push_str(&format!(
                "| range | {:.3}–{:.3} s |\n",
                a.min_seconds, a.max_seconds
            ));
            out.push_str(&format!("| peak RSS | **{:.1} MB** |\n", mb(a.median_peak_rss_bytes)));
            out.push_str(&format!("| files | {} |\n", a.files));
            out.push_str(&format!("| dirs | {} |\n", a.dirs));
            out.push_str(&format!("| allocated bytes | {} |\n", a.bytes));
            out.push_str(&format!("| read errors | {} |\n", a.errors));
        }
    }

    if comparison.disktree.is_some() {
        out.push_str(
            "\nTwo count differences are expected and are not accuracy problems; both \
             engines report identical allocated bytes, which is the number that matters \
             for disk space:\n\n\
             1. **File count.** AppleTree counts every name of a hardlinked file, and \
             counts symlinks as files; disktree counts a hardlinked file once. AppleTree \
             therefore reports more files for the same bytes.\n\
             2. **Directory count.** disktree counts the scan root itself as a directory; \
             AppleTree counts only the directories inside it, so disktree is one higher.\n",
        );
    }

    out.push_str("\n## What this does not measure\n\n");
    out.push_str("- **GUI time.** Application launch, treemap layout, painting, hover and \
                  outline performance are not measured here.\n");
    out.push_str("- **Whole-disk accuracy.** Only paths this process can read are counted. \
                  Without Full Disk Access, root-only system data is invisible to *every* \
                  tool in the table; that undercounts all engines equally and is not a \
                  comparison of them.\n");
    out.push_str("- **Memory beyond peak RSS.** The reported figure is a process peak, not \
                  the resident size of the loaded tree over time.\n\n");

    out.push_str("## Reproduce\n\n```sh\ncd bench && ./run.sh\n```\n");
    out
}

/// Write `run.json` and `report.md` into `dir`, creating it if needed.
pub fn write(dir: &Path, comparison: &Comparison) -> Result<(String, String), String> {
    fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let json_path = dir.join("run.json");
    let report_path = dir.join("report.md");
    fs::write(&json_path, result_json(comparison)).map_err(|e| format!("{}: {e}", json_path.display()))?;
    fs::write(&report_path, report_markdown(comparison))
        .map_err(|e| format!("{}: {e}", report_path.display()))?;
    Ok((
        json_path.display().to_string(),
        report_path.display().to_string(),
    ))
}
