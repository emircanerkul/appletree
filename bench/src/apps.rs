//! GUI-mode runners for the `--compare-apps` tier.
//!
//! bench/ measures an engine by calling it. The GUI apps cannot be called that
//! way: GrandPerspective and QDirStat are closed-source apps that report their
//! own scan duration (stderr and a log file respectively), disktree 0.10.1
//! reports nothing at all, and AppleTree's GUI duration comes from a
//! preference-gated hook in app/Model.swift.
//!
//! Every number therefore carries its `TimingSource`. A reader must be able to
//! see that one row is the app's own finish time and another is an external
//! wall-clock guess, rather than assuming all four measure the same interval.
//!
//! Fairness rules enforced here:
//!   - the same target and the same number of rounds for every app;
//!   - apps that can single-instance safely are launched the same way, and any
//!     deviation is recorded in the row's note;
//!   - an app that cannot be measured says so. It is never dropped silently and
//!     never given an invented number.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

/// Where a tool's duration comes from. Printed with every result because the
/// intervals are not identical across tools.
#[derive(Clone, Copy, PartialEq)]
pub enum TimingSource {
    /// The app itself reports when its scan finished.
    AppReported,
    /// Measured from outside: wall-clock until the process stopped using CPU.
    ExternalWallClock,
}

impl TimingSource {
    pub fn label(self) -> &'static str {
        match self {
            TimingSource::AppReported => "app-reported",
            TimingSource::ExternalWallClock => "external wall-clock",
        }
    }
}

pub struct AppResult {
    pub tool: String,
    pub seconds: Option<f64>,
    /// Peak resident set size seen while the app scanned. Sampled, so it is a
    /// floor on the true peak; the sample interval is stated in `note`.
    pub peak_rss_bytes: Option<u64>,
    pub source: TimingSource,
    pub note: String,
}

impl AppResult {
    fn missing(tool: &str, source: TimingSource, note: impl Into<String>) -> Self {
        AppResult {
            tool: tool.to_string(),
            seconds: None,
            peak_rss_bytes: None,
            source,
            note: note.into(),
        }
    }
}

pub struct AppSpec {
    pub name: &'static str,
    pub path: PathBuf,
}

impl AppSpec {
    /// The executable inside the bundle.
    fn binary(&self) -> Option<PathBuf> {
        let macos = self.path.join("Contents/MacOS");
        let mut candidates: Vec<PathBuf> = std::fs::read_dir(&macos)
            .ok()?
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.is_file())
            .collect();
        candidates.sort();
        candidates
            .iter()
            .find(|p| {
                p.file_name()
                    .map(|n| n.to_string_lossy().starts_with(self.name))
                    .unwrap_or(false)
            })
            .or_else(|| candidates.first())
            .cloned()
    }
}

pub fn discover() -> Vec<AppSpec> {
    [
        ("AppleTree", "/Applications/AppleTree.app"),
        ("disktree", "/Applications/disktree.app"),
        ("GrandPerspective", "/Applications/GrandPerspective.app"),
        ("QDirStat", "/Applications/QDirStat.app"),
    ]
    .into_iter()
    .filter(|(_, path)| Path::new(path).exists())
    .map(|(name, path)| AppSpec { name, path: PathBuf::from(path) })
    .collect()
}

/// Whether this process can see the paths AppleTree's FDA gate probes. Reported
/// with the AppleTree row so a reader knows which mode produced it.
fn fda_visible() -> bool {
    let home = std::env::var("HOME").unwrap_or_default();
    ["Library/Messages", "Library/Mail", "Library/Safari"]
        .iter()
        .any(|p| std::fs::read_dir(format!("{home}/{p}")).is_ok())
}

/// Total CPU time used by `pid` so far, or None once it has exited.
fn cpu_seconds(pid: i32) -> Option<f64> {
    let out = Command::new("ps").args(["-o", "time=", "-p", &pid.to_string()]).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let text = text.trim();
    if text.is_empty() {
        return None;
    }
    // ps prints [[dd-]hh:]mm:ss
    if let Some((days, rest)) = text.split_once('-') {
        let days: f64 = days.parse().ok()?;
        return parse_hms(rest, days * 86_400.0);
    }
    parse_hms(text, 0.0)
}

