//! Ultra-fast APFS directory tree scanner using getattrlistbulk(2).
//!
//! getattrlistbulk returns a whole batch of directory entries *with* their
//! metadata (name, type, sizes) per syscall, so we never pay the classic
//! readdir-then-stat-per-file cost that makes naive scanners slow on macOS.

pub mod cleanup;
pub mod ffi;

mod attrs;
mod scan;

use std::ffi::{c_int, CString};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

use scan::{finish, read_dir_bulk, walk, Arena, SCRATCH, Shared};

/// Contents live in the cloud (iCloud Drive, File Provider). Opening such a
/// directory asks the provider to materialize it, i.e. download.
const SF_DATALESS: u32 = 0x4000_0000;

// ---- Tree model ----

pub const NO_PARENT: u32 = u32::MAX;

/// The finished tree as flat arrays, the layout the Swift UI reads in place
/// (see app/bz.h). Node 0 is the root; children come after their parent.
#[derive(Default)]
#[cfg_attr(test, derive(Debug, PartialEq, Eq))]
pub struct Tree {
    pub parents: Vec<u32>,
    /// Allocated (on-disk) bytes; subtree totals for directories.
    pub alloc: Vec<u64>,
    /// Logical bytes; subtree totals for directories.
    pub logical: Vec<u64>,
    /// Subtree file count for directories, 0 for files.
    pub n_files: Vec<u32>,
    pub flags: Vec<u8>, // bit0 = is_dir
    /// False when an entry was unreadable or a cloud/mount boundary was skipped
    /// anywhere in this subtree. The observed sizes then describe a partial walk.
    pub complete: Vec<bool>,
    /// Node i's children are children[child_off[i]..child_off[i + 1]],
    /// largest allocated size first (treemap layout order).
    pub child_off: Vec<u32>,
    pub children: Vec<u32>,
    /// Node i's name is name_blob[name_off[i]..name_off[i + 1]], UTF-8.
    pub name_off: Vec<u32>,
    pub name_blob: Vec<u8>,
    pub errors: u64,
}

impl Tree {
    pub fn len(&self) -> usize {
        self.parents.len()
    }
    pub fn is_empty(&self) -> bool {
        self.parents.is_empty()
    }
    pub fn is_dir(&self, i: usize) -> bool {
        self.flags[i] & 1 != 0
    }
    pub fn kids(&self, i: usize) -> &[u32] {
        &self.children[self.child_off[i] as usize..self.child_off[i + 1] as usize]
    }
    pub(crate) fn name_bytes(&self, i: usize) -> &[u8] {
        &self.name_blob[self.name_off[i] as usize..self.name_off[i + 1] as usize]
    }
    /// Names are validated UTF-8 when scanned.
    pub fn name(&self, i: usize) -> &str {
        std::str::from_utf8(self.name_bytes(i)).unwrap_or("")
    }
    /// Node `i`'s path from the root.
    ///
    /// Stops at the root **or at a detached node**. `remove_node` (see
    /// `scan::remove_node`) cuts a subtree by setting the removed node's parent
    /// to `NO_PARENT`, and its descendants keep pointing at each other. A loop
    /// that stopped only on `0` therefore walked into `parents[u32::MAX]` and
    /// panicked with "index out of bounds: the len is 4 but the index is
    /// 4294967295" — reachable from the GUI's own refresh path, where
    /// `bz_remove_node` recomputes Clean Up's list and this is called in the
    /// sort comparator (audit RE-2).
    ///
    /// The Swift mirror has always carried this guard (`app/Model.swift`, the
    /// `tree.parents[cur] == UInt32.max` break) — this is the copy that was
    /// missing it. A detached node reports the path it still has, which is what
    /// every other accessor documents; whether that node is still reachable is
    /// `isAttached`'s question, not this one's.
    pub fn path(&self, mut i: usize) -> PathBuf {
        let mut parts = Vec::new();
        while i != 0 && i != NO_PARENT as usize {
            parts.push(self.name(i));
            i = self.parents[i] as usize;
        }
        let mut path = PathBuf::from(self.name(0));
        for part in parts.into_iter().rev() {
            path.push(part);
        }
        path
    }
    /// Path components from the root, compared as `str`s compare (bytewise).
    pub(crate) fn path_parts(&self, mut i: u32) -> Vec<&[u8]> {
        let mut parts = Vec::new();
        while i != NO_PARENT {
            parts.push(self.name_bytes(i as usize));
            i = self.parents[i as usize];
        }
        parts.reverse();
        parts
    }
}

#[derive(Default)]
pub struct Progress {
    pub files: AtomicU64,
    pub dirs: AtomicU64,
    pub bytes: AtomicU64,
    pub errors: AtomicU64,
    pub entry_errors: AtomicU64,
    pub invalid_names: AtomicU64,
    pub skipped_cloud_dirs: AtomicU64,
    pub skipped_mount_points: AtomicU64,
}

