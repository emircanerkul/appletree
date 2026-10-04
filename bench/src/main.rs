//! btbench — AppleTree scan-engine benchmark.
//!
//! Compares the AppleTree scan engine against disktree (pinned headless
//! `disktree-core`), on synthetic fixtures or any readable folder, and writes
//! a report naming the machine it ran on.
//!
//! Typical use is `bench/run.sh`, which wraps this in one command.

mod apps;
mod fixture;
mod host;
mod jsonw;
mod report;
mod runner;

use std::path::{Path, PathBuf};

use runner::Engines;

const USAGE: &str = "\
btbench - AppleTree scan-engine benchmark

USAGE:
    btbench host
    btbench scan   [--path DIR] [--runs N] [--warmup N] [--out DIR] [--no-disktree]
                   [--compare-apps [--app-runs N] [--app-timeout SECS]]
    btbench fixture --size small|medium|large [--out DIR] [--seed N] [--force]
    btbench verify  --path DIR

COMMANDS:
    host      Print the host block (chip, RAM in GB, macOS version)
              --slug for the filesystem-safe form, --human for one line
    scan      Compare engines over one target and write run.json + report.md
    fixture   Create a deterministic synthetic tree with a manifest
    verify    Re-walk a fixture and confirm it still matches its manifest

OPTIONS:
    --path DIR      Target directory for scan/verify
    --runs N        Measured rounds per engine (default 5)
    --warmup N      Unmeasured warmup rounds per engine (default 1)
    --out DIR       Result directory (default docs/benchmarks/results/<date>-<host>)
    --size NAME     Fixture size: small, medium, large
    --seed N        Fixture seed (default 1)
    --force         Allow fixture to write into a non-empty directory
    --no-disktree   Skip the disktree comparison (AppleTree only)

    --compare-apps  Also drive the installed GUI apps (AppleTree, disktree,
                    GrandPerspective, QDirStat) and report their scan times.
                    Slower: each round launches real apps. Rows record where
                    each duration came from, because they are not the same
                    interval: AppleTree's GUI hook and the two closed-source
                    apps report their own finish time, while disktree's GUI
                    reports nothing and is timed externally.
    --app-runs N    Rounds per GUI app (default 3)
    --app-timeout S Per-app timeout in seconds (default 120)

EXAMPLES:
    btbench scan --path /Applications --runs 5
    btbench scan --path /Applications --compare-apps --app-runs 3
    btbench fixture --size small --out /tmp/btbench-small
    btbench verify --path /tmp/btbench-small
";

/// Result root: the repository's docs/benchmarks/results, resolved from this
/// source file so the binary works no matter where it is invoked from.
fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("bench/ has a parent")
        .to_path_buf()
}

fn default_out(host: &host::Host) -> PathBuf {
    let date = std::process::Command::new("date")
        .arg("+%Y-%m-%d")
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|| "undated".into());
    repo_root().join("docs/benchmarks/results").join(format!("{date}-{}", host.slug()))
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() || args[0] == "--help" || args[0] == "-h" {
        print!("{USAGE}");
        return;
    }
    let result = match args[0].as_str() {
        "host" => cmd_host(&args[1..]),
        "scan" => cmd_scan(&args[1..]),
        "fixture" => cmd_fixture(&args[1..]),
        "verify" => cmd_verify(&args[1..]),
        other => Err(format!("unknown command {other:?}; run `btbench --help`")),
    };
    if let Err(message) = result {
        eprintln!("btbench: {message}");
        std::process::exit(1);
    }
}

fn cmd_host(args: &[String]) -> Result<(), String> {
    let host = host::Host::detect();
    // `--slug` is the filesystem-safe form run.sh uses for result directories;
    // `--human` is the one-line form for terminal output.
    if has(args, "--slug") {
        println!("{}", host.slug());
    } else if has(args, "--human") {
        println!("{}", host.human());
    } else {
        println!("{}", host.json());
    }
    Ok(())
}

fn flag<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).map(String::as_str)
}

fn has(args: &[String], name: &str) -> bool {
    args.iter().any(|a| a == name)
}

fn number(args: &[String], name: &str, default: usize) -> Result<usize, String> {
    match flag(args, name) {
        None => Ok(default),
        Some(raw) => raw.parse().map_err(|_| format!("{name} must be a whole number, got {raw:?}")),
    }
}

