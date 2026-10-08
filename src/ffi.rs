//! C ABI for the Swift UI. A scan runs on background threads; the UI polls
//! progress counters, then receives the finished tree as flat arrays
//! (zero-copy: Swift reads the buffers in place until bz_free).

use std::ffi::{c_char, c_int, CStr, CString};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use crate::{cleanup, scan, Progress, Tree};

pub struct BzScan {
    progress: Arc<Progress>,
    done: Arc<AtomicBool>,
    result: Arc<std::sync::Mutex<Option<Flat>>>,
    // Kept alive for the lifetime of the handle; Swift holds raw pointers in.
    flat: Option<Box<Flat>>,
}

/// The scanned tree (already in the flat layout) plus Clean Up's candidates.
struct Flat {
    tree: Tree,
    cleanup_nodes: Vec<u32>,
    cleanup_descriptions: Vec<CString>,
}

fn with_cleanup(tree: Tree) -> Flat {
    let mut flat = Flat {
        tree,
        cleanup_nodes: Vec::new(),
        cleanup_descriptions: Vec::new(),
    };
    flat.refresh_cleanup();
    flat
}

impl Flat {
    /// Recompute Clean Up's candidate list from the current tree.
    ///
    /// Needed after `bz_remove_node`: the list holds node ids and the sizes it
    /// was built from are now stale, and removing a *recognized* folder can
    /// also un-prune candidates beneath it (`cleanup::find` never descends
    /// into one). This may reallocate `cleanup_nodes`, which is why the Swift
    /// side re-reads `bz_cleanup_nodes` on every access instead of caching the
    /// pointer.
    fn refresh_cleanup(&mut self) {
        let candidates = cleanup::find(&self.tree, cleanup::MIN_BYTES);
        self.cleanup_nodes.clear();
        self.cleanup_nodes.extend(candidates.iter().map(|c| c.node));
        self.cleanup_descriptions.clear();
        self.cleanup_descriptions.extend(
            candidates
                .iter()
                .map(|c| CString::new(c.kind.description()).expect("static cleanup label has no NUL")),
        );
    }
}

/// Start a scan on background threads. Returns a handle immediately.
#[no_mangle]
pub extern "C" fn bz_scan_start(path: *const c_char) -> *mut BzScan {
    let path = unsafe { CStr::from_ptr(path) };
    let path = PathBuf::from(String::from_utf8_lossy(path.to_bytes()).into_owned());

    let progress = Arc::new(Progress::default());
    let done = Arc::new(AtomicBool::new(false));
    let result = Arc::new(std::sync::Mutex::new(None));

    {
        let progress = progress.clone();
        let done = done.clone();
        let result = result.clone();
        std::thread::spawn(move || {
            unsafe { crate::set_thread_qos_user_interactive() };
            let t0 = std::time::Instant::now();
            let tree = scan(&path, &progress);
            let t1 = std::time::Instant::now();
            let flat = with_cleanup(tree);
            if std::env::var_os("BZ_TIMING").is_some() {
                eprintln!(
                    "[bz] scan {:.3}s  cleanup {:.1}ms",
                    (t1 - t0).as_secs_f64(),
                    t1.elapsed().as_secs_f64() * 1e3
                );
            }
            *result.lock().unwrap() = Some(flat);
            done.store(true, Ordering::Release);
        });
    }

    Box::into_raw(Box::new(BzScan {
        progress,
        done,
        result,
        flat: None,
    }))
}

#[no_mangle]
pub extern "C" fn bz_progress(
    h: *mut BzScan,
    files: *mut u64,
    dirs: *mut u64,
    bytes: *mut u64,
    done: *mut c_int,
) {
    let h = unsafe { &mut *h };
    unsafe {
        *files = h.progress.files.load(Ordering::Relaxed);
        *dirs = h.progress.dirs.load(Ordering::Relaxed);
        *bytes = h.progress.bytes.load(Ordering::Relaxed);
        *done = h.done.load(Ordering::Acquire) as c_int;
    }
}

/// After done: materialize the flat tree in the handle. Returns node count.
#[no_mangle]
pub extern "C" fn bz_take_tree(h: *mut BzScan) -> u64 {
    let h = unsafe { &mut *h };
    if h.flat.is_none() {
        if let Some(f) = h.result.lock().unwrap().take() {
            h.flat = Some(Box::new(f));
        }
    }
    h.flat.as_ref().map_or(0, |f| f.tree.len() as u64)
}

