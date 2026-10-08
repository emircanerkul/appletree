//! The getattrlistbulk parallel scanner: entry parsing, the directory walk,
//! and the finish/link passes that turn the walked arrays into a `Tree`.
//!
//! `lib.rs` owns the public entry points (`scan`, `scan_count`) and the tree
//! model; this module holds the machinery behind them.

use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::{c_int, c_void, CStr, CString};
use std::sync::atomic::Ordering;
use std::sync::Mutex;

use crate::attrs::{i64_at, u32_at, u64_at, AttrList};
use crate::{Progress, Tree, NO_PARENT, SF_DATALESS};

// ---- FFI: getattrlistbulk ----

extern "C" {
    fn getattrlistbulk(
        dirfd: c_int,
        attr_list: *mut AttrList,
        attr_buf: *mut c_void,
        attr_buf_size: usize,
        options: u64,
    ) -> c_int;
}

const ATTR_BIT_MAP_COUNT: u16 = 5;
const ATTR_CMN_NAME: u32 = 0x0000_0001;
const ATTR_CMN_DEVID: u32 = 0x0000_0002;
const ATTR_CMN_OBJTYPE: u32 = 0x0000_0008;
const ATTR_CMN_FLAGS: u32 = 0x0004_0000;
const ATTR_CMN_FILEID: u32 = 0x0200_0000;
const ATTR_CMN_ERROR: u32 = 0x2000_0000;
const ATTR_CMN_RETURNED_ATTRS: u32 = 0x8000_0000;
const ATTR_DIR_MOUNTSTATUS: u32 = 0x0000_0004;
const DIR_MNTSTATUS_MNTPOINT: u32 = 0x0000_0001;
const ATTR_FILE_LINKCOUNT: u32 = 0x0000_0001;
const ATTR_FILE_TOTALSIZE: u32 = 0x0000_0002;
const ATTR_FILE_ALLOCSIZE: u32 = 0x0000_0004;

const VDIR: u32 = 2;

const BUF_SIZE: usize = 256 * 1024;

pub(crate) struct Entry {
    /// End of this entry's name in `Scratch::names` (it starts where the
    /// previous one ends).
    pub(crate) name_end: u32,
    pub(crate) is_dir: bool,
    /// Contents live in the cloud; not descended (that would download them).
    dataless: bool,
    /// Another volume is mounted here (a disk image, Recovery, a simulator
    /// runtime, autofs). Not descended: a scan measures one volume.
    mount_point: bool,
    pub(crate) size: u64,
    pub(crate) alloc: u64,
    /// `(device, file id)` when the file has more than one hard link.
    hardlink: Option<(u32, u64)>,
}

impl Entry {
    pub(crate) fn descend(&self) -> bool {
        self.is_dir && !self.dataless && !self.mount_point
    }
}

/// Per-thread buffers reused for every directory, so reading one allocates nothing.
#[derive(Default)]
pub(crate) struct Scratch {
    buf: Vec<u8>,
    pub(crate) entries: Vec<Entry>,
    pub(crate) names: Vec<u8>,
}

thread_local! {
    pub(crate) static SCRATCH: RefCell<Scratch> = RefCell::default();
}

/// Read all entries of the directory behind `fd` in bulk into `s`. None if it
/// can't be read, else whether every entry was read.
///
/// The descriptor belongs to the caller: this reads through it and does **not**
/// close it, so `walk` owns the lifetime and closes it once — including on the
/// early-return paths, which a `close` here would make a double close.
pub(crate) fn read_dir_bulk(fd: c_int, s: &mut Scratch, progress: &Progress) -> Option<bool> {
    s.entries.clear();
    s.names.clear();
    if s.buf.is_empty() {
        s.buf = vec![0u8; BUF_SIZE];
    }
    if fd < 0 {
        progress.errors.fetch_add(1, Ordering::Relaxed);
        return None;
    }

    let mut attrlist = AttrList {
        bitmapcount: ATTR_BIT_MAP_COUNT,
        reserved: 0,
        commonattr: ATTR_CMN_RETURNED_ATTRS
            | ATTR_CMN_ERROR
            | ATTR_CMN_NAME
            | ATTR_CMN_DEVID
            | ATTR_CMN_OBJTYPE
            | ATTR_CMN_FLAGS
            | ATTR_CMN_FILEID,
        volattr: 0,
        dirattr: ATTR_DIR_MOUNTSTATUS,
        fileattr: ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE,
        forkattr: 0,
    };

    let mut complete = true;
    loop {
        let n = unsafe {
            getattrlistbulk(
                fd,
                &mut attrlist,
                s.buf.as_mut_ptr() as *mut c_void,
                BUF_SIZE,
                0,
            )
        };
        if n <= 0 {
            if n < 0 {
                progress.errors.fetch_add(1, Ordering::Relaxed);
                complete = false;
            }
            break;
        }
        let mut off = 0usize;
        for _ in 0..n {
            let len = u32_at(&s.buf, off) as usize;
            complete &= parse_entry(&s.buf[off..off + len], &mut s.entries, &mut s.names, progress);
            off += len;
        }
    }
    Some(complete)
}