extern "C" {
    fn pthread_set_qos_class_self_np(qos_class: u32, relative_priority: c_int) -> c_int;
}
const QOS_CLASS_USER_INTERACTIVE: u32 = 0x21;

/// # Safety
/// Only affects the calling thread's scheduling class.
pub unsafe fn set_thread_qos_user_interactive() {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
}

const QOS_CLASS_USER_INITIATED: u32 = 0x19;

/// Rayon pool whose workers run at USER_INITIATED QoS. That still puts them
/// on the performance cores inside a GUI app (at the app's default QoS they
/// land on efficiency cores and scan twice as slowly), and it scans as fast
/// as USER_INTERACTIVE did, but it no longer outranks the UI and the system
/// compositor: at USER_INTERACTIVE a worker on every core made the window
/// (and screen recordings) skip frames for a quarter second mid-scan.
fn fast_pool() -> rayon::ThreadPool {
    rayon::ThreadPoolBuilder::new()
        .start_handler(|_| unsafe {
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
        })
        .build()
        .expect("thread pool")
}

/// Scan `root` and return the finished tree, ready for the UI.
pub fn scan(root: &Path, progress: &Progress) -> Tree {
    let root_name = root.to_string_lossy();
    let tree = Tree {
        parents: vec![NO_PARENT],
        alloc: vec![0],
        logical: vec![0],
        flags: vec![1],
        complete: vec![true],
        name_off: vec![0, root_name.len() as u32],
        name_blob: root_name.as_bytes().to_vec(),
        ..Default::default()
    };
    let shared = Shared {
        arena: Mutex::new(Arena {
            tree,
            hardlinks: std::collections::HashMap::new(),
        }),
        progress,
    };

    let t0 = std::time::Instant::now();
    use std::os::macos::fs::MetadataExt;
    let root_is_cloud_only =
        std::fs::symlink_metadata(root).is_ok_and(|m| m.st_flags() & SF_DATALESS != 0);
    if root_is_cloud_only {
        progress.skipped_cloud_dirs.fetch_add(1, Ordering::Relaxed);
        shared.mark_incomplete(0);
    } else if let Ok(path) = CString::new(root.as_os_str().as_encoded_bytes()) {
        // Open the root once and hand the walk a descriptor. Descending goes
        // through `openat(2)` from there, so no path is ever rebuilt and the
        // walk is not capped at `PATH_MAX` (audit RE-3).
        match scan::open_dir(&path) {
            Some(fd) => fast_pool().scope(|s| walk(s, &shared, fd, 0)),
            None => {
                progress.errors.fetch_add(1, Ordering::Relaxed);
                shared.mark_incomplete(0);
            }
        }
    } else {
        progress.errors.fetch_add(1, Ordering::Relaxed);
        shared.mark_incomplete(0);
    }
    let t1 = std::time::Instant::now();
    let mut tree = shared.arena.into_inner().unwrap().tree;
    finish(&mut tree);
    tree.errors = progress.errors.load(Ordering::Relaxed);
    if std::env::var_os("BZ_TIMING").is_some() {
        eprintln!(
            "[bz] walk {:.3}s  finish {:.1}ms  ({} nodes)",
            (t1 - t0).as_secs_f64(),
            t1.elapsed().as_secs_f64() * 1e3,
            tree.len()
        );
    }
    tree
}

/// Count-only walk with no tree building: measures the pure syscall floor.
pub fn scan_count(root: &Path, progress: &Progress) {
    fn go<'s>(scope: &rayon::Scope<'s>, progress: &'s Progress, dir_fd: c_int) {
        SCRATCH.with_borrow_mut(|s| {
            if read_dir_bulk(dir_fd, s, progress).is_none() {
                unsafe { libc::close(dir_fd) };
                return;
            }
            let (mut start, mut n_files, mut n_dirs, mut bytes) = (0, 0u64, 0u64, 0u64);
            for e in &s.entries {
                if e.is_dir {
                    n_dirs += 1;
                    if e.descend() {
                        if let Some(fd) = scan::open_at(dir_fd, &s.names[start..e.name_end as usize]) {
                            scope.spawn(move |sc| go(sc, progress, fd));
                        }
                    }
                } else {
                    n_files += 1;
                    bytes += e.alloc;
                }
                start = e.name_end as usize;
            }
            progress.files.fetch_add(n_files, Ordering::Relaxed);
            progress.dirs.fetch_add(n_dirs, Ordering::Relaxed);
            progress.bytes.fetch_add(bytes, Ordering::Relaxed);
            unsafe { libc::close(dir_fd) };
        });
    }
    if let Ok(path) = CString::new(root.as_os_str().as_encoded_bytes()) {
        if let Some(fd) = scan::open_dir(&path) {
            rayon::scope(|s| go(s, progress, fd));
        }
    }
}