macro_rules! getter {
    ($name:ident, $field:ident, $ty:ty) => {
        #[no_mangle]
        pub extern "C" fn $name(h: *mut BzScan) -> *const $ty {
            let h = unsafe { &*h };
            h.flat
                .as_ref()
                .map_or(std::ptr::null(), |f| f.tree.$field.as_ptr())
        }
    };
}

getter!(bz_parents, parents, u32);
getter!(bz_alloc, alloc, u64);
getter!(bz_logical, logical, u64);
getter!(bz_nfiles, n_files, u32);
getter!(bz_flags, flags, u8);
getter!(bz_child_off, child_off, u32);
getter!(bz_children, children, u32);
getter!(bz_name_off, name_off, u32);
getter!(bz_name_blob, name_blob, u8);

/// # Safety
/// `h` must be a live scan handle, with no concurrent mutation or free.
#[no_mangle]
pub unsafe extern "C" fn bz_cleanup_count(h: *mut BzScan) -> u64 {
    let h = unsafe { &*h };
    h.flat.as_ref().map_or(0, |f| f.cleanup_nodes.len() as u64)
}

/// # Safety
/// `h` must be a live scan handle, with no concurrent mutation or free.
/// Read at most `bz_cleanup_count(h)` elements, before `bz_free(h)`.
#[no_mangle]
pub unsafe extern "C" fn bz_cleanup_nodes(h: *mut BzScan) -> *const u32 {
    let h = unsafe { &*h };
    h.flat
        .as_ref()
        .map_or(std::ptr::null(), |f| f.cleanup_nodes.as_ptr())
}

/// Label at a candidate-list index (not a tree node index), valid until bz_free.
///
/// # Safety
/// `h` must be a live scan handle, with no concurrent mutation or free.
#[no_mangle]
pub unsafe extern "C" fn bz_cleanup_description(h: *mut BzScan, index: u64) -> *const c_char {
    let h = unsafe { &*h };
    h.flat
        .as_ref()
        .and_then(|f| f.cleanup_descriptions.get(index as usize))
        .map_or(std::ptr::null(), |s| s.as_ptr())
}

/// NUL-terminated C copies of `cleanup::ALLOWLIST` plus the pointer array
/// exposed over the bridge. `&str` literals are not NUL-terminated, so the C
/// table cannot point at them directly. Initialized once, leaked for the
/// program's lifetime by design, never freed, unaffected by `bz_free`.
struct AllowlistTable {
    // Owns the NUL-terminated buffers; `pointers` only points into them. The
    // field is never read after initialization — it exists to keep the
    // buffers alive for the program's lifetime.
    #[allow(dead_code)]
    cstrings: Vec<CString>,
    pointers: Vec<*const c_char>,
}

// Safety: the pointers only reference buffers owned by `cstrings` in this
// struct, which is never mutated after initialization and never dropped.
unsafe impl Send for AllowlistTable {}
unsafe impl Sync for AllowlistTable {}

static ALLOWLIST_TABLE: std::sync::OnceLock<AllowlistTable> = std::sync::OnceLock::new();

/// The cleanup-command allowlist, single source of truth in `cleanup::ALLOWLIST`.
/// Entries stay valid for the program's lifetime and are never freed.
#[no_mangle]
pub extern "C" fn bz_cleanup_allowlist() -> *const *const c_char {
    let table = ALLOWLIST_TABLE.get_or_init(|| {
        let cstrings: Vec<CString> = cleanup::ALLOWLIST
            .iter()
            .map(|cmd| CString::new(*cmd).expect("allowlist command has no interior NUL"))
            .collect();
        let pointers = cstrings.iter().map(|s| s.as_ptr()).collect();
        AllowlistTable { cstrings, pointers }
    });
    table.pointers.as_ptr()
}

/// Number of commands in the allowlist; the count is authoritative (no
/// sentinel entry terminates the table).
#[no_mangle]
pub extern "C" fn bz_cleanup_allowlist_count() -> u64 {
    cleanup::ALLOWLIST.len() as u64
}

#[no_mangle]
pub extern "C" fn bz_errors(h: *mut BzScan) -> u64 {
    let h = unsafe { &*h };
    h.flat.as_ref().map_or(0, |f| f.tree.errors)
}