/// Parse one getattrlistbulk entry. Attribute order within an entry is fixed:
/// RETURNED_ATTRS, ERROR, then common attrs by bit (NAME, DEVID, OBJTYPE,
/// FLAGS, FILEID), then dir attrs (MOUNTSTATUS), then file attrs (LINKCOUNT,
/// TOTALSIZE, ALLOCSIZE). Dir attrs come back only for directories and file
/// attrs only for files. False (and counted) if the entry had to be dropped.
pub(crate) fn parse_entry(
    e: &[u8],
    out: &mut Vec<Entry>,
    names: &mut Vec<u8>,
    progress: &Progress,
) -> bool {
    let mut off = 4usize; // skip length
    let ret_common = u32_at(e, off);
    let ret_dir = u32_at(e, off + 8);
    let ret_file = u32_at(e, off + 12);
    off += 20; // attribute_set_t: 5 x u32

    if ret_common & ATTR_CMN_ERROR != 0 {
        let err = u32_at(e, off);
        off += 4;
        if err != 0 {
            progress.entry_errors.fetch_add(1, Ordering::Relaxed);
            progress.errors.fetch_add(1, Ordering::Relaxed);
            return false;
        }
    }

    let invalid_name = || {
        progress.invalid_names.fetch_add(1, Ordering::Relaxed);
        progress.errors.fetch_add(1, Ordering::Relaxed);
        false
    };
    let mut name: &[u8] = &[];
    if ret_common & ATTR_CMN_NAME != 0 {
        let data_off = u32_at(e, off) as i32 as isize;
        let data_len = u32_at(e, off + 4) as usize;
        let start = (off as isize + data_off) as usize;
        // data_len includes the trailing NUL
        name = &e[start..start + data_len.saturating_sub(1)];
        if std::str::from_utf8(name).is_err() {
            return invalid_name();
        }
        off += 8;
    }

    let mut dev = 0u32;
    if ret_common & ATTR_CMN_DEVID != 0 {
        dev = u32_at(e, off);
        off += 4;
    }

    let mut is_dir = false;
    if ret_common & ATTR_CMN_OBJTYPE != 0 {
        is_dir = u32_at(e, off) == VDIR;
        off += 4;
    }

    let mut flags = 0u32;
    if ret_common & ATTR_CMN_FLAGS != 0 {
        flags = u32_at(e, off);
        off += 4;
    }

    let mut file_id = 0u64;
    if ret_common & ATTR_CMN_FILEID != 0 {
        file_id = u64_at(e, off);
        off += 8;
    }

    let mut mount_point = false;
    if ret_dir & ATTR_DIR_MOUNTSTATUS != 0 {
        mount_point = u32_at(e, off) & DIR_MNTSTATUS_MNTPOINT != 0;
        off += 4;
    }

    let mut links = 1u32;
    if ret_file & ATTR_FILE_LINKCOUNT != 0 {
        links = u32_at(e, off);
        off += 4;
    }

    let mut size = 0u64;
    let mut alloc = 0u64;
    if ret_file & ATTR_FILE_TOTALSIZE != 0 {
        size = i64_at(e, off).max(0) as u64;
        off += 8;
    }
    if ret_file & ATTR_FILE_ALLOCSIZE != 0 {
        alloc = i64_at(e, off).max(0) as u64;
    }

    if name.is_empty() {
        return invalid_name();
    }
    names.extend_from_slice(name);
    out.push(Entry {
        name_end: names.len() as u32,
        is_dir,
        dataless: flags & SF_DATALESS != 0,
        mount_point,
        size,
        alloc,
        hardlink: (!is_dir && links > 1).then_some((dev, file_id)),
    });
    true
}

// ---- Parallel walk ----

/// The tree as the walk grows it: every field of `Tree` except n_files,
/// child_off and children, which `finish` derives. A directory's entries are
/// appended under one short lock, so its children get one contiguous run of
/// indices, and no node owns a heap allocation.
pub(crate) struct Arena {
    pub(crate) tree: Tree,
    /// Attribute an inode's bytes to its lexicographically first scanned path,
    /// independently of worker scheduling. This is accounting, not an estimate
    /// of how many bytes deleting any one of its links would reclaim.
    pub(crate) hardlinks: HashMap<(u32, u64), u32>,
}

impl Arena {
    /// Called under the arena lock after appending a file, before totals are
    /// aggregated. Returns newly accounted bytes for the progress counter.
    pub(crate) fn account_file(&mut self, i: u32, hardlink: Option<(u32, u64)>) -> u64 {
        let t = &mut self.tree;
        let Some(key) = hardlink else {
            return t.alloc[i as usize];
        };
        let Some(&previous) = self.hardlinks.get(&key) else {
            self.hardlinks.insert(key, i);
            return t.alloc[i as usize];
        };
        let (i, previous) = (i as usize, previous as usize);
        let loser = if t.path_parts(i as u32) < t.path_parts(previous as u32) {
            t.logical[i] = t.logical[previous];
            t.alloc[i] = t.alloc[previous];
            self.hardlinks.insert(key, i as u32);
            previous
        } else {
            i
        };
        t.logical[loser] = 0;
        t.alloc[loser] = 0;
        0
    }
}

pub(crate) struct Shared<'a> {
    pub(crate) arena: Mutex<Arena>,
    pub(crate) progress: &'a Progress,
}

impl Shared<'_> {
    pub(crate) fn mark_incomplete(&self, i: u32) {
        self.arena.lock().unwrap().tree.complete[i as usize] = false;
    }
}

