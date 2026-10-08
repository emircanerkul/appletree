//! The Clean Up panel's folder recognition, shared with the JSON CLI.
//!
//! Rust owns RECOGNITION: what a folder is (name/structure heuristics).
//! Swift's `CleanupGuard` owns AUTHORIZATION: whether it may be touched.
//! Recognition must never nominate a folder authorization will refuse — a
//! candidate the guard blocks shows the user a Move that fails with "Too
//! broad", which is why the home-level `~/Library/Caches` and `~/.cache`
//! roots are deliberately not nominated here (see `is_home_library`).
//! These remain heuristics, not authorization to delete anything.
use crate::{Tree, NO_PARENT};

pub const MIN_BYTES: u64 = 50_000_000;

/// The only commands AppleTree runs: each tool's own cleanup, in exactly
/// these forms (S6). No-argument commands must match to the letter; flag
/// variants are separate entries, not prefix matches. This is the single
/// source of truth: the Swift guard set and the agent prompt both read it
/// through `bz_cleanup_allowlist`, in this exact order.
///
/// Five cache-clean forms were retired because their target is the tool's own
/// cache *folder*, which `CACHE_RULES` now nominates: `uv cache clean`
/// (measured — it empties `uv cache dir` entirely, exactly what trashing that
/// folder does), `bun pm cache rm`, `pip cache purge`, `pip3 cache purge` and
/// `pod cache clean --all`. Each was a command whose whole effect a folder move
/// already has, so it was precisely the `exec` dependency the App Store sandbox
/// cannot carry: keeping it would offer a card that fails there for no gain.
///
/// Kept deliberately, each for a reason a folder cannot express:
///
/// - `npm cache clean` / `--force` — npm's cache folder is `~/.npm`, which also
///   holds `_npx`, `_logs` and `_prebuilds`, so the command is *not* the same
///   operation as trashing the folder.
/// - `yarn cache clean` — no confirmed table row (yarn was absent from the
///   machine where the table was measured), so retiring it would lose a
///   capability without a replacement.
/// - `uv cache prune` and `pnpm store prune` — both remove only *unreferenced*
///   entries and leave the store usable; a folder move cannot express that.
/// - `brew cleanup`, `gem cleanup`, `go clean`, `conda clean`, `mamba clean`,
///   `docker … prune`, `xcrun simctl …` — no folder equivalent at all.
pub const ALLOWLIST: &[&str] = &[
    "uv cache prune",
    "npm cache clean",
    "npm cache clean --force",
    "pnpm store prune",
    "yarn cache clean",
    "brew cleanup",
    "brew cleanup --prune=all",
    "brew autoremove",
    "docker system prune",
    "docker system prune -f",
    "docker image prune",
    "docker image prune -f",
    "docker builder prune",
    "docker builder prune -f",
    "docker container prune",
    "xcrun simctl delete unavailable",
    "conda clean",
    "conda clean -a -y",
    "mamba clean",
    "go clean -cache",
    "go clean -modcache",
    "gem cleanup",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    NodeModules,
    PythonEnvironment,
    RustBuild,
    NextBuild,
    XcodeDerivedData,
    DeviceSupport,
    AppCaches,
    /// A cache recognised by one `CACHE_RULES` row. The payload is the owning
    /// tool's name (uv, Cargo, pnpm, pip, Homebrew, …), which is what makes the
    /// identity table useful: `id()` still collapses every row to the published
    /// `tool_caches` category, but `tool()` can say which tool was matched.
    ToolCache(&'static str),
    /// The older shape rules (`.npm`, `.gradle`, a nested `.cache`), which are
    /// not rows of the identity table and so have no tool name to carry.
    ToolCaches,
    BunCache,
}

impl Kind {
    pub fn id(self) -> &'static str {
        match self {
            Self::NodeModules => "node_modules",
            Self::PythonEnvironment => "python_environment",
            Self::RustBuild => "rust_build",
            Self::NextBuild => "next_build",
            Self::XcodeDerivedData => "xcode_derived_data",
            Self::DeviceSupport => "device_support",
            Self::AppCaches => "app_caches",
            // Published wire value: every identity-table row and every shape
            // rule reports the same category through the CLI and the bridge.
            Self::ToolCache(_) | Self::ToolCaches => "tool_caches",
            Self::BunCache => "bun_cache",
        }
    }

    /// The tool that owns this cache, when a `CACHE_RULES` row identified it.
    /// `None` for every folder recognised by shape rather than by identity.
    pub fn tool(self) -> Option<&'static str> {
        match self {
            Self::ToolCache(name) => Some(name),
            _ => None,
        }
    }

    /// Existing panel labels; kept here so both interfaces describe the same rule.
    pub fn description(self) -> &'static str {
        match self {
            Self::NodeModules => "npm packages, reinstallable",
            Self::PythonEnvironment => "Python environment, reinstallable",
            Self::RustBuild => "Rust build output",
            Self::NextBuild => "Next.js build output",
            Self::XcodeDerivedData => "Xcode build data",
            Self::DeviceSupport => "Device symbols, re-downloaded when needed",
            Self::AppCaches => "App caches, rebuilt automatically",
            // Deliberately unspecific, and unchanged for the table rows: the
            // Swift `Cleanup` model shows this verbatim and the shape rules
            // (`.npm`, `.gradle`) have no tool name to name. `tool()` is where
            // a caller asks *which* tool.
            Self::ToolCache(_) | Self::ToolCaches => {
                "Caches, rebuilt or re-downloaded when needed"
            }
            Self::BunCache => "Bun package cache, re-downloaded when needed",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Candidate {
    pub node: u32,
    pub kind: Kind,
}

fn contains(t: &Tree, directory: u32, name: &str) -> bool {
    directory != NO_PARENT
        && t.kids(directory as usize)
            .iter()
            .any(|&i| t.name(i as usize) == name)
}

/// Parent index, or `None` at the scan root.
fn parent_of(t: &Tree, i: u32) -> Option<u32> {
    let p = t.parents[i as usize];
    (p != NO_PARENT).then_some(p)
}

/// True when the usable path *is* a home directory: `<Users>/<user>` at the head,
/// with nothing before it.
///
/// The head position is what `volume_prefix` already guarantees: `/Users/<u>`,
/// `/System/Volumes/Data/Users/<u>` and `/Volumes/<n>/Users/<u>` all arrive here
/// as `["Users", "<u>"]`. A deeper `Users` component is a folder that merely
/// shares the name — a project's `Projects/Users/foo` — and must not read as a
/// second home (audit RC-3).
fn is_home_path(path: &[&str]) -> bool {
    path.len() == 2 && path[0] == "Users"
}

/// True when `dir` is a user's home directory as the tree sees it: the scan root
/// itself (`~`, a whole volume, a folder scan), or a node whose usable path is
/// the anchored pair `<Users>/<user>`.
///
/// The second arm is judged from the **reconstructed path**, not from the tree's
/// shape. The old test required the `Users` directory to be a direct child of
/// the scan root (`t.parents[users] == 0`), which can never hold when the scan
/// root *is* `/Users` — the root's `parents[0]` is `NO_PARENT`, not `0`. So a
/// scan of `/Users` recognised no home below it, skipped every home-level
/// narrowing, and nominated `~/Library/Caches`, the shared root the guard
/// refuses. Because the panel's Move does not re-run the guard (the user's tick
/// is the authorization), that row could really be trashed, taking every app's
/// live cache with it (audit L3/RC-1).
fn is_home_dir(t: &Tree, root: &ScanRoot<'_>, dir: u32) -> bool {
    if dir == 0 {
        return true;
    }
    let mut path = root.parts.clone();
    path.extend(node_below(t, dir));
    is_home_path(&path)
}

/// The user's own `Library/Caches` — `~/Library/Caches`, or
/// `<root>/Users/<user>/Library/Caches`. `library` is the **Library node**.
///
/// This exists because `~/Library/Caches` is a *shared, app-wide* cache root:
/// `CleanupGuard.tooBroad` refuses it as too broad, and only its named
/// subfolders are fair game. Recognition must not advertise a folder that
/// authorization will refuse, or the panel offers a Move that fails with
/// "Too broad". Deeper `Library/Caches` directories belong to one app or
/// simulator and stay nominated.
///
/// `library == 0` answers `true`: node 0 is the scan root, and the scan root is
/// the boundary its own children are measured from. That is the **folder scan of
/// `~/Library`**, where the Library *is* node 0 — `parent_of` returns `None` for
/// it, so an ancestor walk cannot see it, and without this arm such a scan
/// offered `Caches`, the very too-broad root the guard refuses (audit RC-2).
/// A service root (`/Library`, `/Applications`) behaves the same way, and that
/// is correct rather than a leak: the guard refuses `<root>/Library/Caches`
/// there as "Outside your home folder", so recognition must stay silent too.
fn is_home_library(t: &Tree, root: &ScanRoot<'_>, library: u32) -> bool {
    if library == 0 {
        return true;
    }
    parent_of(t, library).is_some_and(|home| is_home_dir(t, root, home))
}

/// True when a directory is the home-level broad cache root the guard refuses:
/// `~/.cache`. `.npm` and `.gradle` are per-tool and stay nominated, and a
/// *nested* `.cache` (a project's) is one owner's data and stays too.
///
/// `i == 0` is the folder scan of `~/.cache` itself, for the same reason as
/// `is_home_library`: node 0 is the boundary its children are measured from.
fn is_home_broad_cache(t: &Tree, root: &ScanRoot<'_>, i: u32) -> bool {
    if i == 0 {
        return true;
    }
    parent_of(t, i).is_some_and(|home| is_home_dir(t, root, home))
}

/// True when `dir` is a real application bundle rather than a directory that
/// merely ends in `.app`.
///
/// The suffix alone is not enough. macOS names container and support folders
/// that way — `~/Library/Containers/com.example.app`,
/// `~/Library/Application Support/com.cmuxterm.app` — and treating those as
/// bundles would stop recognizing the caches inside them, which are ordinary
/// app data the guard permits. A bundle is identified by its structure, the
/// same two layouts `CleanupGuard.isBundle` accepts, so both owners agree on
/// what a bundle is:
///
/// - the classic macOS bundle, `Contents/Info.plist`;
/// - the flat iOS/Unity wrapper, whose `Info.plist` sits at the bundle root
///   with no `Contents/` at all. `/Applications/ARES.app` wraps one at
///   `Wrapper/ARES.app`, so checking for `Contents` alone would descend into a
///   signed inner bundle.
fn is_app_bundle(t: &Tree, dir: u32) -> bool {
    if !t.is_dir(dir as usize) || !t.name(dir as usize).ends_with(".app") {
        return false;
    }
    if contains(t, dir, "Info.plist") {
        return true;
    }
    t.kids(dir as usize).iter().any(|&c| {
        t.name(c as usize) == "Contents"
            && t.kids(c as usize)
                .iter()
                .any(|&g| t.name(g as usize) == "Info.plist")
    })
}

/// True when the node sits inside an installed application bundle — an
/// ancestor directory that is one (see `is_app_bundle`).
///
/// A bundle is one signed, sealed unit, not a project. Its `node_modules` are
/// what the app ships and `dlopen`s at runtime (Electron unpacks native
/// modules next to `app.asar`), not build output a package manager recreates:
/// removing one makes `codesign` report "a sealed resource is missing or
/// invalid" and the app stops verifying. So a name-based rule ("npm packages,
/// reinstallable") is simply false here, and the guard refuses these paths
/// anyway — `/Applications` is outside `$HOME`, and an app installed there is
/// exactly the case the guard is right about.
///
/// Measured on a real `/Applications`: an unfiltered scan offered exactly two
/// candidates, both of them sealed bundle internals —
/// `Bitwarden.app/Contents/Resources/app.asar.unpacked/node_modules` and
/// `Openship.app/Contents/Resources/dashboard/node_modules`. Both were
/// unselectable ("Outside your home folder"), so the panel advertised two
/// Moves that could only fail. Recognition must not nominate what
/// authorization refuses (module doc).
///
/// This walks ancestors rather than checking the immediate parent because the
/// bundle's `Contents/Resources/…` is several levels down.
fn is_inside_app_bundle(t: &Tree, i: u32) -> bool {
    let mut cur = i;
    loop {
        if let Some(parent) = parent_of(t, cur) {
            if is_app_bundle(t, parent) {
                return true;
            }
            cur = parent;
        } else {
            return false;
        }
    }
}

/// True when the node sits under an Apple-managed container prefix, mirroring
/// `CleanupGuard.blockReason(path:)`'s "Managed by macOS" rule exactly.
///
/// That rule refuses a path containing any of:
///   `/Library/Containers/com.apple.`
///   `/Library/Caches/com.apple.`
///   `/Library/Group Containers/group.com.apple.`
///
/// Apple's own app data will not move and macOS rebuilds it anyway. Those paths
/// really do reach the heuristics — a simulator's `data/Containers/Shared/
/// SystemGroup/systemgroup.com.apple.lsd.iconscache/Library/Caches` matches the
/// `Caches`-under-`Library` rule — so without this check the engine advertises
/// hundreds of folders the guard then blocks. Measured on a real home: 428 such
/// nominees, 426 of them refused. Recognition must not nominate what
/// authorization refuses (module doc), so the same three prefixes are tested
/// here, component-wise, rather than a looser "any `com.apple.` ancestor"
/// which would also suppress legitimate folders.
fn is_apple_managed(t: &Tree, i: u32) -> bool {
    // The marker sits at the node itself (a `Caches` dir) or an ancestor; walk
    // up at most a bounded number of levels, stopping at the root.
    let mut cur = i;
    loop {
        let name = t.name(cur as usize);
        if let Some(parent) = parent_of(t, cur) {
            let parent_name = t.name(parent as usize);
            // <...>/Library/Containers/com.apple.… and <...>/Library/Caches/com.apple.…
            if name.starts_with("com.apple.")
                && (parent_name == "Containers" || parent_name == "Caches")
                && parent_of(t, parent).is_some_and(|g| t.name(g as usize) == "Library")
            {
                return true;
            }
            // <...>/Library/Group Containers/group.com.apple.…
            if name.starts_with("group.com.apple.")
                && parent_name == "Group Containers"
                && parent_of(t, parent).is_some_and(|g| t.name(g as usize) == "Library")
            {
                return true;
            }
            cur = parent;
        } else {
            return false;
        }
    }
}

/// `CACHEDIR.TAG`, the published cache declaration
/// (<https://bford.info/cachedir/>). Its presence at a known location is the
/// tool's own statement that the directory holds a cache.
const CACHEDIR_TAG: &str = "CACHEDIR.TAG";

/// One tool's cache, identified by *where it is* plus what the tool itself puts
/// there.
///
/// `kind()` stays the owner of the *shape* names (`node_modules`, `target`);
/// this table owns the *identity* locations, so a new tool is one row plus one
/// test instead of a new `match` arm.
///
/// `rel` is home-relative and split on `/`, so a row can name a nested path
/// (`Library/pnpm/store`). `any_of` holds **groups** of marker paths: the
/// directory qualifies when every group has at least one present descendant.
/// Most rows are one group with one marker; pnpm's store needs two, because
/// `files/` alone is also what an unrelated store-shaped folder would have while
/// `index.db` is pnpm's own database.
///
/// Every row was observed on a real machine (see the evidence note beside the
/// plan). A row that could not be confirmed by running the tool was dropped
/// rather than guessed: the table is additive, so a missing row costs an
/// optimisation, while a guessed one risks offering a folder that is not a cache.
///
/// The location is the path test and the marker is the structure test, so the
/// two halves cannot be satisfied by a name alone: `~/Projects/foo/store` is not
/// `~/Library/pnpm/store`, and a folder carrying `CACHEDIR.TAG` under
/// `~/Projects` is not uv's cache.
///
/// `CACHEDIR.TAG` is treated as a validating marker here rather than as a
/// universal rule ("any tagged directory anywhere is a cache"). A universal rule
/// would nominate tagged directories outside this table — including ones inside
/// `~/Documents`, which `CleanupGuard` refuses — and recognition must never
/// offer what authorization refuses (module doc).
struct CacheRule {
    /// The tool that owns this cache, carried all the way to `Kind::ToolCache`
    /// so the panel, the CLI and the agent prompt can say *which* tool a
    /// candidate belongs to instead of a generic "tool caches". It never
    /// reaches the published `category` wire value, which stays `tool_caches`.
    name: &'static str,
    rel: &'static str,
    any_of: &'static [&'static [&'static str]],
}

/// What each tool puts in its cache, home-relative. See `CacheRule`.
///
/// Not listed, deliberately: `~/.npm` is already recognised by shape in
/// `kind()`, and `find` never descends into a recognised folder — so a row for
/// `~/.npm/_cacache` or `~/.npm/_npx` would be unreachable code. Measured
/// through the CLI: a fixture with both npm locations present reports `.npm`
/// alone. The whole `.npm` tree is the candidate, which is why `_cacache`'s own
/// markers must not be a rule: they could never be consulted.
const CACHE_RULES: &[CacheRule] = &[
    // uv declares its own cache; measured `~/.cache/uv/CACHEDIR.TAG`.
    CacheRule { name: "uv", rel: ".cache/uv", any_of: &[&[CACHEDIR_TAG]] },
    // Cargo declares the whole registry a cache: measured
    // `~/.cargo/registry/CACHEDIR.TAG` at the registry root, with `cache/`
    // holding `<registry>-<hash>` directories that no name rule can match.
    // Naming `.cargo/registry` is what the tool's own tag marks.
    CacheRule { name: "Cargo", rel: ".cargo/registry", any_of: &[&[CACHEDIR_TAG]] },
    // Cargo's git databases are git repositories, so the marker is git's own:
    // measured ten `<name>-<hash>` children, each holding `FETCH_HEAD`.
    CacheRule { name: "Cargo", rel: ".cargo/git/db", any_of: &[&["*/FETCH_HEAD"]] },
    // pnpm's store is versioned: measured `v11/files` and `v11/index.db`, so
    // the version directory is the wildcard and both of its markers are
    // required — `files/` alone is also what an unrelated store-shaped folder
    // would have, while the 43 MB `index.db` is pnpm's own database.
    CacheRule { name: "pnpm", rel: "Library/pnpm/store", any_of: &[&["*/files"], &["*/index.db"]] },
    // pip's HTTP cache: `http-v2` today, `http/` before 2020.
    CacheRule { name: "pip", rel: "Library/Caches/pip", any_of: &[&["http-v2", "http"]] },
    // Homebrew's own metadata. Bottles are cached only sometimes (measured:
    // zero here), so they cannot be a marker, and brew re-downloads them.
    CacheRule { name: "Homebrew", rel: "Library/Caches/Homebrew", any_of: &[&["api"]] },
    CacheRule { name: "CocoaPods", rel: "Library/Caches/CocoaPods", any_of: &[&["Pods"]] },
    CacheRule { name: "SwiftPM", rel: "Library/Caches/org.swift.swiftpm", any_of: &[&["manifests"]] },
];

/// True when `dir` (or, for a multi-component marker, one of its descendants)
/// carries the marker `pattern`.
///
/// A marker is a `/`-separated path relative to the cache directory, and the
/// component `*` matches any single child. The wildcard exists for the one shape
/// a fixed name cannot express: Cargo's git databases are
/// `<name>-<hash>/FETCH_HEAD`, where the hash is unknowable in advance but git's
/// own `FETCH_HEAD` inside each database directory is not. It is deliberately one
/// component and not a glob language: a marker must stay a structural statement,
/// not a pattern that can be widened until it matches.
fn has_marker(t: &Tree, dir: u32, pattern: &str) -> bool {
    match pattern.split_once('/') {
        None => contains(t, dir, pattern),
        Some((head, rest)) => t.kids(dir as usize).iter().any(|&child| {
            (head == "*" || t.name(child as usize) == head) && has_marker(t, child, rest)
        }),
    }
}

/// True when the directory `i` satisfies every marker group of `rule`.
///
/// A group is satisfied by any one of its alternatives, so a group with two
/// (`http-v2` vs `http`) accepts whichever layout the tool left behind.
fn satisfies(t: &Tree, i: u32, rule: &CacheRule) -> bool {
    rule.any_of
        .iter()
        .all(|alternatives| alternatives.iter().any(|m| has_marker(t, i, m)))
}

/// The facts about a scan root that recognition needs, computed **once per
/// tree** rather than per candidate.
///
/// The table's rules are written in the volume's own path — `Library/pnpm/store`
/// means `/Users/<user>/Library/pnpm/store` — but a scan root is not always that
/// path:
///
/// - the app's default target is `/System/Volumes/Data` (the writable Data
///   volume behind `/`), whose first component is `System`;
/// - an external drive is `/Volumes/<name>`;
/// - a folder scan is `/Users/me/Library/Caches`, itself below the home.
///
/// The two volume prefixes are **transparent**: a path below one is the same
/// path the rules name, so only the part after the prefix is usable. `parts` is
/// that usable prefix; a candidate's components run through it and then carry on
/// below the root (see `ScannedPath`).
struct ScanRoot<'a> {
    /// The root's usable prefix: its absolute components, volume prefix removed.
    parts: Vec<&'a str>,
    /// The root's own name was an absolute path. Only the no-`Users` fallback
    /// consults this; a `Users/<name>` component is evidence enough on its own.
    absolute: bool,
}

/// The length of the transparent volume prefix at the start of `parts`.
///
/// `/System/Volumes/Data` is the Data volume and `/Volumes/<name>` an external
/// drive; both are stripped so `Users/me/...` below them is recoverable. A `/`
/// root matches neither and keeps its empty prefix: stripping it would leave
/// `Volumes/<name>` looking like the path itself.
fn volume_prefix(parts: &[&str]) -> usize {
    if parts.starts_with(&["System", "Volumes", "Data"]) {
        return 3;
    }
    if parts.len() > 1 && parts[0] == "Volumes" {
        return 2;
    }
    0
}

/// The scan root's facts, read once per `find` (see `tool_cache`).
fn scan_root(t: &Tree) -> ScanRoot<'_> {
    let all: Vec<&str> = t.name(0).split('/').filter(|p| !p.is_empty()).collect();
    ScanRoot {
        parts: all[volume_prefix(&all)..].to_vec(),
        // A relative fixture must not be able to pretend to be an absolute home
        // (the legacy contract's own guard).
        absolute: t.name(0).starts_with('/'),
    }
}