/// Resident set size of `pid` in bytes, or None once it has exited.
fn rss_bytes(pid: i32) -> Option<u64> {
    let out = Command::new("ps").args(["-o", "rss=", "-p", &pid.to_string()]).output().ok()?;
    if !out.status.success() {
        return None;
    }
    // ps reports RSS in KiB.
    String::from_utf8_lossy(&out.stdout).trim().parse::<u64>().ok().map(|kb| kb * 1024)
}

/// Samples `pid`'s RSS in a background thread until `stop` flips, returning the
/// largest value seen. Sampling (rather than reading the kernel's high-water
/// mark) is what `ps` can offer for a foreign process; it can miss a spike
/// between samples, so the result is a floor and the interval is reported.
fn watch_rss(pid: i32, stop: std::sync::Arc<std::sync::atomic::AtomicBool>, interval: Duration) -> std::thread::JoinHandle<u64> {
    std::thread::spawn(move || {
        use std::sync::atomic::Ordering;
        let mut peak = 0u64;
        while !stop.load(Ordering::Relaxed) {
            if let Some(bytes) = rss_bytes(pid) {
                peak = peak.max(bytes);
            } else {
                break;
            }
            std::thread::sleep(interval);
        }
        peak.max(rss_bytes(pid).unwrap_or(0))
    })
}

/// How often a foreign app's RSS is sampled while it scans. Sets the resolution
/// of the memory figure, which is reported as a floor for that reason.
pub const RSS_SAMPLE_MS: u64 = 50;

fn parse_hms(text: &str, base: f64) -> Option<f64> {
    let parts: Vec<&str> = text.split(':').collect();
    let mut seconds = base;
    for (index, part) in parts.iter().enumerate() {
        let value: f64 = part.parse().ok()?;
        seconds += value * 60f64.powi((parts.len() - 1 - index) as i32);
    }
    Some(seconds)
}

/// How often the idle detector samples, and how long the process must stay idle
/// before its scan is called finished. These two set the resolution: a scan
/// shorter than roughly `TICK * IDLE_SAMPLES` cannot be distinguished from an
/// instant one, and callers must say so rather than report the floor as a time.
const TICK: Duration = Duration::from_millis(100);
const IDLE_SAMPLES: u32 = 4;

fn external_resolution_secs() -> f64 {
    TICK.as_secs_f64() * IDLE_SAMPLES as f64
}

/// Wait until the process stops consuming CPU, i.e. its scan is over.
///
/// Returns `(seconds, at_resolution_floor)`. The flag is set when the result is
/// within one tick of the detector's own floor, because then the honest reading
/// is "finished about as soon as it started", not the number returned.
fn wait_until_idle(pid: i32, timeout: Duration) -> Option<(f64, bool)> {
    let started = Instant::now();
    let mut previous = cpu_seconds(pid)?;
    let mut idle_ticks = 0;
    loop {
        if started.elapsed() > timeout {
            return None;
        }
        std::thread::sleep(TICK);
        match cpu_seconds(pid) {
            None => {
                let secs = started.elapsed().as_secs_f64();
                return Some((secs, secs <= external_resolution_secs() + TICK.as_secs_f64()));
            }
            Some(current) => {
                // CPU time is quantised to 10 ms ticks, so treat "no measurable
                // growth" as idle rather than comparing to a fraction of a core.
                let busy = current - previous >= 0.005;
                previous = current;
                idle_ticks = if busy { 0 } else { idle_ticks + 1 };
                if idle_ticks >= IDLE_SAMPLES {
                    let secs = started.elapsed().as_secs_f64();
                    return Some((secs, secs <= external_resolution_secs() + TICK.as_secs_f64()));
                }
            }
        }
    }
}

fn pkill(name: &str) {
    let _ = Command::new("pkill").args(["-x", name]).output();
    std::thread::sleep(Duration::from_millis(400));
}

fn kill(pid: i32) {
    let _ = Command::new("kill").arg(pid.to_string()).output();
    std::thread::sleep(Duration::from_millis(300));
    let _ = Command::new("kill").args(["-9", &pid.to_string()]).output();
}

/// `defaults write <domain> <key> -bool true` must pass two separate argv
/// entries: passing `"-bool true"` as one argument stores the literal string,
/// which `UserDefaults.bool(forKey:)` then reads as false.
fn defaults_write_bool(domain: &str, key: &str, value: bool) -> Result<(), String> {
    let status = Command::new("defaults")
        .args(["write", domain, key, "-bool", if value { "true" } else { "false" }])
        .status()
        .map_err(|e| format!("defaults write {key}: {e}"))?;
    status.success().then_some(()).ok_or_else(|| format!("defaults write {key} failed"))
}