/// Walk one directory, given its **open descriptor**.
///
/// The descriptor is owned by this call and closed before it returns, on every
/// path. Descending by fd rather than by absolute path is what removes the
/// `PATH_MAX` cap (see the descent in the loop below).
pub(crate) fn walk<'s>(
    scope: &rayon::Scope<'s>,
    shared: &'s Shared<'s>,
    dir_fd: c_int,
    dir_idx: u32,
) {
    // Nothing below runs another job on this thread (spawn only queues), so
    // the borrow can't nest.
    SCRATCH.with_borrow_mut(|s| {
        let progress = shared.progress;
        let Some(complete) = read_dir_bulk(dir_fd, s, progress) else {
            shared.mark_incomplete(dir_idx);
            unsafe { libc::close(dir_fd) };
            return;
        };
        let Scratch { entries, names, .. } = s;
        if entries.is_empty() {
            if !complete {
                shared.mark_incomplete(dir_idx);
            }
            unsafe { libc::close(dir_fd) };
            return;
        }

        let mut n_files = 0u64;
        let mut n_dirs = 0u64;
        for e in entries.iter() {
            if !e.is_dir {
                n_files += 1;
                continue;
            }
            n_dirs += 1;
            if e.mount_point {
                progress.skipped_mount_points.fetch_add(1, Ordering::Relaxed);
            } else if e.dataless {
                progress.skipped_cloud_dirs.fetch_add(1, Ordering::Relaxed);
            }
        }
        progress.files.fetch_add(n_files, Ordering::Relaxed);
        progress.dirs.fetch_add(n_dirs, Ordering::Relaxed);

        let (base, bytes) = {
            let mut arena = shared.arena.lock().unwrap();
            let t = &mut arena.tree;
            t.complete[dir_idx as usize] = complete;
            let base = t.parents.len() as u32;
            t.parents.extend(std::iter::repeat_n(dir_idx, entries.len()));
            t.alloc.extend(entries.iter().map(|e| e.alloc));
            t.logical.extend(entries.iter().map(|e| e.size));
            t.flags.extend(entries.iter().map(|e| e.is_dir as u8));
            t.complete.extend(entries.iter().map(|e| !e.is_dir || e.descend()));
            let blob = t.name_blob.len() as u32;
            t.name_off.extend(entries.iter().map(|e| blob + e.name_end));
            t.name_blob.extend_from_slice(names);
            let mut bytes = 0;
            for (k, e) in entries.iter().enumerate() {
                if !e.is_dir {
                    bytes += arena.account_file(base + k as u32, e.hardlink);
                }
            }
            (base, bytes)
        };
        progress.bytes.fetch_add(bytes, Ordering::Relaxed);

        let mut start = 0;
        for (i, e) in entries.iter().enumerate() {
            if e.descend() {
                let idx = base + i as u32;
                let name = &names[start..e.name_end as usize];
                // Descend by `openat(2)` on the directory we already hold open,
                // not by rebuilding an absolute path.
                //
                // The absolute form was capped at `PATH_MAX`: `open(2)` rejects a
                // path longer than 1024 bytes, so any tree deeper than that lost
                // its whole tail silently — one error counter, `complete = false`,
                // and no explanation. Measured on a 3424-byte-deep fixture: `find`
                // reached the leaf at depth 81 while the engine stopped at 24
                // (audit RE-3). Build trees (`node_modules`, Rust/Go targets,
                // `Library/Caches`) are exactly where that depth occurs.
                //
                // The fd also removes a rename race the absolute form had: the
                // parent stays open across the child's whole walk, so the walk
                // cannot be redirected by a path component being replaced.
                match open_at(dir_fd, name) {
                    Some(child_fd) => scope.spawn(move |sc| walk(sc, shared, child_fd, idx)),
                    None => {
                        progress.errors.fetch_add(1, Ordering::Relaxed);
                        shared.mark_incomplete(idx);
                    }
                }
            }
            start = e.name_end as usize;
        }
        // Every child has its own descriptor now (the name lookup happened on
        // this one), so the parent's can go.
        unsafe { libc::close(dir_fd) };
    });
}