impl ScanRoot<'_> {
    /// The root's usable prefix is a user's home, so the legacy contract holds:
    /// the rule may begin at or below the root (a `HOME` that is not under
    /// `/Users` — the CLI's tests use a temporary directory and macOS puts a
    /// sandboxed process under `/private/var/folders`).
    ///
    /// This is the *only* way a path with no `/Users/<name>` is accepted, and it
    /// deliberately refuses the service and system roots the guard calls
    /// "Outside your home folder": `/Library`, `/Library/Caches`,
    /// `/private/tmp/<anything>`, `/Applications`, `/opt`, `/usr`, `/System` and
    /// a bare `/`. Recognition must not offer what authorization refuses (module
    /// doc). `var/folders/...` is the one exception, because that really is the
    /// home of a sandboxed process.
    fn is_home(&self) -> bool {
        if !self.absolute {
            return false; // a relative fixture is not a home
        }
        let Some((first, rest)) = self.parts.split_first() else {
            return false; // a bare `/` is not a home
        };
        match *first {
            // Service and system directories: never a home, and a folder scan
            // rooted in one can hold a `Library/Caches/<tool>`-shaped subtree.
            "Applications" | "usr" | "opt" | "bin" | "sbin" | "Developer" | "Network"
            | "Library" | "System" | "Volumes" | ".cache" => false,
            // `/var/folders/<…>` is a sandboxed process's home; `/var` and
            // `/var/tmp` are not. macOS hands the same home out under the
            // `/private` prefix (`/private/var/folders/…`, `/var` being a
            // symlink), and a resolved scan root reaches it that way.
            "var" => rest.first() == Some(&"folders"),
            // `/private/tmp/…` is a shared scratch directory, not a home.
            "private" => rest.starts_with(&["var", "folders"]),
            _ => true,
        }
    }
}