/// Drop a node's subtree from the finished tree, in place, after its path left
/// the scan root. Returns 1 on success, 0 for the root, an out-of-range index,
/// a node already removed, or a handle whose scan has not finished.
///
/// No `Vec` is reallocated, so the pointers earlier `bz_*` getters returned
/// stay valid, and no node is renumbered, so ids the Swift side holds (zoom,
/// selection, hover, plan cards) keep naming the same folders. Clean Up's
/// candidate list is recomputed because its sizes and membership both change.
///
/// # Safety
/// `h` must be a live scan handle from `bz_scan_start`, with no concurrent
/// access while this runs.
#[no_mangle]
pub unsafe extern "C" fn bz_remove_node(h: *mut BzScan, node: u64) -> c_int {
    let h = unsafe { &mut *h };
    let Some(flat) = h.flat.as_mut() else {
        return 0;
    };
    let removed = scan::remove_node(&mut flat.tree, node as usize);
    if removed {
        flat.refresh_cleanup();
    }
    removed as c_int
}

/// Resolve an absolute path (already normalized and scan-root-prefixed by the
/// Swift caller) to its node index; `u64::MAX` when any component is missing.
/// The root's name is the scanned path (e.g. "/System/Volumes/Data"), so the
/// path must equal it or extend it with "/"; matching starts after those
/// bytes. NSString normalization and the "/System/Volumes/Data" root-refix
/// stay Swift-side: this call takes the final, refixed path only. Matched
/// against the UTF-8 name blob, no allocation per component.
///
/// # Safety
/// `h` must be a live scan handle obtained from `bz_scan_start`, with no
/// concurrent mutation or free; `path` must point to a NUL-terminated UTF-8
/// string that is only read during the call. A null `path` or a handle whose
/// scan has not finished yet (no flat tree) returns `u64::MAX` rather than
/// crashing.
#[no_mangle]
pub unsafe extern "C" fn bz_node_at_path(h: *mut BzScan, path: *const c_char) -> u64 {
    const NOT_FOUND: u64 = u64::MAX;
    if path.is_null() {
        return NOT_FOUND;
    }
    let path = unsafe { CStr::from_ptr(path) }.to_bytes();
    let Some(flat) = (unsafe { &*h }).flat.as_ref() else {
        return NOT_FOUND;
    };
    let tree = &flat.tree;
    // Mirror Swift path(0): the root's name minus one trailing slash (a "/"
    // scan reads as ""), so the prefix rule below is uniform for every root.
    let root = tree.name_bytes(0);
    let root = if root.ends_with(b"/") { &root[..root.len() - 1] } else { root };
    let rest = if path == root {
        &[][..]
    } else if path.len() > root.len() && path.starts_with(root) && path[root.len()] == b'/' {
        &path[root.len() + 1..]
    } else {
        return NOT_FOUND;
    };
    let mut cur = 0usize;
    'components: for part in rest.split(|&b| b == b'/').filter(|p| !p.is_empty()) {
        for &child in tree.kids(cur) {
            if tree.name_bytes(child as usize) == part {
                cur = child as usize;
                continue 'components;
            }
        }
        return NOT_FOUND;
    }
    cur as u64
}

#[no_mangle]
pub extern "C" fn bz_free(h: *mut BzScan) {
    if !h.is_null() {
        drop(unsafe { Box::from_raw(h) });
    }
}


#[cfg(test)]
mod tests {
    use super::*;
    use crate::NO_PARENT;

    #[test]
    fn bridge_exposes_the_shared_candidates_and_labels() {
        for bytes in [0, cleanup::MIN_BYTES] {
            let mut tree = Tree::with_root("/root");
            tree.push("node_modules", 0, bytes, bytes, true);
            (tree.alloc[0], tree.logical[0]) = (bytes, bytes);
            tree.link_children();
            assert_eq!(tree.parents, [NO_PARENT, 0]);
            let expected = cleanup::find(&tree, cleanup::MIN_BYTES);
            assert_eq!(expected.len(), (bytes > 0) as usize);
            let mut handle = BzScan {
                progress: Arc::new(Progress::default()),
                done: Arc::new(AtomicBool::new(true)),
                result: Arc::new(std::sync::Mutex::new(None)),
                flat: Some(Box::new(with_cleanup(tree))),
            };
            let h = &mut handle as *mut BzScan;
            assert_eq!(unsafe { bz_cleanup_count(h) } as usize, expected.len());
            let nodes = unsafe { std::slice::from_raw_parts(bz_cleanup_nodes(h), expected.len()) };
            for (i, candidate) in expected.iter().enumerate() {
                assert_eq!(nodes[i], candidate.node);
                let label = unsafe { CStr::from_ptr(bz_cleanup_description(h, i as u64)) };
                assert_eq!(label.to_str().unwrap(), candidate.kind.description());
            }
            assert!(unsafe { bz_cleanup_description(h, expected.len() as u64) }.is_null());
        }
    }

