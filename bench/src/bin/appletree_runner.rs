//! AppleTree engine runner. One process, one scan, one line of JSON.
//!
//! Timing covers the engine call only (process start excluded), and peak RSS
//! is this process's own peak, so the parent can compare engines without the
//! two engines' memory being added together.

use std::path::Path;
use std::time::Instant;

use appletree::{scan, Progress};

/// Peak resident set size of this process, in bytes.
fn peak_rss_bytes() -> u64 {
    // SAFETY: `getrusage` fills the struct we own; RUSAGE_SELF is always valid.
    unsafe {
        let mut usage: libc::rusage = std::mem::zeroed();
        if libc::getrusage(libc::RUSAGE_SELF, &mut usage) != 0 {
            return 0;
        }
        usage.ru_maxrss as u64
    }
}

fn main() {
    let mut args = std::env::args().skip(1);
    let path = args.next().unwrap_or_else(|| usage());
    if path == "--help" || path == "-h" {
        usage();
    }
    let root = Path::new(&path);
    if !root.is_dir() {
        eprintln!("appletree-runner: not a directory: {path}");
        std::process::exit(2);
    }

    let progress = Progress::default();
    let start = Instant::now();
    let tree = scan(root, &progress);
    let seconds = start.elapsed().as_secs_f64();
    // Peak RSS is read after the scan but before the tree is dropped, so it
    // includes the live tree - the number that matters for a loaded UI.
    let peak = peak_rss_bytes();

    let dirs = progress.dirs.load(std::sync::atomic::Ordering::Relaxed);
    let errors = progress.entry_errors.load(std::sync::atomic::Ordering::Relaxed)
        + tree.errors;
    println!(
        "{{\"tool\":\"appletree\",\"seconds\":{seconds:.6},\"files\":{},\"dirs\":{dirs},\"bytes\":{},\"errors\":{errors},\"peak_rss_bytes\":{peak}}}",
        tree.n_files[0], tree.alloc[0]
    );
}

fn usage() -> ! {
    eprintln!("usage: appletree-runner <path>");
    std::process::exit(2);
}