fn cmd_scan(args: &[String]) -> Result<(), String> {
    let target = PathBuf::from(flag(args, "--path").unwrap_or("/Applications"));
    if !target.is_dir() {
        return Err(format!("--path is not a directory: {}", target.display()));
    }
    let runs = number(args, "--runs", 5)?;
    let warmup = number(args, "--warmup", 1)?;
    let host = host::Host::detect();
    let out = flag(args, "--out").map(PathBuf::from).unwrap_or_else(|| default_out(&host));

    let exe_dir = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(Path::to_path_buf))
        .ok_or("cannot locate the bench binaries")?;
    let disktree = if has(args, "--no-disktree") { None } else { Some(exe_dir.join("disktree-runner")) };
    let engines = Engines { appletree: exe_dir.join("appletree-runner"), disktree };

    eprintln!("btbench: target {}", target.display());
    eprintln!("btbench: host   {}", host.human());
    eprintln!("btbench: {} measured round(s) per engine, {warmup} warmup", runs);

    let comparison = runner::compare(&engines, &target, runs, warmup)?;
    let (json_path, report_path) = report::write(&out, &comparison)?;

    // GUI tier: opt-in, because it launches real apps and is far slower.
    if has(args, "--compare-apps") {
        let app_runs = number(args, "--app-runs", 3)?;
        let timeout_secs = number(args, "--app-timeout", 120)?;
        let gui = apps_report(&target, app_runs, timeout_secs)?;
        let gui_path = out.join("gui-comparison.md");
        std::fs::write(&gui_path, &gui).map_err(|e| format!("{}: {e}", gui_path.display()))?;
        println!();
        print!("{gui}");
        println!("gui report {}", gui_path.display());
    }

    let a = &comparison.appletree;
    println!();
    println!("AppleTree  median {:.3} s  ({:.3}–{:.3})  peak {:.1} MB", a.median_seconds, a.min_seconds, a.max_seconds, a.median_peak_rss_bytes as f64 / 1048576.0);
    if let Some(d) = &comparison.disktree {
        println!("disktree   median {:.3} s  ({:.3}–{:.3})  peak {:.1} MB", d.median_seconds, d.min_seconds, d.max_seconds, d.median_peak_rss_bytes as f64 / 1048576.0);
        if let Some(s) = comparison.speedup {
            println!("speedup    {s:.2}x");
        }
    }
    println!("report     {report_path}");
    println!("json       {json_path}");

    if !comparison.totals_agree {
        eprintln!();
        eprintln!(
            "btbench: totals diverged between engines. The filesystem likely changed during \
             the run, or an engine regressed. Re-run before comparing speed."
        );
        std::process::exit(1);
    }
    Ok(())
}