    #[test]
    fn allowlist_round_trips_through_the_bridge() {
        let count = bz_cleanup_allowlist_count();
        assert_eq!(count as usize, cleanup::ALLOWLIST.len());
        // No duplicates: a repeated entry would widen nothing but would show a
        // command twice in the agent prompt.
        assert_eq!(
            cleanup::ALLOWLIST.iter().collect::<std::collections::HashSet<_>>().len(),
            cleanup::ALLOWLIST.len()
        );
        let table = bz_cleanup_allowlist();
        assert!(!table.is_null());
        for (i, expected) in cleanup::ALLOWLIST.iter().enumerate() {
            let ptr = unsafe { *table.add(i) };
            assert!(!ptr.is_null());
            let cmd = unsafe { CStr::from_ptr(ptr) };
            assert_eq!(cmd.to_str().unwrap(), *expected);
        }
        // Known commands that must stay allowed, and one that must not appear.
        for known in ["uv cache prune", "brew cleanup --prune=all", "gem cleanup"] {
            assert!(cleanup::ALLOWLIST.contains(&known));
        }
        assert!(!cleanup::ALLOWLIST.contains(&"rm -rf /"));
        // The retired cache-clean forms (see `cleanup::ALLOWLIST`): each one's
        // target is a cache folder `CACHE_RULES` now nominates, so the folder
        // carries the capability and the command was the `exec` dependency the
        // App Store sandbox cannot honour.
        for retired in ["uv cache clean", "bun pm cache rm", "pip cache purge",
                        "pip3 cache purge", "pod cache clean --all"] {
            assert!(!cleanup::ALLOWLIST.contains(&retired), "{retired} should be retired");
        }
        // Entries are individually NUL-terminated C strings: each stops at its
        // own terminator rather than running into the next command's bytes.
        let last = unsafe { CStr::from_ptr(*table.add(count as usize - 1)) };
        assert_eq!(last.to_bytes(), b"gem cleanup");
    }

    /// Port of the deleted Swift `Tree.node(at:)` extension (Agent.swift,
    /// removed in T4), kept as the differential oracle: the engine must agree
    /// with the algorithm it replaced. `children`/`name` mirror the Swift
    /// accessors over the same flat arrays; the `path(0)` trailing-slash
    /// strip on the root name is Swift-specific and reproduced here.
    fn swift_node_at_path(tree: &Tree, path: &str) -> Option<u64> {
        let root_name = tree.name(0);
        let root = root_name.strip_suffix('/').unwrap_or(root_name);
        let prefix = if root == "/" { "/".to_string() } else { format!("{root}/") };
        if path != root && !path.starts_with(&prefix) {
            return None;
        }
        let mut cur = 0usize;
        for part in path[root.len()..].split('/').filter(|p| !p.is_empty()) {
            let next = tree
                .kids(cur)
                .iter()
                .find(|&&c| tree.name(c as usize) == part)
                .copied()?;
            cur = next as usize;
        }
        Some(cur as u64)
    }

    fn scan_handle(tree: Tree) -> BzScan {
        BzScan {
            progress: Arc::new(Progress::default()),
            done: Arc::new(AtomicBool::new(true)),
            result: Arc::new(std::sync::Mutex::new(None)),
            flat: Some(Box::new(Flat { tree, cleanup_nodes: Vec::new(), cleanup_descriptions: Vec::new() })),
        }
    }

    fn at_path(h: *mut BzScan, path: &str) -> Option<u64> {
        let p = CString::new(path).unwrap();
        let r = unsafe { bz_node_at_path(h, p.as_ptr()) };
        (r != u64::MAX).then_some(r)
    }