fn defaults_write_string(domain: &str, key: &str, value: &str) -> Result<(), String> {
    let status = Command::new("defaults")
        .args(["write", domain, key, "-string", value])
        .status()
        .map_err(|e| format!("defaults write {key}: {e}"))?;
    status.success().then_some(()).ok_or_else(|| format!("defaults write {key} failed"))
}

/// AppleTree's preference domain.
const APPLETREE_DOMAIN: &str = "dev.emircan.appletree";

fn export_domain(domain: &str, plist: &Path) -> Result<(), String> {
    let status = Command::new("defaults")
        .args(["export", domain])
        .arg(plist)
        .status()
        .map_err(|e| format!("defaults export {domain}: {e}"))?;
    status.success().then_some(()).ok_or_else(|| format!("defaults export {domain} failed"))
}

fn import_domain(domain: &str, plist: &Path) -> Result<(), String> {
    let status = Command::new("defaults")
        .args(["import", domain])
        .arg(plist)
        .status()
        .map_err(|e| format!("defaults import {domain}: {e}"))?;
    status.success().then_some(()).ok_or_else(|| format!("defaults import {domain} failed"))
}

/// True when the exported plist holds no keys.
///
/// `defaults export` of a domain with nothing in it writes a valid but empty
/// *binary* plist, and `defaults import` rejects that document outright. An
/// empty snapshot therefore means "the domain must end up empty", not "import
/// this". The export is binary, so `plutil` is what reads it back.
fn plist_is_empty(plist: &Path) -> bool {
    let output = Command::new("plutil")
        .args(["-convert", "json", "-o", "-"])
        .arg(plist)
        .output();
    match output {
        // An unreadable snapshot is not empty: import it and let the failure
        // surface rather than silently discarding the user's preferences.
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).trim() == "{}",
        _ => false,
    }
}

/// The whole preference domain, captured before a run so it can be put back.
///
/// The GUI tier has to change preferences the *user* also owns: a
/// LaunchServices-launched app receives no environment and no usable argv, so
/// `defaults write` is the only channel into it. That makes the harness
/// responsible for undoing its writes. `bz.benchExit` in particular is not a
/// harmless leftover — it makes every later launch quit on its own 0.2 s after
/// the scan lands, which a user reads as "the app closed when the scan
/// finished".
///
/// The snapshot covers the whole domain rather than the six keys written here,
/// because that is what makes the restore exact; key-level `defaults export`
/// returns an empty plist, and any change to the key set cannot silently
/// escape the restore.
///
/// Restores on drop, so an early `?` or an error return cannot leak a
/// preference either. It carries its own domain so the restore can never be
/// aimed at a different one than the capture.
struct DomainSnapshot {
    domain: String,
    plist: PathBuf,
    dir: PathBuf,
}

impl DomainSnapshot {
    /// Capture the domain exactly as it stands, including keys that are absent.
    fn take(domain: &str) -> Result<Self, String> {
        let dir = std::env::temp_dir().join(format!("btbench-prefs-{}", std::process::id()));
        std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        let plist = dir.join("snapshot.plist");
        export_domain(domain, &plist)?;
        Ok(Self { domain: domain.to_string(), plist, dir })
    }

    fn restore(&self) -> Result<(), String> {
        // `defaults import` merges, so it would leave every key the run added
        // behind. Delete first: the domain then ends exactly as it started,
        // empty domain included. Safe because the app is killed before the
        // caller drops this, so nothing can write a live value back.
        let _ = Command::new("defaults").args(["delete", &self.domain]).status();
        // A domain that started empty has nothing to import.
        if plist_is_empty(&self.plist) {
            return Ok(());
        }
        import_domain(&self.domain, &self.plist)
    }
}