/// One node's path, in the components the rules are written in: the root's usable
/// prefix followed by the names the tree holds below it.
///
/// Built once per node (`tool_cache`) and lent to every rule, instead of the old
/// per-rule `Vec` of root parts, path and wanted components.
struct ScannedPath<'a> {
    root: &'a ScanRoot<'a>,
    below: &'a [&'a str],
}

impl ScannedPath<'_> {
    /// Components run through the root's prefix and then continue below it: a
    /// folder scan's rule begins *inside* the prefix (`~/Library/Caches` scanning
    /// down to `pip`), a home or volume scan's begins below it.
    fn component(&self, i: usize) -> &str {
        match self.root.parts.get(i) {
            Some(part) => part,
            None => self.below[i - self.root.parts.len()],
        }
    }

    fn len(&self) -> usize {
        self.root.parts.len() + self.below.len()
    }
}

/// True when `i` is the directory a cache rule names, judged by the *path* the
/// scan reached rather than by a name.
///
/// The rules are home-relative, and the panel produces these shapes this must
/// answer for:
///
/// - a home scan, where node 0 is the home and the rule is the path below it;
/// - a whole-volume scan, where the home is `<root>/Users/<user>`;
/// - the app's default whole-disk scan, rooted at `/System/Volumes/Data`;
/// - an external drive, rooted at `/Volumes/<name>`;
/// - a **folder** scan, where node 0 is a folder *below* the home
///   (`~/Library/Caches`). Measured before this: scanning `~/Library/Caches`
///   offered neither pip nor Homebrew, and scanning `~/Library/pnpm` offered no
///   store — the user had picked exactly the folder holding the cache they
///   wanted cleaned.
///
/// All of them are one test: the rule's components must be the path's exact
/// tail, and the position they begin at must be a home boundary — the first
/// `Users` component with exactly one user name after it, or (when the path holds
/// no `Users` at all) a scan root that is itself a plausible home.
///
/// "First `Users` component with a user name after it" is what makes both
/// directions right at once. `rposition` used to take the *deepest* `Users`, so
/// `/Users/me/Projects/Users/foo/Library/pnpm/store` anchored its rule at a fake
/// home inside a user's project, while a user literally named `Users`
/// (`/Users/Users`) was refused by the same mistake. Requiring `k + 2 == start`
/// then keeps `/Users/Library/pnpm/store` (no user component at all) and
/// `/Users/me/Projects/Library/Caches/pip` (the tail begins past the project
/// boundary) refused.
///
/// Nothing here is sufficient on its own: the rule's marker must also be present
/// (`satisfies`), so `~/Projects/foo/store` is refused for having no pnpm
/// structure even though its path is unremarkable.
fn at_rule_location(path: &ScannedPath<'_>, rule: &CacheRule) -> bool {
    let parts = rule.rel.split('/');
    let count = parts.clone().count();
    let Some(start) = path.len().checked_sub(count) else {
        return false;
    };
    // The rule must be the path's exact tail, compared one component at a time:
    // no per-rule `Vec` of wanted components.
    if parts.enumerate().any(|(k, part)| path.component(start + k) != part) {
        return false;
    }
    // ...anchored at a home boundary. `Users` may sit in the root's own prefix
    // (a folder scan below `~/Library/Caches`) or below it (a whole-volume scan),
    // so the whole path is searched.
    match (0..path.len()).position(|k| path.component(k) == "Users") {
        // A `Users` component must be followed by a user name, the rule must
        // begin right after that pair, AND the pair must sit at a real volume
        // boundary — the head of the usable prefix.
        //
        // The boundary test is what makes a literal `Users` directory harmless
        // anywhere else. `is_home()` already refuses `/opt`, `/private/tmp` and
        // `/Network` as homes, but it is only consulted on the no-`Users` branch,
        // so a project directory named `Users` under any of them re-enabled every
        // table row and nominated caches the guard then refused as "Outside your
        // home folder" (audit RC-4).
        Some(k) => k == 0 && k + 1 < path.len() && k + 2 == start,
        // No `Users` anywhere: the root is the home boundary, when it is a home,
        // and the rule must begin at or below it.
        None => path.root.is_home() && start <= path.root.parts.len(),
    }
}

/// The tool-cache row `i` matches, if any: the first rule whose location
/// (`at_rule_location`) and marker (`satisfies`) both hold, carried out as the
/// row's own tool name.
///
/// The node's path prefix is built once here for all eight rules, and the scan
/// root's facts are passed in from `find` rather than recomputed per candidate.
fn tool_cache(t: &Tree, root: &ScanRoot<'_>, i: u32) -> Option<Kind> {
    // A fast path first: only a node whose name is some row's last component can
    // match, so the common node never builds a path at all. It decides nothing —
    // the full comparison below still decides the answer.
    let name = t.name(i as usize);
    if !CACHE_RULES.iter().any(|rule| rule.rel.rsplit('/').next() == Some(name)) {
        return None;
    }
    // The node's path, once for all eight rules.
    let below = node_below(t, i);
    let path = ScannedPath { root, below: &below };
    CACHE_RULES
        .iter()
        .find(|rule| at_rule_location(&path, rule) && satisfies(t, i, rule))
        .map(|rule| Kind::ToolCache(rule.name))
}