    #[test]
    fn node_at_path_matches_the_old_swift_algorithm() {
        let mut tree = Tree::with_root("/Users/me"); // scanned path, no strip
        // Each directory's children go in one contiguous batch (run-based link).
        let d = tree.push("Library", 0, 0, 0, true);
        let _dot = tree.push("trailing.dot.", 0, 1, 1, false);
        let _jp = tree.push("日本語フォルダ", d, 20, 20, true); // UTF-8
        let c = tree.push("Caches", d, 0, 0, true);
        let deep = tree.push("com.example App", c, 10, 10, false); // space
        tree.link_children();

        let mut handle = scan_handle(tree);
        let h = &mut handle as *mut BzScan;
        let cases = [
            ("/Users/me", Some(0)),                     // the root itself
            ("/Users/me/", Some(0)),                    // root with trailing slash
            ("/Users/me/Library", Some(1)),
            ("/Users/me/trailing.dot.", Some(2)),
            ("/Users/me/Library/日本語フォルダ", Some(3)),
            ("/Users/me/日本語フォルダ", None),   // it lives under Library
            ("/Users/me/Library/Caches", Some(4)),
            ("/Users/me/Library/Caches/com.example App", Some(deep as u64)),
            ("/Users/me/Library/Caches/../Caches", None), // not normalized here
            ("/Users/me/Library/Missing", None),        // missing component
            ("/Users/me/Library/Caches/com.example App/x", None), // past a file
            ("/Users/me//Library", Some(1)),            // empty component, tolerated
            ("/", None),                                // other filesystem root
            ("/Users", None),                           // proper prefix of root
            ("/Users/meX", None),                       // near-miss root
            ("", None),                                 // empty path
            ("relative/path", None),                    // not absolute-prefixed
        ];
        for path in cases {
            assert_eq!(at_path(h, path.0), path.1, "path {:?}", path.0);
            assert_eq!(
                at_path(h, path.0),
                swift_node_at_path(&handle.flat.as_ref().unwrap().tree, path.0),
                "oracle disagrees on {:?}",
                path.0
            );
        }
        assert_eq!(unsafe { bz_node_at_path(h, std::ptr::null()) }, u64::MAX);
    }

    #[test]
    fn node_at_path_supports_slash_roots_and_data_refix() {
        // A "/" scan: Swift path(0) strips the trailing slash to "", so the
        // prefix rule degenerates to "starts with /" — the engine mirrors it.
        let mut tree = Tree::with_root("/");
        let d = tree.push("usr", 0, 0, 0, true);
        tree.push("bin", d, 5, 5, true);
        tree.link_children();
        let mut handle = scan_handle(tree);
        let h = &mut handle as *mut BzScan;
        for path in ["/", "//", "/usr", "/usr/bin"] {
            assert_eq!(
                at_path(h, path),
                swift_node_at_path(&handle.flat.as_ref().unwrap().tree, path),
                "oracle disagrees on {path}"
            );
        }
        assert_eq!(at_path(h, "/"), Some(0));
        assert_eq!(at_path(h, "//"), Some(0));
        assert_eq!(at_path(h, "/usr/bin"), Some(2));
        assert_eq!(at_path(h, "/usr/nope"), None);

        // The Data root-refix result: Swift prepends "/System/Volumes/Data"
        // when a caller path misses it, then calls here with the refixed path.
        let mut tree = Tree::with_root("/System/Volumes/Data");
        tree.push("Users", 0, 0, 0, true);
        tree.link_children();
        let mut handle = scan_handle(tree);
        let h = &mut handle as *mut BzScan;
        assert_eq!(at_path(h, "/System/Volumes/Data/Users"), Some(1));
        assert_eq!(
            at_path(h, "/System/Volumes/Data"),
            swift_node_at_path(&handle.flat.as_ref().unwrap().tree, "/System/Volumes/Data")
        );
        assert_eq!(at_path(h, "/Users"), None); // unrefixed caller path: miss

        // Non-degenerate trailing-slash root: `AppleTree /Users/me/` on the
        // CLI makes name(0) == "/Users/me/" — the strip branch must fire for
        // more than just "/".
        let mut tree = Tree::with_root("/Users/me/");
        tree.push("docs", 0, 0, 0, true);
        tree.link_children();
        let mut handle = scan_handle(tree);
        let h = &mut handle as *mut BzScan;
        assert_eq!(at_path(h, "/Users/me"), Some(0)); // stripped root matches
        assert_eq!(at_path(h, "/Users/me/docs"), Some(1));
        assert_eq!(
            at_path(h, "/Users/me/docs"),
            swift_node_at_path(&handle.flat.as_ref().unwrap().tree, "/Users/me/docs")
        );
    }
}