impl Drop for DomainSnapshot {
    fn drop(&mut self) {
        let _ = self.restore();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// Launch a bundle through launchd. Running the binary straight from a shell
/// makes *this* process TCC-responsible, so the app's own Full Disk Access
/// grant would not apply; `open` avoids that.
fn launch_bundle(app: &AppSpec) -> Result<(), String> {
    let status = Command::new("open")
        .arg("-a")
        .arg(&app.path)
        .status()
        .map_err(|e| format!("open -a: {e}"))?;
    status.success().then_some(()).ok_or_else(|| format!("open -a {} failed", app.path.display()))
}

fn spawn_capturing(binary: &Path, args: &[&str], log: &Path) -> Result<i32, String> {
    let file = std::fs::File::create(log).map_err(|e| format!("{}: {e}", log.display()))?;
    let errors = file.try_clone().map_err(|e| e.to_string())?;
    let child = Command::new(binary)
        .args(args)
        .stdout(std::process::Stdio::from(file))
        .stderr(std::process::Stdio::from(errors))
        .spawn()
        .map_err(|e| format!("{}: {e}", binary.display()))?;
    Ok(child.id() as i32)
}

/// Poll a file for a line containing `marker`, returning the first number found
/// after it. `after_last` handles lines like GrandPerspective's
/// `Done scanning: 42410 folders scanned (0 skipped) in 4.33s.`, where the first
/// number after the marker is a folder count and the duration comes later.
fn poll_log_for(log: &Path, marker: &str, after_last: bool, timeout: Duration) -> Option<f64> {
    let started = Instant::now();
    while started.elapsed() < timeout {
        std::thread::sleep(Duration::from_millis(200));
        if let Ok(text) = std::fs::read_to_string(log) {
            if let Some(line) = text.lines().find(|l| l.contains(marker)) {
                let tail = line.split(marker).nth(1)?;
                let fragment = if after_last { tail.rsplit(" in ").next()? } else { tail };
                if let Some(number) = extract_seconds(fragment) {
                    return Some(number);
                }
            }
        }
    }
    None
}

/// Pull the first float out of a fragment like ` 4.33s.` or ` 9.027 sec`.
fn extract_seconds(fragment: &str) -> Option<f64> {
    let mut token = String::new();
    for c in fragment.chars() {
        if c.is_ascii_digit() || (c == '.' && !token.is_empty()) {
            token.push(c);
        } else if !token.is_empty() {
            break;
        }
    }
    token.parse().ok()
}

pub fn measure(app: &AppSpec, target: &Path, timeout: Duration) -> AppResult {
    let outcome = match app.name {
        "AppleTree" => measure_appletree(app, target, timeout),
        "disktree" => measure_disktree(app, target, timeout),
        "GrandPerspective" => measure_grandperspective(app, target, timeout),
        "QDirStat" => measure_qdirstat(app, target, timeout),
        other => Err(format!("no runner implemented for {other}")),
    };
    outcome.unwrap_or_else(|e| AppResult::missing(app.name, TimingSource::AppReported, e))
}

/// AppleTree writes its own finish time through the preference hook, so this is
/// the engine's real duration, not a launch-to-quiet guess.
fn measure_appletree(app: &AppSpec, target: &Path, timeout: Duration) -> Result<AppResult, String> {
    let result_path = std::env::temp_dir().join("btbench-appletree-gui.json");
    let _ = std::fs::remove_file(&result_path);

    pkill("AppleTree");
    // Every preference written below is the user's, not ours: capture the
    // domain now and put it back when this function returns, on the early
    // error paths included. Without this the run leaves `bz.benchExit` set and
    // AppleTree quits itself after every later scan.
    let saved = DomainSnapshot::take(APPLETREE_DOMAIN)?;

    defaults_write_bool(APPLETREE_DOMAIN, "bz.benchTiming", true)?;
    defaults_write_bool(APPLETREE_DOMAIN, "bz.benchExit", true)?;
    defaults_write_string(APPLETREE_DOMAIN, "bz.benchResult", &result_path.to_string_lossy())?;
    // The app only scans at launch when autoScan is on, and scans scanRoot.
    defaults_write_bool(APPLETREE_DOMAIN, "bz.autoScan", true)?;
    defaults_write_string(APPLETREE_DOMAIN, "bz.scanRoot", &target.to_string_lossy())?;

    // A previous run's trail is restored at launch and wins over scanRoot, so
    // point both at the target.
    let trail = format!("(\"{}\")", target.display());
    let _ = Command::new("defaults")
        .args(["write", APPLETREE_DOMAIN, "bz.trail", &trail])
        .status();
    launch_bundle(app)?;
    // `open` returns before the app is ready; give it a moment to start.
    std::thread::sleep(Duration::from_millis(700));

    if let Some(seconds) = poll_log_for(&result_path, "BZ_BENCH", false, timeout) {
        pkill("AppleTree");
        // Restore before reading the result back: the run is over, and a
        // leftover `bz.benchExit` must not survive even a later panic here.
        drop(saved);
        let fda = if fda_visible() { "FDA visible" } else { "no FDA for this shell" };
        let reported = std::fs::read_to_string(&result_path)
            .ok()
            .and_then(|t| t.lines().find(|l| l.contains("BZ_BENCH")).map(str::to_string))
            .and_then(|l| crate::jsonw::parse_flat_object(l.trim_start_matches("BZ_BENCH").trim()));
        // The app reports the kernel's own high-water mark, a real peak;
        // sampling from outside could only be a worse estimate.
        let peak_rss = reported.as_ref().and_then(|p| crate::jsonw::get_u64(p, "peak_rss_bytes"));
        return Ok(AppResult {
            tool: app.name.to_string(),
            seconds: Some(seconds),
            peak_rss_bytes: peak_rss,
            source: TimingSource::AppReported,
            note: format!("app-written finish time ({fda}); peak RSS from the app"),
        });
    }
    pkill("AppleTree");
    Err("no result: grant Full Disk Access to /Applications/AppleTree.app and relaunch".into())
}

/// GrandPerspective NSLogs `Done scanning: N folders scanned (0 skipped) in Xs`.
/// It writes to stderr, which launchd does not expose, so it is launched
/// directly with stderr captured to a file. A readable target needs no FDA.
fn measure_grandperspective(
    app: &AppSpec,
    target: &Path,
    timeout: Duration,
) -> Result<AppResult, String> {
    let binary = app.binary().ok_or("no executable in bundle")?;
    let log = std::env::temp_dir().join("btbench-grandperspective.log");
    pkill("GrandPerspective");
    let pid = spawn_capturing(&binary, &[&target.to_string_lossy()], &log)?;
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let watcher = watch_rss(pid, std::sync::Arc::clone(&stop), Duration::from_millis(RSS_SAMPLE_MS));

    let seconds = poll_log_for(&log, "Done scanning:", true, timeout);
    // The GUI stays open after scanning, so stop it once the line is in hand.
    let _ = wait_until_idle(pid, Duration::from_secs(10));
    kill(pid);
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    let peak_rss = watcher.join().unwrap_or(0);
    let peak_rss = (peak_rss > 0).then_some(peak_rss);

    Ok(AppResult {
        tool: app.name.to_string(),
        seconds,
        peak_rss_bytes: peak_rss,
        source: TimingSource::AppReported,
        note: if seconds.is_some() {
            "app-written finish time (stderr)".into()
        } else {
            "app printed no finish line".into()
        },
    })
}

/// QDirStat writes `Reading finished after X sec` to its log file.
fn measure_qdirstat(app: &AppSpec, target: &Path, timeout: Duration) -> Result<AppResult, String> {
    let binary = app.binary().ok_or("no executable in bundle")?;
    let home = std::env::var("HOME").unwrap_or_default();
    let user = home.rsplit('/').next().unwrap_or("user").to_string();
    let log = PathBuf::from(format!("/tmp/qdirstat-{user}/qdirstat.log"));
    let _ = std::fs::remove_file(&log);

    pkill("QDirStat");
    let pid = spawn_capturing(&binary, &["--dont-ask", &target.to_string_lossy()], &log)?;
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let watcher = watch_rss(pid, std::sync::Arc::clone(&stop), Duration::from_millis(RSS_SAMPLE_MS));

    let seconds = poll_log_for(&log, "Reading finished after", false, timeout);
    kill(pid);
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    let peak_rss = watcher.join().unwrap_or(0);
    let peak_rss = (peak_rss > 0).then_some(peak_rss);

    Ok(AppResult {
        tool: app.name.to_string(),
        seconds,
        peak_rss_bytes: peak_rss,
        source: TimingSource::AppReported,
        note: if seconds.is_some() {
            "app-written finish time (log)".into()
        } else {
            "no finish line in log".into()
        },
    })
}

/// disktree 0.10.1's GUI prints nothing anywhere, so its duration can only be
/// measured from outside: until it stops using CPU. Labelled external for
/// exactly that reason.
fn measure_disktree(app: &AppSpec, target: &Path, timeout: Duration) -> Result<AppResult, String> {
    let binary = app.binary().ok_or("no executable in bundle")?;
    let log = std::env::temp_dir().join("btbench-disktree.log");
    pkill("disktree");
    let pid = spawn_capturing(&binary, &[&target.to_string_lossy()], &log)?;
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let watcher = watch_rss(pid, std::sync::Arc::clone(&stop), Duration::from_millis(RSS_SAMPLE_MS));

    // Grace period: the process is starting up and using no CPU yet.
    std::thread::sleep(Duration::from_millis(250));
    let measured = wait_until_idle(pid, timeout);
    kill(pid);
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    let peak_rss = watcher.join().unwrap_or(0);
    let peak_rss = (peak_rss > 0).then_some(peak_rss);

    let resolution = external_resolution_secs();
    let (seconds, note) = match measured {
        Some((_, true)) => (
            None,
            format!(
                "finish was below the external detector's {resolution:.1}s resolution; the app                  reports no timing, so this row cannot be measured externally"
            ),
        ),
        Some((secs, _)) => (
            Some(secs),
            format!(
                "app reports nothing; external wall-clock until CPU idle, resolution ~{resolution:.1}s                  — an upper bound, not equal to app-reported rows"
            ),
        ),
        None => (None, format!("did not go idle within {}s", timeout.as_secs())),
    };
    Ok(AppResult {
        tool: app.name.to_string(),
        seconds,
        peak_rss_bytes: peak_rss,
        source: TimingSource::ExternalWallClock,
        note,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_ps_cpu_time_formats() {
        assert_eq!(parse_hms("00:01.50", 0.0), Some(1.5));
        assert_eq!(parse_hms("01:00", 0.0), Some(60.0));
        assert_eq!(parse_hms("00:00:02", 0.0), Some(2.0));
        assert_eq!(parse_hms("02:00", 86_400.0), Some(86_520.0));
    }

    #[test]
    fn extracts_seconds_from_log_fragments() {
        assert_eq!(extract_seconds(" 4.33s."), Some(4.33));
        assert_eq!(extract_seconds(" 9.027 sec"), Some(9.027));
        assert_eq!(extract_seconds("nope"), None);
    }

    /// The bug this guards: the harness writes `bz.benchExit`, and a run that
    /// does not restore it leaves AppleTree quitting itself after every scan.
    /// Uses a scratch domain so the test cannot touch the real preferences.
    #[test]
    fn domain_snapshot_restores_every_key_including_added_ones() {
        let domain = "dev.emircan.appletree.btbench-test";

        let preexisting = Command::new("defaults")
            .args(["write", domain, "bz.listWidth", "-float", "390"])
            .status()
            .expect("defaults write");
        assert!(preexisting.success());

        let snapshot = DomainSnapshot::take(domain).expect("snapshot");
        assert!(snapshot.plist.exists(), "snapshot must hold a plist");

        // What a bench run does to the user's domain.
        for key in ["bz.benchTiming", "bz.benchExit", "bz.autoScan"] {
            defaults_write_bool(domain, key, true).ok();
        }
        defaults_write_string(domain, "bz.scanRoot", "/Applications").ok();

        snapshot.restore().expect("restore");

        let read = Command::new("defaults").args(["read", domain, "bz.benchExit"]).output();
        let read = read.expect("defaults read");
        assert!(
            !read.status.success(),
            "bz.benchExit must be gone after a restore, got {:?}",
            String::from_utf8_lossy(&read.stdout)
        );
        let kept = Command::new("defaults").args(["read", domain, "bz.listWidth"]).output();
        let kept = kept.expect("defaults read");
        assert!(
            String::from_utf8_lossy(&kept.stdout).trim().starts_with("390"),
            "the user's own preference must survive the restore"
        );

        // A snapshot of a domain that does not exist restores to empty, not to
        // error: the case a first-ever bench run hits. The domain is left
        // deleted, which `defaults read` can report either as an error or as an
        // empty dictionary, so assert the semantic result instead of the status.
        let _ = Command::new("defaults").args(["delete", domain]).status();
        let missing = DomainSnapshot::take(domain).expect("snapshot of missing domain");
        defaults_write_bool(domain, "bz.benchExit", true).ok();
        missing.restore().expect("restore of missing domain");
        let after = Command::new("defaults").args(["export", domain]).arg(&missing.plist).output();
        let after = after.expect("defaults export");
        assert!(after.status.success());
        assert!(
            plist_is_empty(&missing.plist),
            "an empty snapshot must restore an empty domain"
        );

        let _ = Command::new("defaults").args(["delete", domain]).status();
    }
}