/// The names on the path from the root's children down to `i`, outermost first.
/// One `Vec` per node, not one per rule.
fn node_below(t: &Tree, i: u32) -> Vec<&str> {
    let mut below = Vec::new();
    let mut cur = i;
    while cur != 0 {
        below.push(t.name(cur as usize));
        cur = t.parents[cur as usize];
    }
    below.reverse();
    below
}

/// What `i` is, with the scan root's facts already computed. `find` computes them
/// once per tree; tests reach this through the `kind` helper in their own module.
fn kind_at(t: &Tree, root: &ScanRoot<'_>, i: u32) -> Option<Kind> {
    if is_apple_managed(t, i) || is_inside_app_bundle(t, i) {
        return None;
    }
    let parent = t.parents[i as usize];
    // The node's path in the components the rules are written in, built once.
    // Every name test below reads a *reconstructed* component rather than
    // `t.name(parent)`: a scan root's name is its whole absolute path, so when
    // the parent IS the scan root that call yields "/Users/me/…/Xcode" instead
    // of "Xcode", and a folder scan rooted at the folder holding the cache
    // silently lost it (audit RC-2).
    let below = node_below(t, i);
    let path = ScannedPath { root, below: &below };
    let name = path.component(path.len().saturating_sub(1));
    let parent_name = if path.len() >= 2 { path.component(path.len() - 2) } else { "" };
    // Marker lookups happen only for the named artifact, not every sibling.
    match name {
        "node_modules" => Some(Kind::NodeModules),
        ".venv" => Some(Kind::PythonEnvironment),
        "venv" if contains(t, i, "pyvenv.cfg") => Some(Kind::PythonEnvironment),
        "target" if contains(t, parent, "Cargo.toml") => Some(Kind::RustBuild),
        ".next" if contains(t, parent, "package.json") => Some(Kind::NextBuild),
        "DerivedData" if parent_name == "Xcode" => Some(Kind::XcodeDerivedData),
        "iOS DeviceSupport" | "macOS DeviceSupport" | "watchOS DeviceSupport" => {
            Some(Kind::DeviceSupport)
        }
        // Not the home's own Library/Caches: that root is too broad (see
        // `is_home_library`). A simulator's or an app's deeper Library/Caches is
        // one owner's data and stays a candidate. `full` is this node's own path.
        "Caches" if parent_name == "Library" && !is_home_library(t, root, parent) => {
            Some(Kind::AppCaches)
        }
        "Caches" if parent_name == "CoreSimulator" => Some(Kind::AppCaches),
        // `.cache` at the home root is too broad; a tool's own nested `.cache`
        // (e.g. a project's) is not.
        ".cache" if !is_home_broad_cache(t, root, i) => Some(Kind::ToolCaches),
        ".npm" | ".gradle" => Some(Kind::ToolCaches),
        // `<home>/.bun/install/cache`, in the components the rules are written
        // in rather than by bare parent names (RC-2).
        "cache"
            if parent_name == "install"
                && path.len() >= 3
                && path.component(path.len() - 3) == ".bun" =>
        {
            Some(Kind::BunCache)
        }
        // Identity locations (§5): a tool's cache found by where it is and what
        // the tool puts there. Checked last so the shape rules above stay the
        // cheapest path, and only for a directory under a home directory.
        _ => tool_cache(t, root, i),
    }
}

