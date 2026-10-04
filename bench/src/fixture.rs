//! Deterministic synthetic scan targets.
//!
//! A fixture is a pure function of `size` and `seed`, so two people on two
//! machines measure the same tree layout. It exists because a benchmark that
//! only runs on the author's home directory is not reproducible by anyone
//! else, and because real folders need no Full Disk Access but do change
//! underneath a running benchmark.

use std::fs;
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};

pub const SIZES: [&str; 3] = ["small", "medium", "large"];

/// Shape of a fixture. `dirs` counts directories, `files` counts files.
pub struct Spec {
    pub name: &'static str,
    pub dirs: usize,
    pub files: usize,
    pub file_kib: usize,
}

pub fn spec(size: &str) -> Result<Spec, String> {
    // Sized to be long enough to time meaningfully (tens of ms and up) while
    // staying small enough to create in seconds and delete afterwards.
    match size {
        "small" => Ok(Spec { name: "small", dirs: 200, files: 1_500, file_kib: 4 }),
        "medium" => Ok(Spec { name: "medium", dirs: 1_200, files: 20_000, file_kib: 8 }),
        "large" => Ok(Spec { name: "large", dirs: 3_000, files: 60_000, file_kib: 16 }),
        other => Err(format!("unknown size {other:?}; expected one of {}", SIZES.join(", "))),
    }
}

/// Deterministic 64-bit PRNG (splitmix64): identical output on every platform
/// and Rust version, which `rand` deliberately does not guarantee.
struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Self {
        Rng(seed ^ 0x9E37_79B9_7F4A_7C15)
    }

    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

/// What was created, written to `manifest.json` beside the tree so a later
/// `--verify` (or a human) can check the fixture was not disturbed.
///
/// `files` counts *names*, so a hardlinked file reachable by two names counts
/// twice here; `logical_bytes` counts each inode once, matching `du` and both
/// engines.
pub struct Manifest {
    pub size: String,
    pub seed: u64,
    pub dirs: usize,
    pub files: usize,
    pub logical_bytes: u64,
    pub hardlink_names: usize,
    pub symlinks: usize,
    pub unicode_names: usize,
}

impl Manifest {
    pub fn json(&self) -> String {
        format!(
            "{{\n  \"size\": \"{}\",\n  \"seed\": {},\n  \"dirs\": {},\n  \"files\": {},\n  \"logical_bytes\": {},\n  \"hardlink_names\": {},\n  \"symlinks\": {},\n  \"unicode_names\": {}\n}}\n",
            crate::jsonw::escape(&self.size),
            self.seed,
            self.dirs,
            self.files,
            self.logical_bytes,
            self.hardlink_names,
            self.symlinks,
            self.unicode_names
        )
    }
}

const UNICODE_NAMES: [&str; 6] = [
    "résumé",
    "日本語",
    "emoji-🎯",
    "space in name",
    "Ünïcödé",
    "кириллица",
];

/// Create the fixture tree. Refuses to write into a non-empty directory
/// unless `force`, so a mistyped `--out` cannot clobber real files.
/// The manifest lives *beside* the tree, not inside it: anything inside the
/// fixture directory is scanned and counted by the engines, which would make
/// every file count depend on the harness's own bookkeeping file.
pub fn manifest_path(out: &Path) -> PathBuf {
    let name = out
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "fixture".into());
    out.with_file_name(format!("{name}.manifest.json"))
}