/// Drive every installed GUI app for `runs` rounds, round-robin, and build the
/// comparison table. Rounds are interleaved rather than grouped so a change in
/// background load cannot land on one app alone.
fn apps_report(target: &Path, runs: usize, timeout_secs: usize) -> Result<String, String> {
    if runs < 1 {
        return Err("--app-runs must be at least 1".into());
    }
    let specs = apps::discover();
    if specs.is_empty() {
        return Err("none of the known GUI apps are installed in /Applications".into());
    }
    let timeout = std::time::Duration::from_secs(timeout_secs.max(10) as u64);
    let mut samples: Vec<Vec<f64>> = vec![Vec::new(); specs.len()];
    let mut memories: Vec<Vec<u64>> = vec![Vec::new(); specs.len()];

    for round in 1..=runs {
        // Alternate direction each round, as the engine comparison does.
        let order: Vec<usize> = if round % 2 == 1 {
            (0..specs.len()).collect()
        } else {
            (0..specs.len()).rev().collect()
        };
        for index in order {
            let spec = &specs[index];
            eprintln!("btbench: gui round {round}/{runs} — {}", spec.name);
            let result = apps::measure(spec, target, timeout);
            match result.seconds {
                Some(seconds) => {
                    let rss = result
                        .peak_rss_bytes
                        .map(|b| format!("{b}"))
                        .unwrap_or_else(|| "null".into());
                    println!(
                        "  {{\"tool\":\"{}\",\"round\":{round},\"seconds\":{seconds:.6},\"peak_rss_bytes\":{rss},\"source\":\"{}\"}}",
                        result.tool,
                        result.source.label()
                    );
                    samples[index].push(seconds);
                    if let Some(bytes) = result.peak_rss_bytes {
                        memories[index].push(bytes);
                    }
                }
                None => println!(
                    "  {{\"tool\":\"{}\",\"round\":{round},\"seconds\":null,\"note\":\"{}\"}}",
                    result.tool,
                    crate::jsonw::escape(&result.note)
                ),
            }
        }
    }

    let mut out = String::new();
    out.push_str("# GUI-mode comparison\n\n");
    out.push_str(&format!(
        "**Target** `{}` · **rounds** {runs} per app, interleaved\n\n",
        target.display()
    ));
    out.push_str(&format!(
        "Every app was given the same target and the same number of rounds. Launching the bundle \
         through `open` makes launchd — not the terminal — the TCC-responsible process, so each \
         app's own Full Disk Access grant applies.\n\n\
         **These rows are not all the same interval.** The source column says where each duration \
         comes from; compare `app-reported` rows with each other, and treat the external row as an \
         upper bound rather than an equal measurement.\n\n\
         **Memory** is the peak resident set size. For AppleTree it is the kernel's own high-water \
         mark reported by the app itself. For the other apps it is sampled from outside every \
         {} ms while the scan runs, so it is a floor on the true peak and can miss a spike between \
         samples. It covers each app's whole process, UI included — which is why it is far larger \
         than the engine-tier figures, where RSS is measured in a process that never loads the UI.\n\n",
        apps::RSS_SAMPLE_MS,
    ));
    out.push_str("| app | measure | peak memory | source | rounds | note |\n|---|---:|---:|---|---:|---|\n");
    for (index, spec) in specs.iter().enumerate() {
        let values = &samples[index];
        if values.is_empty() {
            let memory = median_u64(&memories[index])
                .map(|b| format!("{:.1} MB", b as f64 / 1048576.0))
                .unwrap_or_else(|| "not measured".into());
            out.push_str(&format!(
                "| {} | not measured | {} | | 0 | see the run output above |\n",
                spec.name, memory
            ));
            continue;
        }
        let mut sorted = values.clone();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let median = if sorted.len() % 2 == 1 {
            sorted[sorted.len() / 2]
        } else {
            (sorted[sorted.len() / 2 - 1] + sorted[sorted.len() / 2]) / 2.0
        };
        let source = if spec.name == "disktree" { "external wall-clock" } else { "app-reported" };
        let note = if spec.name == "disktree" {
            "app prints no timing; timed until CPU idle, so not comparable to app-reported rows"
        } else {
            "app-written finish time"
        };
        let memory = median_u64(&memories[index])
            .map(|b| format!("**{:.1} MB**", b as f64 / 1048576.0))
            .unwrap_or_else(|| "not measured".into());
        out.push_str(&format!(
            "| {} | **{:.3} s** | {} | {} | {} | min {:.3} s, max {:.3} s — {} |\n",
            spec.name,
            median,
            memory,
            source,
            values.len(),
            sorted.first().unwrap(),
            sorted.last().unwrap(),
            note
        ));
    }
    Ok(out)
}

/// Median of a byte-count sample, or None when nothing was measured.
fn median_u64(values: &[u64]) -> Option<u64> {
    if values.is_empty() {
        return None;
    }
    let mut sorted = values.to_vec();
    sorted.sort_unstable();
    Some(if sorted.len() % 2 == 1 {
        sorted[sorted.len() / 2]
    } else {
        (sorted[sorted.len() / 2 - 1] + sorted[sorted.len() / 2]) / 2
    })
}

fn cmd_fixture(args: &[String]) -> Result<(), String> {
    let size = flag(args, "--size").unwrap_or("small");
    let out = PathBuf::from(flag(args, "--out").unwrap_or("/tmp/btbench-fixture"));
    let seed = flag(args, "--seed").and_then(|s| s.parse().ok()).unwrap_or(1u64);
    let manifest = fixture::create(&out, size, seed, has(args, "--force"))?;
    println!(
        "fixture {} at {}: {} dirs, {} files, {} logical bytes, {} hardlink name(s), {} symlink(s)",
        manifest.size, out.display(), manifest.dirs, manifest.files, manifest.logical_bytes,
        manifest.hardlink_names, manifest.symlinks
    );
    Ok(())
}

fn cmd_verify(args: &[String]) -> Result<(), String> {
    let path = PathBuf::from(flag(args, "--path").ok_or("verify needs --path DIR")?);
    let seen = fixture::verify(&path)?;
    println!(
        "ok: {} matches its manifest ({} dirs, {} files, {} logical bytes)",
        path.display(), seen.dirs, seen.files, seen.logical_bytes
    );
    Ok(())
}