/// Existing panel semantics: visit descendants (not the scan root), skip
/// `.Trash`, and never descend into a recognized folder, even below threshold.
/// Size ties use paths so parallel scan scheduling cannot reorder the report.
pub fn find(t: &Tree, min_bytes: u64) -> Vec<Candidate> {
    let mut found = Vec::new();
    if t.is_empty() {
        return found;
    }
    // The root's facts, once for the whole walk rather than once per candidate.
    let root = scan_root(t);
    let mut stack = vec![0];
    while let Some(i) = stack.pop() {
        for &child in t.kids(i) {
            let c = child as usize;
            // Skip this subtree, not later siblings (the final sort decides order).
            if t.alloc[c] < min_bytes || !t.is_dir(c) || t.name(c) == ".Trash" {
                continue;
            }
            if let Some(kind) = kind_at(t, &root, child) {
                found.push(Candidate { node: child, kind });
            } else {
                stack.push(c);
            }
        }
    }
    found.sort_by(|a, b| {
        t.alloc[b.node as usize]
            .cmp(&t.alloc[a.node as usize])
            .then_with(|| t.path(a.node as usize).cmp(&t.path(b.node as usize)))
    });
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Sizes are set per node as given (not aggregated). Siblings must be
    /// added consecutively, as a scan appends them; `link` then lists them.
    fn add(scan: &mut Tree, parent: u32, name: &str, is_dir: bool, bytes: u64) -> u32 {
        if parent == NO_PARENT {
            *scan = Tree::with_root(name);
            scan.alloc[0] = bytes;
            scan.logical[0] = bytes;
            return 0;
        }
        assert!(
            scan.parents.last() == Some(&parent) || !scan.parents.contains(&parent),
            "siblings are contiguous"
        );
        scan.push(name, parent, bytes, bytes, is_dir)
    }

    fn link(mut scan: Tree) -> Tree {
        scan.link_children();
        scan
    }

    #[test]
    fn recognizes_all_existing_panel_rules_and_no_new_ones() {
        // Each row has an independent context, including the legacy name-only
        // marker behavior. No filesystem access is needed for classification.
        let cases = [
            (
                "node_modules",
                "project",
                "",
                "",
                "",
                Some(Kind::NodeModules),
            ),
            (
                ".venv",
                "project",
                "",
                "",
                "",
                Some(Kind::PythonEnvironment),
            ),
            (
                "venv",
                "project",
                "",
                "",
                "pyvenv.cfg",
                Some(Kind::PythonEnvironment),
            ),
            ("venv", "project", "", "", "", None),
            (
                "target",
                "project",
                "",
                "Cargo.toml",
                "",
                Some(Kind::RustBuild),
            ),
            ("target", "project", "", "", "", None),
            (
                ".next",
                "project",
                "",
                "package.json",
                "",
                Some(Kind::NextBuild),
            ),
            (".next", "project", "", "", "", None),
            (
                "DerivedData",
                "Xcode",
                "",
                "",
                "",
                Some(Kind::XcodeDerivedData),
            ),
            ("DerivedData", "other", "", "", "", None),
            (
                "iOS DeviceSupport",
                "any",
                "",
                "",
                "",
                Some(Kind::DeviceSupport),
            ),
            (
                "macOS DeviceSupport",
                "any",
                "",
                "",
                "",
                Some(Kind::DeviceSupport),
            ),
            (
                "watchOS DeviceSupport",
                "any",
                "",
                "",
                "",
                Some(Kind::DeviceSupport),
            ),
            // The grandparent field is a `/`-separated chain under the scan
            // root, so a row can express the home shape `<root>/Users/<user>`
            // that the narrowing keys on. A `Caches` under a non-home `Library`
            // (an app's or a simulator's) stays a candidate; the home-level
            // `~/Library/Caches` is the too-broad root and is not one.
            ("Caches", "Library", "", "", "", Some(Kind::AppCaches)),
            ("Caches", "Library", "Users/me", "", "", None),
            ("Caches", "CoreSimulator", "", "", "", Some(Kind::AppCaches)),
            ("Caches", "other", "", "", "", None),
            (".cache", "any", "", "", "", Some(Kind::ToolCaches)),
            // `~/.cache` (a home-level `me`) does not.
            (".cache", "me", "Users", "", "", None),
            (".npm", "any", "", "", "", Some(Kind::ToolCaches)),
            (".gradle", "any", "", "", "", Some(Kind::ToolCaches)),
            ("cache", "install", ".bun", "", "", Some(Kind::BunCache)),
            ("cache", "install", "other", "", "", None),
            ("cache", "other", ".bun", "", "", None),
            (".build", "project", "", "Package.swift", "", None),
            ("Downloads", "home", "", "", "", None),
        ];
        for (name, parent, grandparent, sibling, child, expected) in cases {
            let mut scan = Tree::default();
            add(&mut scan, NO_PARENT, "/", true, 0);
            // A bare "" keeps the legacy one-level grandparent; anything else is
            // walked as a chain, so "Users/me" reaches the home directory.
            let mut gp = 0;
            for part in grandparent.split('/') {
                gp = add(&mut scan, gp, part, true, MIN_BYTES);
            }
            let p = add(&mut scan, gp, parent, true, MIN_BYTES);
            let i = add(&mut scan, p, name, true, MIN_BYTES);
            if !sibling.is_empty() {
                add(&mut scan, p, sibling, false, 0);
            }
            if !child.is_empty() {
                add(&mut scan, i, child, false, 0);
            }
            let scan = link(scan);
            assert_eq!(kind(&scan, i), expected, "{grandparent}/{parent}/{name}");
            assert_eq!(
                find(&scan, MIN_BYTES),
                expected
                    .map(|kind| Candidate { node: i, kind })
                    .into_iter()
                    .collect::<Vec<_>>()
            );
        }
    }

    #[test]
    fn home_level_cache_roots_are_not_candidates() {
        // ~/Library/Caches is a shared, app-wide cache root: CleanupGuard's
        // `tooBroad` refuses it, and only its named subfolders go. Recognition
        // must not offer a folder authorization will refuse, or the panel shows
        // a Move that fails with "Too broad". Each case is its own tree so the
        // sibling-contiguity rule `add` enforces holds (a parent's children are
        // appended in one batch, as the walk does).
        let chain = |names: &[&str], bytes: u64| {
            let mut scan = Tree::default();
            add(&mut scan, NO_PARENT, names[0], true, 0);
            let mut parent = 0;
            let mut last = 0;
            for name in &names[1..] {
                last = add(&mut scan, parent, name, true, bytes);
                parent = last;
            }
            (link(scan), last)
        };

        // A home scan: the root IS the home, so ~/Library/Caches is the broad root.
        let (scan, caches) = chain(&["/Users/me", "Library", "Caches"], MIN_BYTES);
        assert_eq!(kind(&scan, caches), None, "~/Library/Caches is too broad to offer");
        assert!(find(&scan, MIN_BYTES).is_empty(), "nothing to offer inside a home Library");

        // A whole-volume scan: the home is /Users/<user>, still the same root.
        let (scan, caches) = chain(&["/", "Users", "me", "Library", "Caches"], MIN_BYTES);
        assert_eq!(kind(&scan, caches), None, "/Users/me/Library/Caches is the same broad root");

        // A simulator's or an app's deeper Library/Caches is one owner's data and
        // must stay a candidate — this is the real path the panel reports.
        let (scan, caches) = chain(
            &["/", "Device", "data", "Library", "Caches"],
            MIN_BYTES,
        );
        assert_eq!(kind(&scan, caches), Some(Kind::AppCaches));

        // `~/.cache` is the broad root; `.npm`/`.gradle` are per-tool and stay.
        let (scan, dotcache) = chain(&["/Users/me", ".cache"], MIN_BYTES);
        assert_eq!(kind(&scan, dotcache), None, "~/.cache is too broad to offer");
        let (scan, dotcache) = chain(&["/Users/me", "proj", ".cache"], MIN_BYTES);
        assert_eq!(kind(&scan, dotcache), Some(Kind::ToolCaches), "a nested .cache is not");
        let (scan, npm) = chain(&["/Users/me", ".npm"], MIN_BYTES);
        assert_eq!(kind(&scan, npm), Some(Kind::ToolCaches));
        let (scan, gradle) = chain(&["/Users/me", ".gradle"], MIN_BYTES);
        assert_eq!(kind(&scan, gradle), Some(Kind::ToolCaches));
    }

    #[test]
    fn apple_managed_container_caches_are_not_candidates() {
        // The guard refuses these as "Managed by macOS"; the `Caches`-under-
        // `Library` rule would otherwise match them, so the engine used to
        // advertise hundreds of folders the user could not act on (measured:
        // 428 nominees, 426 refused, on a real home).
        let chain = |names: &[&str]| {
            let mut scan = Tree::default();
            add(&mut scan, NO_PARENT, names[0], true, 0);
            let mut parent = 0;
            let mut last = 0;
            for name in &names[1..] {
                last = add(&mut scan, parent, name, true, MIN_BYTES);
                parent = last;
            }
            (link(scan), last)
        };

        // The three prefixes the guard's "Managed by macOS" rule names.
        for names in [
            &["/", "Library", "Containers", "com.apple.Safari", "Data", "Library", "Caches"][..],
            &["/", "Library", "Caches", "com.apple.example"][..],
            &["/", "Library", "Group Containers", "group.com.apple.example", "Library", "Caches"][..],
        ] {
            let (scan, node) = chain(names);
            assert_eq!(kind(&scan, node), None, "{names:?} is Apple-managed");
        }

        // A simulator's SystemGroup cache is NOT one of those three prefixes:
        // the guard permits it, so recognition must keep nominating it.
        let (scan, node) = chain(&[
            "/", "Developer", "CoreSimulator", "Devices", "UUID", "data", "Containers", "Shared",
            "SystemGroup", "systemgroup.com.apple.lsd.iconscache", "Library", "Caches",
        ]);
        assert_eq!(kind(&scan, node), Some(Kind::AppCaches));

        // A non-Apple container cache under Library/Containers stays a candidate.
        let (scan, node) = chain(&["/", "Library", "Containers", "com.example.app", "Data", "Library", "Caches"]);
        assert_eq!(kind(&scan, node), Some(Kind::AppCaches));
    }

    #[test]
    fn app_bundle_internals_are_not_candidates() {
        // A bundle is one signed, sealed unit: its node_modules are shipped to
        // be loaded at runtime, not build output to recreate. Offering them
        // showed the user Moves that could only fail — measured on a real
        // /Applications, an unfiltered scan offered exactly these two paths and
        // the guard refused both ("Outside your home folder").
        //
        // A bundle fixture needs `Contents/Info.plist`: that structure is what
        // distinguishes a bundle from a folder that merely ends in `.app` (see
        // `is_app_bundle`). `bundle_app` adds the `.app` and its `Contents`
        // directory and returns both, so the caller hangs the rest off it.
        // Each directory's children are added in one batch, as `add` requires.
        let bundle_app = |scan: &mut Tree, parent: u32, name: &str| {
            let app = add(scan, parent, name, true, MIN_BYTES * 10);
            let contents = add(scan, app, "Contents", true, MIN_BYTES * 10);
            add(scan, contents, "Info.plist", false, 0);
            (app, contents)
        };

        // /Applications/Bitwarden.app/Contents/Resources/app.asar.unpacked/node_modules
        let mut scan = Tree::default();
        add(&mut scan, NO_PARENT, "/", true, 0);
        let apps = add(&mut scan, 0, "Applications", true, MIN_BYTES * 10);
        let (_, bw_contents) = bundle_app(&mut scan, apps, "Bitwarden.app");
        let resources = add(&mut scan, bw_contents, "Resources", true, MIN_BYTES * 10);
        let unpacked = add(&mut scan, resources, "app.asar.unpacked", true, MIN_BYTES);
        let bw_nm = add(&mut scan, unpacked, "node_modules", true, MIN_BYTES);
        let scan = link(scan);
        assert_eq!(kind(&scan, bw_nm), None, "Bitwarden's sealed node_modules");
        assert!(
            find(&scan, MIN_BYTES).iter().all(|c| c.node != bw_nm),
            "a sealed bundle internal must not be offered at all"
        );

        // /Applications/Openship.app/Contents/Resources/dashboard/node_modules
        let mut scan = Tree::default();
        add(&mut scan, NO_PARENT, "/", true, 0);
        let apps = add(&mut scan, 0, "Applications", true, MIN_BYTES * 10);
        let (_, op_contents) = bundle_app(&mut scan, apps, "Openship.app");
        let resources = add(&mut scan, op_contents, "Resources", true, MIN_BYTES * 10);
        let dashboard = add(&mut scan, resources, "dashboard", true, MIN_BYTES);
        let op_nm = add(&mut scan, dashboard, "node_modules", true, MIN_BYTES);
        assert_eq!(kind(&link(scan), op_nm), None, "Openship's sealed node_modules");

        // The same shape inside the home folder. The guard permits anything
        // under $HOME, so this is the case where a nomination really would be
        // acted on — and it still breaks the bundle's signature.
        let mut scan = Tree::default();
        add(&mut scan, NO_PARENT, "/Users/me", true, 0);
        let lib = add(&mut scan, 0, "Library", true, MIN_BYTES * 10);
        let support = add(&mut scan, lib, "Application Support", true, MIN_BYTES * 10);
        let raycast = add(&mut scan, support, "com.raycast.macos", true, MIN_BYTES * 10);
        let updates = add(&mut scan, raycast, "Updates", true, MIN_BYTES * 10);
        let version = add(&mut scan, updates, "2.6.3", true, MIN_BYTES * 10);
        let (_, rc_contents) = bundle_app(&mut scan, version, "Raycast.app");
        let resources = add(&mut scan, rc_contents, "Resources", true, MIN_BYTES * 10);
        let api = add(&mut scan, resources, "api", true, MIN_BYTES);
        let rc_nm = add(&mut scan, api, "node_modules", true, MIN_BYTES);
        assert_eq!(kind(&link(scan), rc_nm), None, "an in-home bundle is still sealed");

        // A project outside any bundle is untouched: this is the rule's whole
        // purpose and it must keep working.
        let mut scan = Tree::default();
        add(&mut scan, NO_PARENT, "/Users/me", true, 0);
        let projects = add(&mut scan, 0, "projects", true, MIN_BYTES * 10);
        let web = add(&mut scan, projects, "web", true, MIN_BYTES);
        let proj_nm = add(&mut scan, web, "node_modules", true, MIN_BYTES);
        assert_eq!(kind(&link(scan), proj_nm), Some(Kind::NodeModules));

        // A folder that merely ends in `.app` is not a bundle — macOS names
        // containers and app-support folders that way — so the folders inside
        // it stay recognized.
        let mut scan = Tree::default();
        add(&mut scan, NO_PARENT, "/Users/me", true, 0);
        let projects = add(&mut scan, 0, "projects", true, MIN_BYTES * 10);
        let notabundle = add(&mut scan, projects, "com.example.app", true, MIN_BYTES);
        let inner_nm = add(&mut scan, notabundle, "node_modules", true, MIN_BYTES);
        assert_eq!(
            kind(&link(scan), inner_nm),
            Some(Kind::NodeModules),
            "a plain folder named like a bundle is not one"
        );

        // The flat iOS/Unity layout: `Info.plist` at the bundle root and no
        // `Contents/` at all. `/Applications/ARES.app` wraps one of these at
        // `Wrapper/ARES.app`, so a `Contents`-only check descends into a signed
        // inner bundle.
        let mut scan = Tree::default();
        add(&mut scan, NO_PARENT, "/Applications", true, 0);
        let ares = add(&mut scan, 0, "ARES.app", true, MIN_BYTES * 10);
        let wrapper = add(&mut scan, ares, "Wrapper", true, MIN_BYTES * 10);
        let inner = add(&mut scan, wrapper, "ARES.app", true, MIN_BYTES * 10);
        add(&mut scan, inner, "Info.plist", false, 0);
        add(&mut scan, inner, "Resources", true, MIN_BYTES);
        let nm = add(&mut scan, inner, "Resources", true, MIN_BYTES);
        let flat_nm = add(&mut scan, nm, "node_modules", true, MIN_BYTES);
        assert_eq!(
            kind(&link(scan), flat_nm),
            None,
            "a flat wrapper bundle with root Info.plist is a bundle"
        );
    }

    /// Builds a home-rooted chain `<root>/Users/me/<rel…>` and returns the tree
    /// and the node the location rule nominates. The root IS the home here, so
    /// `is_home_dir` recognises node 0 and the rule's relative path is measured
    /// from it — the shape a `~` scan produces.
    fn home_location(rel: &str, marker: fn(&mut Tree, u32)) -> (Tree, u32) {
        let mut scan = Tree::default();
        add(&mut scan, NO_PARENT, "/Users/me", true, 0);
        let mut parent = 0;
        let mut node = 0;
        for part in rel.split('/') {
            node = add(&mut scan, parent, part, true, MIN_BYTES);
            parent = node;
        }
        marker(&mut scan, node);
        (link(scan), node)
    }

    #[test]
    fn tool_cache_locations_need_their_marker_not_just_their_name() {
        // The reliability rule (§5): a candidate must satisfy at least one
        // structural test, never a location alone. Each row has two halves — the
        // tool's own structure present is recognised, and the *same location*
        // with the marker absent is not nominated. The second half is what makes
        // the table trustworthy: it is the difference between reading a cache and
        // guessing at one.
        //
        // `~/.npm` and `~/.bun/install/cache` are deliberately absent: `kind()`
        // already recognises them by shape, and `find` never descends into a
        // recognised folder, so a deeper row under either would be unreachable.
        const CASES: [(&str, fn(&mut Tree, u32)); 8] = [
            // The published cache declaration. Measured on the real ~/.cache/uv:
            // its first line is the `8a477f…` signature. The scan model carries
            // names, not file contents, so the marker is the tag's presence at
            // the tool's own fixed location (see the table's doc comment).
            (".cache/uv", |t, i| {
                add(t, i, "CACHEDIR.TAG", false, 0);
            }),
            // Cargo declares its whole registry a cache (see the table).
            (".cargo/registry", |t, i| {
                add(t, i, "CACHEDIR.TAG", false, 0);
            }),
            // Cargo's git databases are `<name>-<hash>`; measured
            // `zed-a70e2ad075855582`, plus nine more.
            (".cargo/git/db", |t, i| {
                let db = add(t, i, "zed-a70e2ad075855582", true, MIN_BYTES);
                add(t, db, "FETCH_HEAD", false, 0);
            }),
            // pip's HTTP cache: `http-v2` today, `http/` before 2020.
            ("Library/Caches/pip", |t, i| {
                add(t, i, "http-v2", true, MIN_BYTES);
            }),
            // Homebrew keeps its metadata under api/. Bottles are cached only
            // sometimes (measured: zero here), so they cannot be a marker.
            ("Library/Caches/Homebrew", |t, i| {
                add(t, i, "api", true, MIN_BYTES);
            }),
            ("Library/Caches/CocoaPods", |t, i| {
                add(t, i, "Pods", true, MIN_BYTES);
            }),
            ("Library/Caches/org.swift.swiftpm", |t, i| {
                add(t, i, "manifests", true, MIN_BYTES);
            }),
            // pnpm's store is versioned: measured `v11/files` and `v11/index.db`.
            ("Library/pnpm/store", |t, i| {
                let version = add(t, i, "v11", true, MIN_BYTES);
                add(t, version, "files", true, MIN_BYTES);
                add(t, version, "index.db", false, 0);
            }),
        ];

        for (rel, marker) in CASES {
            let (scan, node) = home_location(rel, marker);
            let matched = CACHE_RULES.iter().find(|r| r.rel == rel).expect("every case is a row");
            assert_eq!(kind(&scan, node), Some(Kind::ToolCache(matched.name)), "{rel} with its marker");
            assert_eq!(
                find(&scan, MIN_BYTES),
                vec![Candidate { node, kind: Kind::ToolCache(matched.name) }],
                "{rel} must reach the candidate list"
            );

            // Half two: the same location, the marker removed.
            let (scan, node) = home_location(rel, |_, _| {});
            assert_eq!(kind(&scan, node), None, "{rel} without its marker is just a folder");
            assert!(find(&scan, MIN_BYTES).is_empty(), "{rel} must not be offered");
        }
    }

    #[test]
    fn cache_locations_are_paths_not_names() {
        // The negative half of acceptance criterion 2: a folder that merely
        // *resembles* a cache is not proposed. The table keys on the tool's fixed
        // home-relative location, so the same names elsewhere never match — even
        // carrying every marker the real rows look for.
        let elsewhere = [
            "Projects/foo/store",          // the plan's own example
            "tmp/Homebrew",                // a marker-free folder sharing the name
            "Library/Caches/placeholder",  // a sibling of the real ones
            "projects/Library/pnpm/store", // the right names, the wrong place
            "Library/pnpm/store-old",      // one character away from a real row
            ".cache/puppeteer",            // a cache with no confirmed row
        ];
        for rel in elsewhere {
            let (scan, node) = home_location(rel, |t, i| {
                add(t, i, "CACHEDIR.TAG", false, 0);
                add(t, i, "api", true, MIN_BYTES);
                let version = add(t, i, "v11", true, MIN_BYTES);
                add(t, version, "files", true, MIN_BYTES);
                add(t, version, "index.db", false, 0);
            });
            assert_eq!(kind(&scan, node), None, "{rel} is not a documented location");
            assert!(find(&scan, MIN_BYTES).is_empty(), "{rel} must not be offered");
        }

        // A `tmp` directory merely named `_cacache` is not npm's cache. npm's
        // own tree is recognised by shape at `~/.npm` (below), so the point here
        // is that the name alone buys nothing anywhere else.
        let (scan, node) = home_location("tmp/_cacache", |_, _| {});
        assert_eq!(kind(&scan, node), None, "a tmp directory named _cacache");
        let (scan, node) = home_location("tmp/_cacache", |t, i| {
            add(t, i, "index-v5", true, MIN_BYTES);
            add(t, i, "content-v2", true, MIN_BYTES);
        });
        assert_eq!(kind(&scan, node), None, "even with npm's own two markers");

        // A wrong marker at the right location is still refused: the location
        // does not stand in for the structure.
        for rel in ["Library/pnpm/store", ".cargo/registry", ".cargo/git/db"] {
            let (scan, node) = home_location(rel, |t, i| {
                add(t, i, "tmp", true, MIN_BYTES);
            });
            assert_eq!(kind(&scan, node), None, "{rel} with the wrong marker");
        }
    }

    #[test]
    fn a_location_is_measured_from_the_home_that_contains_it() {
        // A whole-volume scan has more than one `/Users/<name>`, and the table's
        // rules are home-relative. Matching a rule against the *first* home the
        // walk reaches would attribute one user's `Library/pnpm/store` to
        // another's home — offering, and then sizing, a path that is not the
        // user's. The rule is matched on the *tail* of the scanned path, so
        // `/Users/other/Library/pnpm/store` matches the pnpm row as such.
        let mut scan = Tree::default();
        add(&mut scan, NO_PARENT, "/", true, 0);
        let users = add(&mut scan, 0, "Users", true, MIN_BYTES * 10);
        let other = add(&mut scan, users, "other", true, MIN_BYTES * 10);
        let lib = add(&mut scan, other, "Library", true, MIN_BYTES * 10);
        let pnpm = add(&mut scan, lib, "pnpm", true, MIN_BYTES);
        let store = add(&mut scan, pnpm, "store", true, MIN_BYTES);
        let version = add(&mut scan, store, "v11", true, MIN_BYTES);
        add(&mut scan, version, "files", true, MIN_BYTES);
        add(&mut scan, version, "index.db", false, 0);
        let scan = link(scan);
        assert!(at_location(&scan, store, "Library/pnpm/store"));
        assert_eq!(kind(&scan, store), Some(Kind::ToolCache("pnpm")));

        // The same shape one level above a home is not a home-relative location:
        // `/Users/Library/pnpm/store` is not a user's cache.
        let mut scan = Tree::default();
        add(&mut scan, NO_PARENT, "/", true, 0);
        let users = add(&mut scan, 0, "Users", true, MIN_BYTES * 10);
        let lib = add(&mut scan, users, "Library", true, MIN_BYTES * 10);
        let pnpm = add(&mut scan, lib, "pnpm", true, MIN_BYTES);
        let store = add(&mut scan, pnpm, "store", true, MIN_BYTES);
        let version = add(&mut scan, store, "v11", true, MIN_BYTES);
        add(&mut scan, version, "files", true, MIN_BYTES);
        add(&mut scan, version, "index.db", false, 0);
        let scan = link(scan);
        assert_eq!(kind(&scan, store), None, "not under any user's home");
    }

    /// The classifier as `find` calls it, for one node.
    fn kind(t: &Tree, i: u32) -> Option<Kind> {
        kind_at(t, &scan_root(t), i)
    }

    /// The location half of the identity test, as the classifier calls it.
    fn at_location(t: &Tree, i: u32, rel: &str) -> bool {
        let root = scan_root(t);
        let below = node_below(t, i);
        let path = ScannedPath { root: &root, below: &below };
        at_rule_location(&path, CACHE_RULES.iter().find(|r| r.rel == rel).unwrap())
    }

    /// The marker for a `CACHE_RULES` row. `key` may be the row's full `rel` or
    /// the tail a folder scan reaches it through ("pip" for "Library/Caches/pip"),
    /// so tests name a row rather than restating its structure.
    fn marker_for(key: &str) -> fn(&mut Tree, u32) {
        let rel = CACHE_RULES
            .iter()
            .map(|r| r.rel)
            .find(|rel| *rel == key || rel.ends_with(&format!("/{key}")))
            .unwrap_or_else(|| panic!("no CACHE_RULES row for {key}"));
        match rel {
            ".cache/uv" | ".cargo/registry" => |t, i| {
                add(t, i, "CACHEDIR.TAG", false, 0);
            },
            ".cargo/git/db" => |t, i| {
                let db = add(t, i, "zed-a70e2ad075855582", true, MIN_BYTES);
                add(t, db, "FETCH_HEAD", false, 0);
            },
            "Library/pnpm/store" => |t, i| {
                let version = add(t, i, "v11", true, MIN_BYTES);
                add(t, version, "files", true, MIN_BYTES);
                add(t, version, "index.db", false, 0);
            },
            "Library/Caches/pip" => |t, i| {
                add(t, i, "http-v2", true, MIN_BYTES);
            },
            "Library/Caches/Homebrew" => |t, i| {
                add(t, i, "api", true, MIN_BYTES);
            },
            "Library/Caches/CocoaPods" => |t, i| {
                add(t, i, "Pods", true, MIN_BYTES);
            },
            "Library/Caches/org.swift.swiftpm" => |t, i| {
                add(t, i, "manifests", true, MIN_BYTES);
            },
            other => panic!("no marker helper for row {other}"),
        }
    }

    /// An absolute-rooted tree `<root>/<rel…>` with `rel`'s marker, plus the node
    /// the rule nominates. The root's own name carries its absolute path, so the
    /// rule must be measured against the *path the scan reached*, exactly as the
    /// real walk hands it over (node 0 is the scan root, not `/`).
    fn rooted(root: &str, rel: &str, marker: fn(&mut Tree, u32)) -> (Tree, u32) {
        let mut scan = Tree::default();
        add(&mut scan, NO_PARENT, root, true, 0);
        let mut parent = 0;
        let mut node = 0;
        for part in rel.split('/') {
            node = add(&mut scan, parent, part, true, MIN_BYTES);
            parent = node;
        }
        marker(&mut scan, node);
        (link(scan), node)
    }

    #[test]
    fn every_rule_is_found_from_every_scan_root_shape() {
        // B1: the app's default scan target is `/System/Volumes/Data`
        // (`ScanTargets.macintoshHD`), whose first component is `System`. The
        // old `is_system_location` check refused that root outright, so all eight
        // rows were unreachable there — measured on this machine, `quick-wins
        // --root /System/Volumes/Data` reported 51 candidates and ZERO table-row
        // hits while the same scan rooted at `$HOME` reported pnpm, Homebrew and
        // Cargo. The Data volume is *transparent*: its prefix is stripped before
        // the rule is measured, so the path below it is the volume's real one.
        //
        // `/` and an external drive rooted at `/Volumes/<name>` get the same
        // treatment: a whole-disk walk reaches users' caches through them, and
        // `is_system_location` used to refuse `Volumes` wholesale.
        for root in ["/System/Volumes/Data", "/", "/Volumes/Ext"] {
            for rule in CACHE_RULES {
                let rel = format!("Users/me/{}", rule.rel);
                let (scan, node) = rooted(root, &rel, marker_for(rule.rel));
                assert_eq!(
                    kind(&scan, node),
                    Some(Kind::ToolCache(rule.name)),
                    "root {root}: row {} must be recognised",
                    rule.rel
                );
                // The candidate list too, not only the classifier.
                assert_eq!(
                    find(&scan, MIN_BYTES),
                    vec![Candidate { node, kind: Kind::ToolCache(rule.name) }],
                    "root {root}: row {} must reach the candidate list",
                    rule.rel
                );
                // ...and without its marker the same location stays refused, so
                // the new root handling did not weaken the structural half.
                let (scan, node) = rooted(root, &rel, |_, _| {});
                assert_eq!(kind(&scan, node), None, "root {root}: {} needs its marker", rule.rel);
            }
        }

        // A folder scan *below* the Data volume's home: the same three shapes the
        // panel produces for `/`, now under the default target.
        for (root, rel, tool) in [
            ("/System/Volumes/Data/Users/me/Library/Caches", "pip", "pip"),
            ("/System/Volumes/Data/Users/me/Library", "Caches/pip", "pip"),
            ("/System/Volumes/Data/Users/me/Library/pnpm", "store", "pnpm"),
        ] {
            let (scan, node) = rooted(root, rel, marker_for(rel));
            assert_eq!(kind(&scan, node), Some(Kind::ToolCache(tool)), "scan root {root}");
            assert_eq!(find(&scan, MIN_BYTES).len(), 1, "scan root {root} must offer {rel}");
        }
    }

    #[test]
    fn a_home_and_a_folder_below_it_still_find_the_caches() {
        // A home scan (node 0 *is* the home) must keep working, as must a folder
        // scan below the home: the rule's components are the exact path tail.
        // `rel` is the path from the scan root and `tool` the row it belongs to.
        let folder_cases = [
            ("/Users/me", "Library/Caches/pip", "pip"),
            ("/Users/me", "Library/pnpm/store", "pnpm"),
            ("/Users/me/Library/Caches", "pip", "pip"),
            ("/Users/me/Library", "Caches/pip", "pip"),
            ("/Users/me/Library/pnpm", "store", "pnpm"),
        ];
        for (root, rel, tool) in folder_cases {
            let (scan, node) = rooted(root, rel, marker_for(rel));
            assert_eq!(
                kind(&scan, node),
                Some(Kind::ToolCache(tool)),
                "scan root {root} must reach {rel}"
            );
            assert_eq!(find(&scan, MIN_BYTES).len(), 1, "scan root {root} must offer {rel}");
        }
    }

    #[test]
    fn a_scan_of_users_does_not_offer_the_shared_cache_roots() {
        // L3/RC-1, the destructive one. `is_home_dir` used to require the
        // `Users` directory to be a direct child of the scan root
        // (`t.parents[users] == 0`), which can never hold when the scan root IS
        // `/Users`: node 0's parent is `NO_PARENT`. So a scan of `/Users`
        // recognised no home below it, skipped the home-level narrowing, and
        // offered `~/Library/Caches` and `~/.cache` — the shared roots
        // `CleanupGuard.tooBroad` refuses.
        //
        // That is not a dead row here: the panel's Move uses
        // `authority: .userDirect` (`app/CleanupModel.swift`), which skips the
        // guard because the user's tick *is* the authorization. Trashing the row
        // would take every app's live cache with it.
        //
        // The two roots are reached through completely different rules — a
        // `Caches` under a `Library`, and a home-level `.cache` — so both are
        // asserted, and in both spellings the app can produce.
        let pip = |t: &mut Tree, i: u32| {
            add(t, i, "http-v2", true, MIN_BYTES);
        };
        for root in ["/Users", "/System/Volumes/Data/Users", "/Volumes/Ext/Users"] {
            // `~/Library/Caches` — the broad root the panel must never offer.
            let (scan, node) = rooted(root, "erkul/Library/Caches", pip);
            assert_eq!(
                kind(&scan, node),
                None,
                "root {root}: ~/Library/Caches is the shared root the guard refuses"
            );
            assert!(
                find(&scan, MIN_BYTES).is_empty(),
                "root {root}: it must not reach the candidate list either"
            );

            // `~/.cache` — the same narrowing, on the other rule.
            let (scan, node) = rooted(root, "erkul/.cache", pip);
            assert_eq!(kind(&scan, node), None, "root {root}: ~/.cache is too broad");
            assert!(find(&scan, MIN_BYTES).is_empty(), "root {root}: nor in the list");

            // The control: a *named* subfolder of the same roots is fair game,
            // so the fix must not have silenced the whole subtree.
            let (scan, node) = rooted(root, "erkul/Library/Caches/pip", pip);
            assert_eq!(
                kind(&scan, node),
                Some(Kind::ToolCache("pip")),
                "root {root}: a named cache under the broad root still goes"
            );
        }
    }

    #[test]
    fn a_folder_scan_of_the_folder_holding_a_cache_finds_it() {
        // RC-2. The shape rules compared `t.name(parent)`, but a scan root's
        // name is its **whole absolute path**: scanning `~/Library/Developer/Xcode`
        // makes that the parent's name, so `parent_name == "Xcode"` was false
        // and `DerivedData` — 2.0 GB on the machine this was measured on — was
        // never offered. Same for `.../CoreSimulator`, `~/.bun/install` and
        // `~/Library` (whose `Caches` is the broad root, so it must stay out).
        //
        // The measured pair: a `$HOME` scan offered DerivedData, and a scan of
        // its own parent — the folder a user picks precisely to clean it —
        // offered nothing.
        let (scan, node) = rooted("/Users/me/Library/Developer/Xcode", "DerivedData", |t, i| {
            add(t, i, "build", true, MIN_BYTES);
        });
        assert_eq!(
            kind(&scan, node),
            Some(Kind::XcodeDerivedData),
            "a folder scan of the folder holding DerivedData must find it"
        );
        assert_eq!(find(&scan, MIN_BYTES).len(), 1, "and reach the candidate list");

        // The same for the `.bun` identity rule, which compared two bare names.
        let (scan, node) = rooted("/Users/me/.bun/install", "cache", |_, _| {});
        assert_eq!(kind(&scan, node), Some(Kind::BunCache), "~/.bun/install/cache");

        // A folder scan of `~/Library` must NOT offer its own `Caches`: that is
        // the too-broad root, now that node 0 is recognised as the boundary.
        let pip = |t: &mut Tree, i: u32| {
            add(t, i, "http-v2", true, MIN_BYTES);
        };
        let (scan, node) = rooted("/Users/me/Library", "Caches", pip);
        assert_eq!(kind(&scan, node), None, "~/Library/Caches stays too broad");

        // Control: the same scan one level deeper still finds the tool cache.
        let (scan, node) = rooted("/Users/me/Library", "Caches/pip", pip);
        assert_eq!(kind(&scan, node), Some(Kind::ToolCache("pip")));
    }

    #[test]
    fn a_service_folder_is_not_a_home() {
        // B5: the no-`Users` fallback used to accept any absolute root, so
        // `/Library/Caches`, `/Library` and `/private/tmp/notahome` were read as
        // homes. `CleanupGuard` refuses all of them as "Outside your home
        // folder", i.e. recognition offered what authorization refuses (module
        // doc). `/` is the same trap: it is only a home when a `Users/<name>`
        // component follows it.
        let pip = |t: &mut Tree, i: u32| {
            add(t, i, "http-v2", true, MIN_BYTES);
        };
        for (root, rel) in [
            ("/Library/Caches", "pip"),
            ("/Library", "Caches/Homebrew"),
            ("/private/tmp/notahome", "Library/Caches/pip"),
            ("/", "Library/Caches/pip"),
            ("/Applications", "Library/Caches/pip"),
            ("/opt/homebrew", "Library/Caches/pip"),
            ("/Users", "Library/Caches/pip"),
            ("/Users/me/Projects", "Library/Caches/pip"),
        ] {
            let marker = if root == "/Library" {
                marker_for("Library/Caches/Homebrew")
            } else {
                pip
            };
            let (scan, node) = rooted(root, rel, marker);
            assert_eq!(kind(&scan, node), None, "scan root {root} is not a home");
            assert!(find(&scan, MIN_BYTES).is_empty(), "scan root {root} must offer nothing");
        }
    }

    #[test]
    fn the_home_anchor_is_the_first_plausible_users_component() {
        // B6, false-accept: `rposition` found the *deepest* `Users`, so
        // `/Users/me/Projects/Users/foo/Library/pnpm/store` had its rule anchored
        // at the fake `Projects/Users/foo` home inside a user's project.
        let (scan, node) = rooted(
            "/Users/me/Projects/Users/foo",
            "Library/pnpm/store",
            marker_for("Library/pnpm/store"),
        );
        assert_eq!(kind(&scan, node), None, "a project is not a second home");
        assert!(find(&scan, MIN_BYTES).is_empty());

        // B6, false-reject: a user literally named `Users` has the home
        // `/Users/Users`. `rposition` alone still finds the right deepest
        // component here, but the *first* plausible one must be considered too;
        // this is the acceptance half of the same rule.
        let (scan, node) = rooted(
            "/Users/Users",
            "Library/Caches/Homebrew",
            marker_for("Library/Caches/Homebrew"),
        );
        assert_eq!(kind(&scan, node), Some(Kind::ToolCache("Homebrew")));

        // B6 via a home under `/Volumes/...`: the old `is_system_location`
        // refused the whole `Volumes` prefix, so an external-drive home could
        // never be recognised.
        let (scan, node) = rooted(
            "/Volumes/Ext/Users/me",
            "Library/pnpm/store",
            marker_for("Library/pnpm/store"),
        );
        assert_eq!(kind(&scan, node), Some(Kind::ToolCache("pnpm")));

        // A `Users` directory with no user component below it is not a home:
        // `/Users/Library/pnpm/store` and `/Users/me/Projects/Library/Caches/pip`
        // must stay refused (the anchor is `Users/<name>`, not `Users`).
        for (root, rel) in [
            ("/Users", "Library/pnpm/store"),
            ("/Users/me/Projects", "Library/Caches/pip"),
        ] {
            let (scan, node) = rooted(root, rel, marker_for(rel));
            assert_eq!(kind(&scan, node), None, "scan root {root} is not a home");
        }
    }

    #[test]
    fn a_table_row_carries_its_tool_but_keeps_the_published_category() {
        // B7: the identity table exists to say *which* tool a cache belongs to,
        // and `tool_cache` used to throw that away with `.map(|_| Kind::ToolCaches)`.
        // The tool name is now carried on the candidate.
        let (scan, node) = rooted("/Users/me", ".cargo/registry", marker_for(".cargo/registry"));
        assert_eq!(kind(&scan, node), Some(Kind::ToolCache("Cargo")));
        assert_eq!(kind(&scan, node).and_then(Kind::tool), Some("Cargo"));

        // HARD CONSTRAINT: `id()` is the published CLI/JSON category and must stay
        // exactly `tool_caches` for every row. `description()` stays the generic
        // panel label because Swift `Cleanup` shows it verbatim.
        for rule in CACHE_RULES {
            let kind = Kind::ToolCache(rule.name);
            assert_eq!(kind.id(), "tool_caches", "row {} must keep the wire value", rule.rel);
            assert_eq!(kind.tool(), Some(rule.name));
            assert_eq!(kind.description(), Kind::ToolCaches.description());
        }
        // Shape rules have no tool identity and keep reporting `None`.
        for kind in [Kind::ToolCaches, Kind::NodeModules, Kind::BunCache] {
            assert_eq!(kind.tool(), None);
        }
        assert_eq!(Kind::ToolCache("uv").id(), Kind::ToolCaches.id());
    }

    #[test]
    fn a_folder_scan_finds_the_caches_inside_it() {
        // The panel lets the user scan ONE folder, and the table's rules are
        // home-relative — so a scan rooted below the home had no home ancestor to
        // measure from and found nothing. Measured before this: scanning
        // `~/Library/Caches` offered no pip and no Homebrew, and scanning
        // `~/Library/pnpm` offered no store, even though a home scan offered all
        // three. The user picked that folder precisely to clean what is in it.
        //
        // A scan root's own name is an absolute path, so the real location can
        // still be reconstructed: the node's path must end with the rule, and the
        // components before it must spell a home directory. `/Applications` is
        // not a home, which is what keeps a folder scan outside the home from
        // offering the user's caches.
        let pip = |t: &mut Tree, i: u32| {
            add(t, i, "http-v2", true, MIN_BYTES);
        };

        // Scanning the cache's own parent, and the cache itself.
        for (root, rel) in [("/Users/me/Library/Caches", "pip"),
                            ("/Users/me/Library", "Caches/pip")] {
            let (scan, node) = rooted(root, rel, pip);
            assert_eq!(kind(&scan, node), Some(Kind::ToolCache("pip")), "scan root {root}");
            assert_eq!(
                find(&scan, MIN_BYTES),
                vec![Candidate { node, kind: Kind::ToolCache("pip") }],
                "scan root {root} must offer the cache inside it"
            );
        }
        // The same for a nested store under a folder scan.
        let (scan, node) = rooted("/Users/me/Library/pnpm", "store", |t, i| {
            let version = add(t, i, "v11", true, MIN_BYTES);
            add(t, version, "files", true, MIN_BYTES);
            add(t, version, "index.db", false, 0);
        });
        assert_eq!(kind(&scan, node), Some(Kind::ToolCache("pnpm")));
        assert_eq!(find(&scan, MIN_BYTES).len(), 1);

        // A folder scan OUTSIDE the home finds nothing: the location test is
        // what stops an Applications or Homebrew scan from offering the user's
        // caches.
        for root in ["/Applications", "/opt/homebrew", "/Users"] {
            let (scan, node) = rooted(root, "Library/Caches/pip", pip);
            let _ = node;
            assert_eq!(find(&scan, MIN_BYTES), Vec::new(), "scan root {root} is not a home");
        }
        // And a *project* folder whose path merely ends like a cache stays out:
        // what precedes the rule must be a home, not arbitrary nesting.
        let (scan, node) = rooted("/Users/me/Projects", "Library/Caches/pip", pip);
        assert_eq!(kind(&scan, node), None, "a project is not a home");
    }

    #[test]
    fn preserves_panel_traversal_threshold_and_partial_candidates() {
        let mut scan = Tree::default();
        add(
            &mut scan,
            NO_PARENT,
            "/root/node_modules",
            true,
            MIN_BYTES * 10,
        );
        let trash = add(&mut scan, 0, ".Trash", true, MIN_BYTES * 2);
        add(&mut scan, 0, ".cache", false, MIN_BYTES * 2);
        let matched = add(&mut scan, 0, "node_modules", true, MIN_BYTES);
        let small = add(&mut scan, 0, ".gradle", true, MIN_BYTES - 1);
        add(&mut scan, trash, "node_modules", true, MIN_BYTES * 2);
        add(&mut scan, matched, ".venv", true, MIN_BYTES);
        // Deliberately inconsistent size catches descent under a small match.
        add(&mut scan, small, ".venv", true, MIN_BYTES);
        let mut scan = link(scan);
        scan.complete[matched as usize] = false;
        assert_eq!(
            find(&scan, MIN_BYTES),
            vec![Candidate {
                node: matched,
                kind: Kind::NodeModules
            }]
        );
    }


    #[test]
    fn size_ties_are_lexical_independent_of_discovery_order() {
        for names in [["z", "a"], ["a", "z"]] {
            let mut scan = Tree::default();
            add(&mut scan, NO_PARENT, "/root", true, 0);
            let first = add(&mut scan, 0, names[0], true, MIN_BYTES);
            let second = add(&mut scan, 0, names[1], true, MIN_BYTES);
            let large = add(&mut scan, 0, ".npm", true, MIN_BYTES * 2);
            let first_cache = add(&mut scan, first, ".cache", true, MIN_BYTES);
            let second_cache = add(&mut scan, second, ".cache", true, MIN_BYTES);
            let scan = link(scan);
            let expected = if names[0] == "a" {
                vec![large, first_cache, second_cache]
            } else {
                vec![large, second_cache, first_cache]
            };
            assert_eq!(
                find(&scan, MIN_BYTES)
                    .iter()
                    .map(|c| c.node)
                    .collect::<Vec<_>>(),
                expected
            );
        }
    }
}