pub fn create(out: &Path, size: &str, seed: u64, force: bool) -> Result<Manifest, String> {
    let spec = spec(size)?;
    if out.exists() && !force {
        let empty = fs::read_dir(out)
            .map_err(|e| format!("{}: {e}", out.display()))?
            .next()
            .is_none();
        if !empty {
            return Err(format!(
                "{} already exists and is not empty; pass --force to write into it",
                out.display()
            ));
        }
    }
    // `--force` rebuilds from scratch rather than merging: a leftover hardlink
    // or an extra file from an earlier run would otherwise make the manifest a
    // lie, and the fixture would stop being a pure function of (size, seed).
    if out.exists() && force {
        fs::remove_dir_all(out).map_err(|e| format!("{}: {e}", out.display()))?;
    }
    fs::create_dir_all(out).map_err(|e| format!("{}: {e}", out.display()))?;

    let mut rng = Rng::new(seed);
    let mut manifest = Manifest {
        size: spec.name.to_string(),
        seed,
        dirs: 0,
        files: 0,
        logical_bytes: 0,
        hardlink_names: 0,
        symlinks: 0,
        unicode_names: 0,
    };

    // Wide layer: many sibling directories, the shape real disks have.
    let wide = spec.dirs / 4;
    let payload = vec![b'x'; spec.file_kib * 1024];
    for i in 0..wide {
        let dir = out.join(format!("dir-{i:04}"));
        fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        manifest.dirs += 1;
        // A couple of levels below each wide directory.
        for j in 0..2 {
            let nested = dir.join(format!("nested-{j}"));
            fs::create_dir_all(&nested).map_err(|e| format!("{}: {e}", nested.display()))?;
            manifest.dirs += 1;
        }
    }

    // Deep chain: exercises recursion depth and path-length handling.
    let mut deep = out.join("deep");
    fs::create_dir_all(&deep).map_err(|e| format!("{}: {e}", deep.display()))?;
    manifest.dirs += 1;
    for level in 0..24 {
        deep = deep.join(format!("level-{level:02}"));
        fs::create_dir_all(&deep).map_err(|e| format!("{}: {e}", deep.display()))?;
        manifest.dirs += 1;
    }

    // An empty directory: a zero-byte child is where scanners disagree.
    let empty = out.join("empty-dir");
    fs::create_dir_all(&empty).map_err(|e| format!("{}: {e}", empty.display()))?;
    manifest.dirs += 1;

    // Unicode, spaces, and a long name.
    let unicode_dir = out.join("unicode");
    fs::create_dir_all(&unicode_dir).map_err(|e| format!("{}: {e}", unicode_dir.display()))?;
    manifest.dirs += 1;
    for name in UNICODE_NAMES {
        let path = unicode_dir.join(name);
        write_file(&path, &payload)?;
        manifest.files += 1;
        manifest.logical_bytes += payload.len() as u64;
        manifest.unicode_names += 1;
    }

    // Files spread across the wide layer, filling the file budget.
    let remaining = spec.files.saturating_sub(manifest.files);
    let dirs: Vec<PathBuf> = (0..wide).map(|i| out.join(format!("dir-{i:04}"))).collect();
    for index in 0..remaining {
        let dir = &dirs[index % dirs.len()];
        let path = dir.join(format!("file-{index:06}.bin"));
        let kib = spec.file_kib + rng.below(8);
        write_file(&path, &vec![b'y'; kib * 1024])?;
        manifest.files += 1;
        manifest.logical_bytes += (kib * 1024) as u64;
    }

    // One hardlinked file under two names: the documented reason AppleTree and
    // disktree report different file counts for identical byte totals. `files`
    // counts names (so this adds two), `logical_bytes` counts the inode once.
    let original = out.join("hardlink-a.bin");
    write_file(&original, &vec![b'h'; 64 * 1024])?;
    manifest.files += 1;
    manifest.logical_bytes += 64 * 1024;
    let link = out.join("hardlink-b.bin");
    fs::hard_link(&original, &link).map_err(|e| format!("{}: {e}", link.display()))?;
    manifest.files += 1;
    manifest.hardlink_names = 2;

    // A symlink: it must not be followed, so it adds nothing to the totals.
    let target = out.join("symlink-to-dir-0");
    let _ = fs::remove_file(&target);
    std::os::unix::fs::symlink(out.join("dir-0000"), &target)
        .map_err(|e| format!("{}: {e}", target.display()))?;
    manifest.symlinks = 1;

    fs::write(manifest_path(out), manifest.json())
        .map_err(|e| format!("{}: {e}", manifest_path(out).display()))?;
    Ok(manifest)
}

fn write_file(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let mut file = fs::File::create(path).map_err(|e| format!("{}: {e}", path.display()))?;
    file.write_all(bytes).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(())
}

/// Result of walking an existing tree and comparing it to its manifest.
pub struct Verify {
    pub dirs: usize,
    pub files: usize,
    pub logical_bytes: u64,
    pub matches: bool,
}

/// Walk a fixture and compare with `manifest.json`. Symlinks are not followed
/// and count as neither file nor directory, matching both engines. A hardlinked
/// inode's bytes are counted once, as `du` and both engines do; every name is
/// still counted as a file.
pub fn verify(out: &Path) -> Result<Verify, String> {
    let manifest_path = manifest_path(out);
    let text = fs::read_to_string(&manifest_path)
        .map_err(|e| format!("{}: {e} (is this a fixture?)", manifest_path.display()))?;
    let pairs = crate::jsonw::parse_flat_object(&text)
        .ok_or_else(|| format!("{}: unreadable manifest", manifest_path.display()))?;
    let want_dirs = crate::jsonw::get_u64(&pairs, "dirs").unwrap_or(0) as usize;
    let want_files = crate::jsonw::get_u64(&pairs, "files").unwrap_or(0) as usize;
    let want_bytes = crate::jsonw::get_u64(&pairs, "logical_bytes").unwrap_or(0);

    let mut seen = Verify { dirs: 0, files: 0, logical_bytes: 0, matches: false };
    let mut seen_inodes = std::collections::HashSet::new();
    walk(out, &mut seen, &mut seen_inodes)?;
    seen.matches = seen.dirs == want_dirs
        && seen.files == want_files
        && seen.logical_bytes == want_bytes;
    if !seen.matches {
        return Err(format!(
            "fixture changed: manifest says {want_dirs} dirs / {want_files} files / {want_bytes} bytes, found {} / {} / {}",
            seen.dirs, seen.files, seen.logical_bytes
        ));
    }
    Ok(seen)
}

fn walk(
    dir: &Path,
    seen: &mut Verify,
    seen_inodes: &mut std::collections::HashSet<(u64, u64)>,
) -> Result<(), String> {
    use std::os::unix::fs::MetadataExt;

    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(format!("{}: {e}", dir.display())),
    };
    for entry in entries {
        let entry = entry.map_err(|e| format!("{}: {e}", dir.display()))?;
        let path = entry.path();
        let meta = fs::symlink_metadata(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        if meta.is_symlink() {
            continue;
        }
        if meta.is_dir() {
            seen.dirs += 1;
            walk(&path, seen, seen_inodes)?;
        } else {
            seen.files += 1;
            // Hardlinked names share one inode: its bytes are counted once.
            if meta.nlink() <= 1 || seen_inodes.insert((meta.dev(), meta.ino())) {
                seen.logical_bytes += meta.len();
            }
        }
    }
    Ok(())
}
