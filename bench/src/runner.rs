//! ABBA-alternated comparison of two engines over one target.
//!
//! Why alternate: cache warmth and background load drift over a run, and a
//! block of AppleTree runs followed by a block of disktree runs would charge
//! that drift to whichever engine ran second. Warmup runs are unmeasured.
//! Each engine runs in its own process (see the two runner binaries), so peak
//! memory per engine is real rather than the two engines' peaks combined.

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::host::Host;
use crate::jsonw::{get_f64, get_str, get_u64, parse_flat_object};

#[derive(Clone)]
pub struct Sample {
    pub tool: String,
    pub seconds: f64,
    pub files: u64,
    pub dirs: u64,
    pub bytes: u64,
    pub errors: u64,
    pub peak_rss_bytes: u64,
}

impl Sample {
    pub fn json(&self, round: Option<usize>) -> String {
        let round = round.map(|r| format!("\"round\":{r},")).unwrap_or_default();
        format!(
            "{{{round}\"tool\":\"{}\",\"seconds\":{:.6},\"files\":{},\"dirs\":{},\"bytes\":{},\"errors\":{},\"peak_rss_bytes\":{}}}",
            crate::jsonw::escape(&self.tool),
            self.seconds,
            self.files,
            self.dirs,
            self.bytes,
            self.errors,
            self.peak_rss_bytes
        )
    }
}

#[derive(Clone, Copy, PartialEq)]
pub enum Tool {
    Appletree,
    Disktree,
}

impl Tool {
    pub fn name(self) -> &'static str {
        match self {
            Tool::Appletree => "appletree",
            Tool::Disktree => "disktree",
        }
    }
}

pub struct Engines {
    pub appletree: PathBuf,
    pub disktree: Option<PathBuf>,
}

impl Engines {
    pub fn binary(&self, tool: Tool) -> Result<&Path, String> {
        match tool {
            Tool::Appletree => Ok(&self.appletree),
            Tool::Disktree => self
                .disktree
                .as_deref()
                .ok_or_else(|| "disktree runner not built (crate built without the disktree feature)".to_string()),
        }
    }
}

fn run_once(engines: &Engines, tool: Tool, target: &Path) -> Result<Sample, String> {
    let binary = engines.binary(tool)?;
    if !binary.exists() {
        return Err(format!("{} runner missing at {}", tool.name(), binary.display()));
    }
    let output = Command::new(binary)
        .arg(target)
        .output()
        .map_err(|e| format!("{}: {e}", binary.display()))?;
    if !output.status.success() {
        return Err(format!(
            "{} runner failed ({}): {}",
            tool.name(),
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let line = stdout
        .lines()
        .rev()
        .find(|l| l.trim_start().starts_with('{'))
        .ok_or_else(|| format!("{} runner printed no JSON: {stdout}", tool.name()))?;
    let pairs = parse_flat_object(line)
        .ok_or_else(|| format!("{} runner printed unparseable JSON: {line}", tool.name()))?;
    Ok(Sample {
        tool: get_str(&pairs, "tool").unwrap_or_else(|| tool.name().to_string()),
        seconds: get_f64(&pairs, "seconds").ok_or("missing seconds")?,
        files: get_u64(&pairs, "files").ok_or("missing files")?,
        dirs: get_u64(&pairs, "dirs").ok_or("missing dirs")?,
        bytes: get_u64(&pairs, "bytes").ok_or("missing bytes")?,
        errors: get_u64(&pairs, "errors").unwrap_or(0),
        peak_rss_bytes: get_u64(&pairs, "peak_rss_bytes").unwrap_or(0),
    })
}

pub struct Comparison {
    pub host: Host,
    pub target: String,
    pub tools: Vec<Tool>,
    pub runs: usize,
    pub measured: Vec<Sample>,
    pub totals_agree: bool,
    pub appletree: Summary,
    pub disktree: Option<Summary>,
    pub speedup: Option<f64>,
    pub rss_ratio: Option<f64>,
}

pub struct Summary {
    pub runs: usize,
    pub min_seconds: f64,
    pub median_seconds: f64,
    pub max_seconds: f64,
    pub median_peak_rss_bytes: u64,
    pub files: u64,
    pub dirs: u64,
    pub bytes: u64,
    pub errors: u64,
}

fn summarize(samples: &[Sample]) -> Summary {
    let mut times: Vec<f64> = samples.iter().map(|s| s.seconds).collect();
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let mut peaks: Vec<u64> = samples.iter().map(|s| s.peak_rss_bytes).collect();
    peaks.sort_unstable();
    let median = |v: &[f64]| {
        if v.len() % 2 == 1 { v[v.len() / 2] } else { (v[v.len() / 2 - 1] + v[v.len() / 2]) / 2.0 }
    };
    let first = &samples[0];
    Summary {
        runs: samples.len(),
        min_seconds: *times.first().unwrap(),
        median_seconds: median(&times),
        max_seconds: *times.last().unwrap(),
        // The engine's own process peak; summed totals would be meaningless.
        median_peak_rss_bytes: peaks[peaks.len() / 2],
        files: first.files,
        dirs: first.dirs,
        bytes: first.bytes,
        errors: first.errors,
    }
}

pub fn compare(engines: &Engines, target: &Path, runs: usize, warmup: usize) -> Result<Comparison, String> {
    if runs < 1 {
        return Err("--runs must be at least 1".into());
    }
    let tools: Vec<Tool> = match &engines.disktree {
        Some(_) => vec![Tool::Appletree, Tool::Disktree],
        None => vec![Tool::Appletree],
    };

    for _ in 0..warmup {
        for tool in &tools {
            run_once(engines, *tool, target)?;
        }
    }

    let mut measured = Vec::new();
    for round in 0..runs {
        // ABBA: even rounds AppleTree first, odd rounds disktree first.
        let order: Vec<Tool> = if round % 2 == 0 {
            tools.clone()
        } else {
            tools.iter().rev().copied().collect()
        };
        for tool in order {
            let sample = run_once(engines, tool, target)?;
            println!("{}", sample.json(Some(round + 1)));
            measured.push(sample);
        }
    }

    let appletree_samples: Vec<Sample> =
        measured.iter().filter(|s| s.tool == "appletree").cloned().collect();
    let disktree_samples: Vec<Sample> =
        measured.iter().filter(|s| s.tool == "disktree").cloned().collect();
    let appletree = summarize(&appletree_samples);
    let disktree = (!disktree_samples.is_empty()).then(|| summarize(&disktree_samples));

    // Correctness guardrail: equal allocated bytes is the invariant that makes a
    // speed comparison meaningful. Any disagreement is a hard failure.
    let totals_agree = match &disktree {
        Some(d) => d.bytes == appletree.bytes && d.errors == appletree.errors,
        None => true,
    };
    let speedup = disktree.as_ref().map(|d| d.median_seconds / appletree.median_seconds);
    let rss_ratio = disktree
        .as_ref()
        .filter(|_| appletree.median_peak_rss_bytes > 0)
        .map(|d| d.median_peak_rss_bytes as f64 / appletree.median_peak_rss_bytes as f64);

    Ok(Comparison {
        host: Host::detect(),
        target: target.display().to_string(),
        tools,
        runs,
        measured,
        totals_agree,
        appletree,
        disktree,
        speedup,
        rss_ratio,
    })
}