/// Open `name` under the already-open directory `dir_fd`, as a directory.
///
/// `O_NOFOLLOW` keeps a symlinked child from being followed, which matches the
/// absolute-path walk this replaces (`lib.rs::scan` opens the root the same
/// way). The caller owns the returned descriptor and closes it.
pub(crate) fn open_at(dir_fd: c_int, name: &[u8]) -> Option<c_int> {
    let name = CString::new(name).ok()?;
    let fd = unsafe {
        libc::openat(
            dir_fd,
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    (fd >= 0).then_some(fd)
}

/// Open an absolute directory path, for the root of a walk.
///
/// The one place a path is turned into a descriptor; everything below goes
/// through `open_at`. `O_NOFOLLOW` matches the child rule, and the caller owns
/// the descriptor.
pub(crate) fn open_dir(path: &CStr) -> Option<c_int> {
    let fd = unsafe {
        libc::open(
            path.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    (fd >= 0).then_some(fd)
}

/// Each directory's children form one run of equal parents: `(parent, first, len)`.
///
/// The grouping is by **adjacent equal parent**, which is exactly what the walk
/// produces — a directory's entries are appended under one lock, so its children
/// occupy consecutive indices. That makes the walk's own invariant load-bearing:
/// if any child were appended out of order, or a whole directory's batch were
/// dropped between two others, the same parent would appear in two runs and
/// `link` would build a `children` array that is short by one entry — silently
/// orphaning a node with no error and no assertion (audit RE-6).
///
/// `finish` therefore checks the invariant in test builds: every node's parent
/// must be at a lower index (children follow their parent), and re-grouping the
/// arrays must not lose anyone. The check is below, in `finish`.
fn runs(parents: &[u32]) -> Vec<(u32, u32, u32)> {
    let mut out = Vec::new();
    let mut i = 1;
    while i < parents.len() {
        let j = i + parents[i..].iter().take_while(|&&p| p == parents[i]).count();
        out.push((parents[i], i as u32, (j - i) as u32));
        i = j;
    }
    out
}

/// True when every node's parent precedes it and every non-root node is claimed
/// by exactly one run.
///
/// A node whose parent appears *after* it cannot be reached by the bottom-up
/// pass (which walks runs in reverse), and a node claimed by no run never enters
/// `children` at all. Both are silent: no error counter moves, the tree just
/// loses a subtree from the totals and from the map.
#[cfg(debug_assertions)]
fn runs_cover_every_node(t: &Tree, runs: &[(u32, u32, u32)]) -> bool {
    let mut claimed = vec![false; t.len()];
    claimed[0] = true;
    for &(_p, first, len) in runs {
        for i in first..first + len {
            if i as usize >= t.len() || claimed[i as usize] {
                return false;
            }
            claimed[i as usize] = true;
        }
    }
    t.parents
        .iter()
        .enumerate()
        .all(|(i, &p)| i == 0 || (p != NO_PARENT && (p as usize) < i))
        && claimed.iter().all(|&c| c)
}

/// Derive subtree totals and the sorted child lists from the walk's arrays.
///
/// **Single-shot, and debug-asserted as such.** Every total here is an
/// `+=` into an already-existing array: a second call adds each subtree to its
/// parent again, so a one-file directory of 100 bytes becomes 300 (measured,
/// audit RE-5). That is fine for the one caller (`lib.rs::scan`, which finishes
/// the freshly walked tree exactly once), but the surrounding code
/// (`Tree::with_root`/`push`/`link_children`) exists so tests can build trees by
/// hand and run these passes — and a test that calls `finish` twice would get
/// quietly wrong numbers instead of an error.
///
/// The invariant is checked rather than documented: `debug_assert` fires in the
/// test profile, and the recursive-kind of double-add is impossible to detect
/// from the arrays alone, so the guard is the flag below in debug builds. It
/// costs nothing in release.
pub(crate) fn finish(t: &mut Tree) {
    #[cfg(debug_assertions)]
    {
        let fresh = t.n_files.len() != t.len();
        debug_assert!(
            fresh,
            "finish() is single-shot: a second call double-counts every subtree total"
        );
    }
    let runs = runs(&t.parents);
    // The walk's batch invariant, checked rather than assumed: a lost run would
    // silently orphan a node from every total and from the child lists (RE-6).
    #[cfg(debug_assertions)]
    debug_assert!(
        runs_cover_every_node(t, &runs),
        "runs() lost a node: a reordered or split batch would orphan it silently"
    );
    // Bottom-up: a directory's run starts after its parent's run, so reverse
    // run order finishes every child before its parent.
    t.n_files = vec![0u32; t.len()];
    for &(p, first, len) in runs.iter().rev() {
        let (mut a, mut l, mut f, mut c) = (0u64, 0u64, 0u32, true);
        for i in first as usize..(first + len) as usize {
            a += t.alloc[i];
            l += t.logical[i];
            f += if t.is_dir(i) { t.n_files[i] } else { 1 };
            c &= t.complete[i];
        }
        let p = p as usize;
        t.alloc[p] += a;
        t.logical[p] += l;
        t.n_files[p] += f;
        t.complete[p] &= c;
    }
    link(t, &runs);
}

/// child_off and children, largest first (treemap layout order).
fn link(t: &mut Tree, runs: &[(u32, u32, u32)]) {
    let n = t.len();
    t.child_off = vec![0u32; n + 1];
    for &(p, _, len) in runs {
        t.child_off[p as usize] = len;
    }
    let mut acc = 0u32;
    for c in &mut t.child_off {
        (*c, acc) = (acc, acc + *c);
    }
    t.children = vec![0u32; n.saturating_sub(1)];
    for &(p, first, len) in runs {
        let at = t.child_off[p as usize] as usize;
        let kids = &mut t.children[at..at + len as usize];
        for (k, c) in kids.iter_mut().enumerate() {
            *c = first + k as u32;
        }
        kids.sort_unstable_by_key(|&c| std::cmp::Reverse(t.alloc[c as usize]));
    }
}

/// `Tree::flags` bit 1: this node was removed from the tree by
/// `remove_node`. Bit 0 stays `is_dir`.
pub(crate) const REMOVED: u8 = 2;

/// Remove a node and its subtree from the tree after its path left the scan
/// root — the user moved it to the Trash.
///
/// In place, deliberately, for two reasons:
///
/// 1. **No `Vec` is reallocated**, so the raw pointers Swift cached in its
///    `Tree` (see `app/Model.swift`) stay valid. Growing or shrinking a
///    `Vec`'s length can move its buffer, which would dangle every view.
/// 2. **No node is renumbered.** A node id is its index, so keeping the
///    indices stable means the id that named a folder before still names the
///    same folder after — the view's zoom, selection and hover survive. That
///    is precisely what a rescan cannot offer.
///
/// Only the removed node's link is cut. Its descendants become unreachable
/// because every consumer walks `children` from the root, and the subtree's
/// figures are subtracted from each ancestor so every total stays honest.
///
/// Returns `false` for the root, an out-of-range index, or an already-removed
/// node, so a second removal is a no-op rather than a double subtraction.
///
/// Accounting caveat: if the removed node was the path that *owned* a
/// hard-linked inode's bytes (see `Arena::account_file`), the bytes are
/// subtracted from the tree even though another name for the same inode may
/// still sit inside the scan. Re-attributing them to that other name would
/// need the `hardlinks` map, which lives in the walk's arena and not in the
/// flat `Tree`; the totals therefore under-count by those bytes until the
/// next scan. This is deliberate and bounded, not an oversight.
pub(crate) fn remove_node(t: &mut Tree, node: usize) -> bool {
    if node == 0 || node >= t.len() || t.flags[node] & REMOVED != 0 {
        return false;
    }
    let parent = t.parents[node];
    if parent == NO_PARENT {
        return false;
    }
    let parent = parent as usize;

    // Read the subtree's figures before touching anything.
    let (da, dl, df) = (
        t.alloc[node],
        t.logical[node],
        if t.is_dir(node) { t.n_files[node] } else { 1 },
    );

    // Cut the link inside the parent's run. `Vec::remove` shifts the tail left
    // in place without reallocating, so the child array's address is stable.
    let (start, end) = (t.child_off[parent] as usize, t.child_off[parent + 1] as usize);
    let Some(pos) = t.children[start..end].iter().position(|&c| c as usize == node) else {
        return false;
    };
    t.children.remove(start + pos);
    // `child_off` is a prefix sum over node order, so every offset from the
    // parent's own end onward loses the one child just removed.
    for off in t.child_off[parent + 1..].iter_mut() {
        *off -= 1;
    }

    // Subtract the subtree from every ancestor, root included.
    let mut cur = parent;
    loop {
        t.alloc[cur] = t.alloc[cur].saturating_sub(da);
        t.logical[cur] = t.logical[cur].saturating_sub(dl);
        t.n_files[cur] = t.n_files[cur].saturating_sub(df);
        // ...and recompute the ancestor's completeness from what is left.
        //
        // `complete` is a folded bool ("every descendant was readable"), so
        // subtracting one contribution from it needs the fold, not a value.
        // Removing the one unreadable folder used to leave the root still
        // claiming its figures were partial, with no way to recover — the user
        // trashes the cause and the scan still reads unreliable (audit RE-4).
        //
        // Re-folding from the surviving children is exact: each child's own
        // `complete` is already the fold of its subtree, so ANDing them is the
        // same result the original bottom-up pass would produce, minus the
        // removed subtree. The node's own attachment matters too — a directory
        // whose child list was emptied by the removal is complete.
        t.complete[cur] = t.kids(cur).iter().all(|&c| t.complete[c as usize]);
        let p = t.parents[cur];
        if p == NO_PARENT {
            break;
        }
        cur = p as usize;
    }

    // Detach and zero the node itself, so anything that still holds its id
    // reads "nothing here" instead of a stale size.
    t.flags[node] |= REMOVED;
    t.parents[node] = NO_PARENT;
    t.alloc[node] = 0;
    t.logical[node] = 0;
    t.n_files[node] = 0;
    true
}

/// Hand-built trees for tests.
#[cfg(test)]
impl Tree {
    pub(crate) fn with_root(name: &str) -> Tree {
        let mut t = Tree { name_off: vec![0], ..Default::default() };
        t.push(name, NO_PARENT, 0, 0, true);
        t
    }
    /// Append a node as the walk does: each directory's children in one batch.
    pub(crate) fn push(&mut self, name: &str, parent: u32, logical: u64, alloc: u64, is_dir: bool) -> u32 {
        self.parents.push(parent);
        self.logical.push(logical);
        self.alloc.push(alloc);
        self.flags.push(is_dir as u8);
        self.complete.push(true);
        self.name_blob.extend_from_slice(name.as_bytes());
        self.name_off.push(self.name_blob.len() as u32);
        self.parents.len() as u32 - 1
    }
    /// Child lists only, keeping the sizes as given.
    pub(crate) fn link_children(&mut self) {
        let runs = runs(&self.parents);
        link(self, &runs);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bulk_record(name: &str, is_dir: bool, flags: u32, mount_status: u32, links: u32) -> Vec<u8> {
        let mut e = vec![0u8; 4];
        let common = ATTR_CMN_RETURNED_ATTRS
            | ATTR_CMN_ERROR
            | ATTR_CMN_NAME
            | ATTR_CMN_DEVID
            | ATTR_CMN_OBJTYPE
            | ATTR_CMN_FLAGS
            | ATTR_CMN_FILEID;
        let dir = if is_dir { ATTR_DIR_MOUNTSTATUS } else { 0 };
        let file = if is_dir {
            0
        } else {
            ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE
        };
        for value in [common, 0, dir, file, 0, 0] {
            e.extend_from_slice(&value.to_le_bytes());
        }
        let name_ref = e.len();
        e.extend_from_slice(&[0u8; 8]);
        for value in [17u32, if is_dir { VDIR } else { 1 }, flags] {
            e.extend_from_slice(&value.to_le_bytes());
        }
        e.extend_from_slice(&123456u64.to_le_bytes());
        if is_dir {
            e.extend_from_slice(&mount_status.to_le_bytes());
        } else {
            e.extend_from_slice(&links.to_le_bytes());
            e.extend_from_slice(&12345i64.to_le_bytes());
            e.extend_from_slice(&16384i64.to_le_bytes());
        }
        let name_offset = (e.len() - name_ref) as u32;
        e[name_ref..name_ref + 4].copy_from_slice(&name_offset.to_le_bytes());
        e[name_ref + 4..name_ref + 8].copy_from_slice(&(name.len() as u32 + 1).to_le_bytes());
        e.extend_from_slice(name.as_bytes());
        e.push(0);
        let len = e.len() as u32;
        e[..4].copy_from_slice(&len.to_le_bytes());
        e
    }

    #[test]
    fn bulk_parser_preserves_cloud_mount_and_hardlink_metadata() {
        let (mut entries, mut names) = (Vec::new(), Vec::new());
        for (name, dir, flags, mount, links) in [
            ("cloud", true, SF_DATALESS, 0, 1),
            ("mounted", true, 0, DIR_MNTSTATUS_MNTPOINT, 1),
            ("plain", true, 0, 0, 1),
            ("linked-é", false, 0, 0, 2),
        ] {
            let record = bulk_record(name, dir, flags, mount, links);
            assert!(parse_entry(&record, &mut entries, &mut names, &Progress::default()));
        }
        assert_eq!(entries.len(), 4);
        assert!(entries[..3].iter().all(|e| e.is_dir) && !entries[3].is_dir);
        assert!(entries[0].dataless && !entries[0].mount_point);
        assert!(!entries[1].dataless && entries[1].mount_point);
        let descend: Vec<_> = entries.iter().map(|e| e.descend()).collect();
        assert_eq!(descend, [false, false, true, false], "cloud-only and mount points are skipped");
        assert_eq!(&names[entries[2].name_end as usize..], "linked-é".as_bytes());
        assert_eq!(entries[3].hardlink, Some((17, 123456)));
        assert_eq!((entries[3].size, entries[3].alloc), (12345, 16384));
    }

    #[test]
    fn removing_the_unreadable_folder_restores_completeness() {
        // RE-4. `complete` is a folded bool: "every descendant was readable".
        // `remove_node` subtracted sizes but never touched it, so trashing the
        // one unreadable folder left the root still reporting a partial walk and
        // the CLI's `coverage.complete` still `false`, with no way to recover —
        // the cause was gone and the flag could not be. The fold is now
        // recomputed from the surviving children, which is exact.
        let mut t = Tree::with_root("/root");
        let good = t.push("good", 0, 100, 100, true);
        t.push("good-child", good, 50, 50, false);
        let unreadable = t.push("unreadable", 0, 0, 0, true);
        t.complete = vec![true; t.len()];
        finish(&mut t);
        // Mark the folder the way `mark_incomplete` does, then re-fold upward so
        // the fixture matches a real walk.
        t.complete[unreadable as usize] = false;
        for i in (1..t.len()).rev() {
            let p = t.parents[i] as usize;
            t.complete[p] &= t.complete[i];
        }
        assert!(!t.complete[0], "the fixture must start incomplete");

        assert!(remove_node(&mut t, unreadable as usize));
        assert!(
            t.complete[0],
            "after removing the only unreadable folder the walk is complete again"
        );
        // The surviving subtree is untouched and still complete.
        assert!(t.complete[good as usize]);
        assert_eq!(t.alloc[0], 150);
    }

    #[test]
    fn remove_node_detaches_in_place_without_renumbering() {
        // The layout invariant `remove_node` relies on: every directory's
        // children form ONE contiguous run of indices, because the walk appends
        // a directory's entries in a single batch. So the root's children go
        // first (a, b), then each child's own children — NOT depth-first.
        let mut t = Tree::with_root("/root");
        let a = t.push("a", 0, 0, 0, true);
        let b = t.push("b", 0, 0, 0, true);
        let a1 = t.push("a-child", a, 900, 1000, false);
        let b1 = t.push("b-child", b, 700, 800, false);
        t.complete = vec![true; t.len()];
        finish(&mut t);

        // Totals before: a=1000 + b=800.
        assert_eq!(t.alloc[0], 1800);
        assert_eq!(t.n_files[0], 2);
        assert_eq!(t.kids(0).len(), 2);

        assert!(remove_node(&mut t, a as usize));

        // The removed node is detached and zeroed.
        assert!(t.flags[a as usize] & REMOVED != 0);
        assert_eq!(t.parents[a as usize], NO_PARENT);
        assert_eq!(t.alloc[a as usize], 0);

        // Every ancestor total is honest: only b's 800 remains.
        assert_eq!(t.alloc[0], 800, "the removed subtree's bytes are subtracted");
        assert_eq!(t.n_files[0], 1);
        // b keeps its own figures and its own index — nothing was renumbered.
        assert_eq!(t.alloc[b as usize], 800);
        assert_eq!(t.alloc[b1 as usize], 800);
        assert_eq!(t.parents[b1 as usize], b);
        // The removed child keeps its index too (so any held id still resolves),
        // it is simply unreachable from the root.
        assert_eq!(t.parents[a1 as usize], a);
        assert_eq!(t.alloc[a1 as usize], 1000);

        // The root's child list lost exactly `a`, and `b` is still reachable.
        assert_eq!(t.kids(0), &[b], "only the removed node was unlinked");
        // A detached node keeps its OWN child run: it is unreachable from the
        // root, which is what detaches it, so nothing walks into it. Its own
        // subtree stays intact for anything that still holds an id into it.
        assert_eq!(t.kids(a as usize), &[a1]);
        // b's own child list is intact: the offsets after the cut still point
        // at its run.
        assert_eq!(t.kids(b as usize), &[b1]);

        // Idempotent: a second removal is a no-op, not a double subtraction.
        assert!(!remove_node(&mut t, a as usize));
        assert_eq!(t.alloc[0], 800);

        // The root can never be removed.
        assert!(!remove_node(&mut t, 0));
        assert_eq!(t.alloc[0], 800);

        // Removing b too empties the root honestly.
        assert!(remove_node(&mut t, b as usize));
        assert_eq!(t.alloc[0], 0);
        assert_eq!(t.n_files[0], 0);
        assert_eq!(t.kids(0), &[] as &[u32]);
    }

    #[test]
    fn path_does_not_panic_on_a_detached_node() {
        // RE-2. `remove_node` sets the removed node's parent to `NO_PARENT`, and
        // `Tree::path` looped `while i != 0`, so it indexed
        // `parents[u32::MAX]` and panicked: "index out of bounds: the len is 4
        // but the index is 4294967295". `Tree::path` is `pub` and the GUI's
        // `bz_remove_node` → `find` → sort comparator calls it, so one detached
        // candidate aborted the whole refresh. The Swift mirror always had the
        // guard; this asserts the Rust copy does too.
        let mut t = Tree::with_root("/root");
        let a = t.push("a", 0, 0, 0, true);
        let a1 = t.push("a-child", a, 900, 1000, false);
        t.complete = vec![true; t.len()];
        finish(&mut t);

        assert!(remove_node(&mut t, a as usize));

        // Both the removed node and its still-linked descendant must resolve
        // without panicking. The path they report is the one they still hold —
        // whether they are reachable is `isAttached`'s question, not this one's.
        let removed_path = t.path(a as usize);
        let child_path = t.path(a1 as usize);
        assert_eq!(removed_path, std::path::PathBuf::from("/root/a"));
        assert_eq!(child_path, std::path::PathBuf::from("/root/a/a-child"));
        // The root itself is unaffected.
        assert_eq!(t.path(0), std::path::PathBuf::from("/root"));
    }

    /// Every child is listed once, under its parent, after it.
    fn assert_partition(t: &Tree) {
        let mut seen = vec![false; t.len()];
        seen[0] = true;
        for p in 0..t.len() {
            assert!(t.flags[p] & 1 != 0 || t.kids(p).is_empty());
            for &c in t.kids(p) {
                let c = c as usize;
                assert!(c > p, "aggregation requires parent-before-child order");
                assert!(!seen[c], "a child belongs to exactly one directory");
                seen[c] = true;
                assert_eq!(t.parents[c] as usize, p);
            }
        }
        assert!(seen.iter().all(|&v| v), "every node is reachable");
    }

    #[test]
    fn scan_preserves_parent_links_empty_dirs_and_symlinks() {
        use std::os::unix::fs::symlink;
        let root = std::env::temp_dir().join(format!("bz-tree-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("nested/empty")).unwrap();
        std::fs::write(root.join("nested/document-é"), [7u8; 17]).unwrap();
        symlink(&root, root.join("loop")).unwrap();
        let t = crate::scan(&root, &Progress::default());
        let _ = std::fs::remove_dir_all(&root);
        assert_eq!(t.errors, 0);
        assert_eq!(t.len(), 5, "directory symlinks are not followed");
        assert_eq!(t.n_files[0], 2);
        assert_partition(&t);
        let find = |n: &str| (0..t.len()).find(|&i| t.name(i) == n).unwrap();
        let empty = find("empty");
        assert!(t.flags[empty] & 1 != 0 && t.kids(empty).is_empty());
        assert_eq!(t.logical[find("document-é")], 17);
    }

    #[test]
    fn parallel_child_ranges_partition_wide_and_deep_tree() {
        let root = std::env::temp_dir().join(format!("bz-ranges-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let mut deep = root.clone();
        for depth in 1..=96 {
            deep.push("d");
            std::fs::create_dir(&deep).unwrap();
            std::fs::write(deep.join("data"), vec![1u8; depth]).unwrap();
        }
        for width in 0..64 {
            let dir = root.join(format!("wide-{width}"));
            std::fs::create_dir_all(dir.join("empty")).unwrap();
            std::fs::write(dir.join("data"), [1u8; 19]).unwrap();
        }
        let t = crate::scan(&root, &Progress::default());
        let _ = std::fs::remove_dir_all(&root);
        assert_eq!(t.errors, 0);
        assert_eq!(t.len(), 385);
        assert_eq!(t.n_files[0], 160);
        assert_eq!(t.logical[0], 5872);
        assert_partition(&t);
    }

    #[test]
    fn walk_reaches_beyond_path_max() {
        // RE-3. The walk used to rebuild an absolute path per child and `open(2)`
        // it, so once the accumulated prefix passed `PATH_MAX` (1024 bytes) every
        // deeper directory was refused: one error counter, `complete = false`,
        // and the whole tail of the tree silently missing. Measured on a
        // 3424-byte-deep fixture, `find` reached the leaf while the engine
        // stopped at depth 24.
        //
        // The fixture is built with `fchdir`/`mkdirat`, never an absolute path,
        // because the *fixture* would hit the same cap: 60 components of 30
        // characters is ~1830 bytes.
        let root = std::env::temp_dir().join(format!("bz-pathmax-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();

        let depth = 60usize;
        let component = "d".repeat(30);
        let mut dir_fd = unsafe {
            libc::open(
                std::ffi::CString::new(root.to_str().unwrap()).unwrap().as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY,
            )
        };
        assert!(dir_fd >= 0, "fixture root must open");
        for _ in 0..depth {
            let name = std::ffi::CString::new(component.as_str()).unwrap();
            assert_eq!(unsafe { libc::mkdirat(dir_fd, name.as_ptr(), 0o755) }, 0);
            let next = unsafe {
                libc::openat(dir_fd, name.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY)
            };
            assert!(next >= 0, "fixture level must open");
            unsafe { libc::close(dir_fd) };
            dir_fd = next;
        }
        // A real file at the very bottom, so a reached leaf is observable.
        let leaf = std::ffi::CString::new("leaf.bin").unwrap();
        let fd = unsafe { libc::openat(dir_fd, leaf.as_ptr(), libc::O_CREAT | libc::O_WRONLY, 0o644) };
        assert!(fd >= 0, "fixture leaf must open");
        unsafe {
            libc::write(fd, [7u8; 4096].as_ptr() as *const _, 4096);
            libc::close(fd);
            libc::close(dir_fd);
        }

        let t = crate::scan(&root, &Progress::default());
        let _ = std::fs::remove_dir_all(&root);

        // The old behaviour: errors == 1, complete == false, ~24 levels.
        // Every level and the leaf must be present, and the walk must be whole.
        assert_eq!(t.errors, 0, "the walk must not stop at PATH_MAX");
        assert!(t.complete[0], "the walk must report a complete tree");
        assert_eq!(t.n_files[0], 1, "the leaf file must be seen");
        // 1 root + 60 levels + the leaf file itself.
        assert_eq!(t.len(), depth + 2, "every level must be reached");
        assert_eq!(t.alloc[0], 4096, "the leaf's bytes must be totalled");
        assert_partition(&t);
    }

    /// A tree as the walk leaves it: each directory's entries appended as one
    /// batch after it, totals and child lists not yet derived.
    fn fixture(dirs: usize, files_per_dir: usize) -> Tree {
        let mut t = Tree::with_root("/fixture");
        t.errors = 3;
        for dir in 0..dirs {
            t.push(&format!("directory-{dir}"), 0, 0, 0, true);
        }
        for dir in 0..dirs {
            for file in 0..files_per_dir {
                let size = (file as u64 * 7919 + dir as u64 * 104729) % 1_000_000;
                let name = format!("document-{dir}-{file}-é-日本語.txt");
                t.push(&name, dir as u32 + 1, size, size.div_ceil(4096) * 4096, false);
            }
        }
        // One unreadable directory, to exercise incompleteness propagation.
        if dirs > 1 {
            t.complete[2] = false;
        }
        t
    }

    /// The pre-0.6 conversion, kept as an independent reference: per-node
    /// totals in reverse index order, then each child list sorted on its own.
    fn reference_finish(mut t: Tree) -> Tree {
        let n = t.len();
        t.n_files = vec![0; n];
        let mut lists = vec![Vec::new(); n];
        for i in (1..n).rev() {
            let p = t.parents[i] as usize;
            t.alloc[p] += t.alloc[i];
            t.logical[p] += t.logical[i];
            t.n_files[p] += if t.flags[i] & 1 != 0 { t.n_files[i] } else { 1 };
            t.complete[p] &= t.complete[i];
        }
        for i in 1..n {
            lists[t.parents[i] as usize].push(i as u32);
        }
        t.child_off = vec![0];
        for mut kids in lists {
            kids.sort_unstable_by_key(|&c| std::cmp::Reverse(t.alloc[c as usize]));
            t.children.extend(kids);
            t.child_off.push(t.children.len() as u32);
        }
        t
    }

    #[test]
    fn finish_preserves_every_abi_column_and_child_order() {
        for (dirs, files) in [(0, 0), (3, 0), (1, 1024), (128, 4)] {
            let mut t = fixture(dirs, files);
            finish(&mut t);
            assert_eq!(t, reference_finish(fixture(dirs, files)));
        }
    }

    #[test]
    #[cfg(debug_assertions)]
    fn runs_reject_a_split_batch() {
        // Proves the RE-6 invariant is not vacuous: two nodes of one parent
        // separated by another parent's node is the shape a dropped batch
        // creates, and it must be refused rather than orphaning a node.
        let mut t = Tree::with_root("/root");
        let a = t.push("a", 0, 1, 1, true);
        t.push("b", 0, 1, 1, true);
        t.push("a-child", a, 1, 1, false);
        t.complete = vec![true; t.len()];
        // `parents` is [NO_PARENT, 0, 0, 0] — already one run for the root. Break
        // it the way a lost node would: give the last node a parent that appears
        // after it.
        t.parents[3] = 3;
        let r = runs(&t.parents);
        assert!(!runs_cover_every_node(&t, &r), "a self-parented node must be refused");
    }

    #[test]
    #[cfg(debug_assertions)]
    fn finish_refuses_a_second_call() {
        // RE-5. `finish` adds each subtree into its parent, so a second call
        // double-counts: measured (100, 100, 1) → (300, 300, 1). The guard makes
        // that an assertion in test builds instead of silently wrong totals.
        let mut t = Tree::with_root("/root");
        t.push("a", 0, 100, 100, false);
        t.complete = vec![true; t.len()];
        finish(&mut t);
        assert_eq!(t.alloc[0], 100);

        let second = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| finish(&mut t)));
        assert!(
            second.is_err(),
            "a second finish() must be refused, not double every total"
        );
    }

    #[test]
    #[ignore = "isolated performance measurement; run in release with --nocapture"]
    fn finish_benchmark() {
        // Alternate execution order to avoid favoring either implementation.
        for round in 0..10 {
            for variant in [round % 2, 1 - round % 2] {
                let mut t = fixture(256, 1024);
                let start = std::time::Instant::now();
                if variant == 0 {
                    t = reference_finish(t);
                } else {
                    finish(&mut t);
                }
                let elapsed = start.elapsed();
                std::hint::black_box(&t);
                println!("finish,{round},{variant},{}", elapsed.as_nanos());
            }
        }
    }

    #[test]
    fn hardlink_owner_does_not_depend_on_discovery_order() {
        for order in [[3, 4, 5], [5, 3, 4], [4, 5, 3]] {
            let mut tree = Tree::with_root("/root");
            tree.push("a", 0, 0, 0, true);
            tree.push("z", 0, 0, 0, true);
            tree.push("a", 2, 8192, 4096, false);
            tree.push("z", 1, 8192, 4096, false);
            tree.push("y", 1, 8192, 4096, false);
            let mut arena = Arena { tree, hardlinks: HashMap::new() };
            let added: u64 = order
                .into_iter()
                .map(|i| arena.account_file(i, Some((7, 42))))
                .sum();
            let t = &mut arena.tree;
            assert_eq!(added, 4096, "progress counts the inode once");
            assert_eq!(t.alloc[3], 0); // /root/z/a
            assert_eq!(t.alloc[4], 0); // /root/a/z
            assert_eq!(t.alloc[5], 4096); // /root/a/y wins every time
            assert_eq!(t.logical[5], 8192);
            finish(t);
            assert_eq!((t.alloc[0], t.logical[0], t.n_files[0]), (4096, 8192, 3));
        }
    }

    #[test]
    fn incomplete_subtrees_propagate_without_hiding_healthy_siblings() {
        let mut t = Tree::with_root("/root");
        t.push("partial", 0, 0, 0, true);
        t.push("healthy", 0, 0, 0, true);
        let skipped = t.push("unreadable-or-skipped", 1, 0, 0, true);
        t.push("file", 2, 8192, 4096, false);
        t.complete[skipped as usize] = false;
        finish(&mut t);
        assert_eq!(t.complete[..3], [false, false, true]);
        assert_eq!(t.alloc[0], 4096, "partial scans still expose observed bytes");
    }

    #[test]
    fn entry_errors_are_reported_instead_of_silently_dropped() {
        let mut bytes = vec![0u8; 28];
        bytes[4..8].copy_from_slice(&ATTR_CMN_ERROR.to_le_bytes());
        bytes[24..28].copy_from_slice(&(libc::EACCES as u32).to_le_bytes());
        let progress = Progress::default();
        let (mut entries, mut names) = (Vec::new(), Vec::new());
        assert!(!parse_entry(&bytes, &mut entries, &mut names, &progress));
        assert!(entries.is_empty());
        assert_eq!(progress.errors.load(Ordering::Relaxed), 1);
        assert_eq!(progress.entry_errors.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn invalid_utf8_is_not_replaced_with_an_actionable_path() {
        let mut bytes = vec![0u8; 34];
        bytes[4..8].copy_from_slice(&ATTR_CMN_NAME.to_le_bytes());
        bytes[24..28].copy_from_slice(&8u32.to_le_bytes());
        bytes[28..32].copy_from_slice(&2u32.to_le_bytes());
        bytes[32] = 0xff;
        let progress = Progress::default();
        let (mut entries, mut names) = (Vec::new(), Vec::new());
        assert!(!parse_entry(&bytes, &mut entries, &mut names, &progress));
        assert!(entries.is_empty() && names.is_empty());
        assert_eq!(progress.errors.load(Ordering::Relaxed), 1);
        assert_eq!(progress.invalid_names.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn hardlinks_count_once() {
        let root = std::env::temp_dir().join(format!("bz-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("sub")).unwrap();
        std::fs::write(root.join("file"), vec![7u8; 1 << 20]).unwrap();
        std::fs::hard_link(root.join("file"), root.join("sub/link")).unwrap();

        let tree = crate::scan(&root, &Progress::default());
        let _ = std::fs::remove_dir_all(&root);

        assert_eq!(tree.n_files[0], 2, "both names are listed");
        assert_eq!(tree.logical[0], 1 << 20, "but the bytes count once");
    }

    #[test]
    fn flat_layout() {
        let root = std::env::temp_dir().join(format!("bz-test-flat-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("big/deep")).unwrap();
        std::fs::create_dir_all(root.join("empty")).unwrap();
        std::fs::write(root.join("big/deep/blob"), vec![1u8; 1 << 20]).unwrap();
        std::fs::write(root.join("small"), b"hi").unwrap();

        let t = crate::scan(&root, &Progress::default());
        let _ = std::fs::remove_dir_all(&root);

        assert_eq!(t.len(), 6);
        assert_eq!((t.child_off.len(), t.name_off.len(), t.children.len()), (7, 7, 5));
        let names = |i: usize| t.kids(i).iter().map(|&c| t.name(c as usize)).collect::<Vec<_>>();
        assert_eq!(names(0), ["big", "small", "empty"], "largest first");
        let big = t.kids(0)[0] as usize;
        assert_eq!(names(big), ["deep"]);
        assert_eq!((t.n_files[0], t.n_files[big]), (2, 1));
        assert_eq!(t.logical[0], (1 << 20) + 2);
        assert_eq!(t.flags[big], 1);
        for i in 1..t.len() {
            assert!(t.kids(t.parents[i] as usize).contains(&(i as u32)));
        }
    }

    #[test]
    fn c_abi_round_trip() {
        use crate::ffi::*;
        let root = std::env::temp_dir().join(format!("bz-test-ffi-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("d")).unwrap();
        std::fs::write(root.join("d/f"), b"x").unwrap();
        let path = CString::new(root.as_os_str().as_encoded_bytes()).unwrap();

        let h = bz_scan_start(path.as_ptr());
        let (mut f, mut d, mut b, mut done) = (0, 0, 0, 0);
        while done == 0 {
            std::thread::sleep(std::time::Duration::from_millis(1));
            bz_progress(h, &mut f, &mut d, &mut b, &mut done);
        }
        let _ = std::fs::remove_dir_all(&root);
        assert_eq!(bz_take_tree(h), 3);
        let s = |p: *const u32, n| unsafe { std::slice::from_raw_parts(p, n) };
        assert_eq!(s(bz_parents(h), 3), [NO_PARENT, 0, 1]);
        assert_eq!(s(bz_child_off(h), 4), [0, 1, 2, 2]);
        assert_eq!(s(bz_children(h), 2), [1, 2]);
        assert_eq!(s(bz_nfiles(h), 3), [1, 1, 0]);
        let off = s(bz_name_off(h), 4);
        let blob = unsafe { std::slice::from_raw_parts(bz_name_blob(h), off[3] as usize) };
        assert_eq!(&blob[off[1] as usize..], b"df");
        bz_free(h);
    }
}
