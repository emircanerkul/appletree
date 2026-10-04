//! disktree runner: the same measurement contract as the AppleTree runner, so
//! the comparison is engine-versus-engine with identical accounting.
//!
//! disktree-core is pinned to tag `v0.10.1` because it is not published on
//! crates.io. Options are the upstream defaults, which is what the installed
//! disktree 0.10.1 app uses: allocated blocks (not apparent size), hidden files
//! included, one filesystem, hardlinks de-duplicated.

use std::path::Path;
use std::time::Instant;

use disktree_core::scan::{scan, ScanOptions};

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
    let path = std::env::args().nth(1).unwrap_or_else(|| usage());
    if path == "--help" || path == "-h" {
        usage();
    }
    let root = Path::new(&path);
    if !root.is_dir() {
        eprintln!("disktree-runner: not a directory: {path}");
        std::process::exit(2);
    }

    let options = ScanOptions::default();
    let start = Instant::now();
    let node = match scan(root, options) {
        Ok(node) => node,
        Err(err) => {
            eprintln!("disktree-runner: {err}");
            std::process::exit(2);
        }
    };
    let seconds = start.elapsed().as_secs_f64();
    let peak = peak_rss_bytes();

    // disktree reports errors per node as `read_error`; count them the same way
    // the parent counts AppleTree's, so the field means one thing.
    let errors = count_read_errors(&node);
    println!(
        "{{\"tool\":\"disktree\",\"seconds\":{seconds:.6},\"files\":{},\"dirs\":{},\"bytes\":{},\"errors\":{errors},\"peak_rss_bytes\":{peak}}}",
        node.files, node.dirs, node.bytes
    );
}

fn count_read_errors(node: &disktree_core::tree::Node) -> u64 {
    let mut total = u64::from(node.read_error);
    for child in &node.children {
        total += count_read_errors(child);
    }
    total
}

fn usage() -> ! {
    eprintln!("usage: disktree-runner <path>");
    std::process::exit(2);
}
