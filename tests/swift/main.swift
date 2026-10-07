// Guard unit tests (plan T8): the trust boundary gets a regression net.
// Build (from repo root, same flags as the Makefile):
//   swiftc tests/swift/main.swift app/CleanupGuard.swift \
//       -import-objc-header app/bz.h -swift-version 6 \
//       -default-isolation MainActor -target arm64-apple-macos14.0 \
//       -L target/release -lappletree -o .build/guard-tests
// Prints PASS/FAIL lines and exits nonzero on any failure.
//
// Fixture strategy: NSHomeDirectory() on macOS comes from Directory Services
// and ignores a changed HOME, so the guard's rules always use the real home.
// Tests therefore place scratch fixtures inside the workspace
// (~/Documents/...), which is itself inside the guard's protected Documents
// root — the T6 smoke pattern. Rule checks that need no fixtures are probed
// read-only against the real home; blockReason never writes.

import Foundation

var failed = 0
var passed = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        passed += 1
        print("PASS \(name)")
    } else {
        failed += 1
        print("FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }
}

let home = CleanupGuard.home
func path(_ rel: String) -> String { home + "/" + rel }
let fm = FileManager.default
// Fixtures sit next to the test binary in .build/ — inside the repo, so under
// the guard's protected Documents root (the carve-out tests need that), and
// derived from the binary path so no machine-specific location is hardcoded.
let ws = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .appendingPathComponent("guard-test")
    .path

// Scratch fixtures, recreated each run. Cleaned up explicitly before exit()
// below — exit() skips defer blocks.
try? fm.removeItem(atPath: ws)
try? fm.createDirectory(atPath: ws, withIntermediateDirectories: true)
try? fm.createDirectory(atPath: ws + "/node_modules/react", withIntermediateDirectories: true)
try? "x".write(toFile: ws + "/node_modules/react/index.js", atomically: true, encoding: .utf8)

// --- S1: protected and neverClean (read-only prefix checks, real home) ------
check("Documents blocked", CleanupGuard.blockReason(path: path("Documents")) != nil)
check("Documents subfolder blocked", CleanupGuard.blockReason(path: path("Documents/notes")) != nil)
check("Desktop blocked", CleanupGuard.blockReason(path: path("Desktop")) != nil)
check("Pictures blocked", CleanupGuard.blockReason(path: path("Pictures")) != nil)
check("Movies blocked", CleanupGuard.blockReason(path: path("Movies")) != nil)
check("Music blocked", CleanupGuard.blockReason(path: path("Music")) != nil)
check("Library/Mail blocked", CleanupGuard.blockReason(path: path("Library/Mail")) != nil)
check("Library/Messages blocked", CleanupGuard.blockReason(path: path("Library/Messages")) != nil)
check("Library/Keychains blocked", CleanupGuard.blockReason(path: path("Library/Keychains")) != nil)
check("Library/Mobile Documents blocked", CleanupGuard.blockReason(path: path("Library/Mobile Documents")) != nil)
check("Library/LaunchAgents blocked", CleanupGuard.blockReason(path: path("Library/LaunchAgents")) != nil)
check("Library/LaunchAgents child blocked", CleanupGuard.blockReason(path: path("Library/LaunchAgents/com.foo.plist")) != nil)
// tooBroad blocks the folder itself; naming a specific subfolder (depth >= 2)
// is the mechanism that keeps whole app-data folders out of a sweep.
check("Library/Application Support root blocked", CleanupGuard.blockReason(path: path("Library/Application Support")) != nil)
check("named subfolder of Application Support passes the breadth rule",
      CleanupGuard.blockReason(path: path("Library/Application Support/App/Cache")) == nil,
      CleanupGuard.blockReason(path: path("Library/Application Support/App/Cache")) ?? "")
check(".ssh blocked", CleanupGuard.blockReason(path: path(".ssh")) != nil)
check(".gnupg blocked", CleanupGuard.blockReason(path: path(".gnupg")) != nil)
check(".Trash blocked", CleanupGuard.blockReason(path: path(".Trash")) != nil)

// Rebuildable carve-out inside protected folders (workspace = Documents tree).
check("node_modules allowed inside Documents", CleanupGuard.blockReason(path: ws + "/node_modules") == nil,
      CleanupGuard.blockReason(path: ws + "/node_modules") ?? "")
// A folder *below* a rebuildable one is not itself rebuildable: the guard
// allows the named build directory wholesale, never a path inside it that a
// caller made up, so a nested lookup stays blocked by the Documents rule.
check("nested inside node_modules not itself carve-out eligible",
      CleanupGuard.blockReason(path: ws + "/node_modules/react") == "In ~/Documents, which AppleTree never cleans",
      CleanupGuard.blockReason(path: ws + "/node_modules/react") ?? "nil")
check("plain sibling of node_modules blocked", CleanupGuard.blockReason(path: ws + "/plain") == "In ~/Documents, which AppleTree never cleans",
      CleanupGuard.blockReason(path: ws + "/plain") ?? "nil")

// --- S1: too broad -----------------------------------------------------------
check("Library root blocked", CleanupGuard.blockReason(path: path("Library")) != nil)
check("Library/Caches blocked", CleanupGuard.blockReason(path: path("Library/Caches")) != nil)
check("Downloads blocked", CleanupGuard.blockReason(path: path("Downloads")) != nil)
check("home root blocked", CleanupGuard.blockReason(path: home) != nil)
check("top-level folder blocked", CleanupGuard.blockReason(path: path("Desktop2")) != nil)

// Dot-folders at the top level are allowed (they don't hold live app data).
try? fm.createDirectory(atPath: path(".guard-test-cache"), withIntermediateDirectories: true)
check("top-level dot-folder allowed", CleanupGuard.blockReason(path: path(".guard-test-cache")) == nil,
      CleanupGuard.blockReason(path: path(".guard-test-cache")) ?? "")

// --- Outside home ------------------------------------------------------------
check("outside home blocked", CleanupGuard.blockReason(path: "/tmp") == "Outside your home folder",
      CleanupGuard.blockReason(path: "/tmp") ?? "nil")
check("/var blocked", CleanupGuard.blockReason(path: "/var/log") != nil)
// A path with .. must not escape the rules via string tricks.
check(".. traversal judged safely", CleanupGuard.blockReason(path: "/tmp/../Users/x") != nil)

// --- Signed app bundles ------------------------------------------------------
//
// A bundle is one sealed unit: removing a folder inside it invalidates the
// app's signature (verified with `codesign --verify --strict` on real bundles,
// which then reports "a sealed resource is missing or invalid"). A `.app` in
// /Applications used to be refused only for being outside $HOME, which named
// the wrong cause — and, for the many bundles inside the home folder, was no
// protection at all.

// A real bundle under $HOME: the guard permits everything there, so this is
// the case where a nomination would actually be acted on.
let bundleRoot = home + "/Library/Application Support/com.raycast.macos/Updates/2.6.3/Raycast.app"
try? fm.createDirectory(atPath: bundleRoot + "/Contents", withIntermediateDirectories: true)
try? "plist".write(toFile: bundleRoot + "/Contents/Info.plist", atomically: true, encoding: .utf8)
try? fm.createDirectory(atPath: bundleRoot + "/Contents/Resources/api/node_modules",
                        withIntermediateDirectories: true)
check("a bundle inside the home folder is refused",
      CleanupGuard.blockReason(path: bundleRoot + "/Contents/Resources/api/node_modules")
        == "Inside a signed app bundle",
      CleanupGuard.blockReason(path: bundleRoot + "/Contents/Resources/api/node_modules") ?? "nil")
// The same reason, rather than the misleading home rule, once outside it.
let outsideBundle = fm.temporaryDirectory.path + "/guard-bundle-\(ProcessInfo.processInfo.processIdentifier).app"
try? fm.createDirectory(atPath: outsideBundle + "/Contents", withIntermediateDirectories: true)
try? "plist".write(toFile: outsideBundle + "/Contents/Info.plist", atomically: true, encoding: .utf8)
let outsideNM = outsideBundle + "/Contents/Resources/node_modules"
try? fm.createDirectory(atPath: outsideNM, withIntermediateDirectories: true)
check("a bundle outside the home names the bundle, not the home rule",
      CleanupGuard.blockReason(path: outsideNM) == "Inside a signed app bundle",
      CleanupGuard.blockReason(path: outsideNM) ?? "nil")
// A folder that merely ends in `.app` is not a bundle: macOS names containers
// and app-support folders that way, and their contents stay permitted.
try? fm.createDirectory(atPath: path("Library/Application Support/com.example.app/Caches"),
                        withIntermediateDirectories: true)
check("a folder merely named *.app is not a bundle",
      CleanupGuard.blockReason(path: path("Library/Application Support/com.example.app/Caches")) == nil,
      CleanupGuard.blockReason(path: path("Library/Application Support/com.example.app/Caches")) ?? "nil")
// A normal project stays permitted.
check("a project outside any bundle is still permitted",
      CleanupGuard.blockReason(path: ws + "/node_modules") == nil,
      CleanupGuard.blockReason(path: ws + "/node_modules") ?? "nil")
try? fm.removeItem(atPath: bundleRoot)
try? fm.removeItem(atPath: home + "/Library/Application Support/com.example.app")
try? fm.removeItem(atPath: outsideBundle)

// --- Guard categories, pinned by message --------------------------------------
check("managed by macOS", CleanupGuard.blockReason(path: path("Library/Containers/com.apple.Safari")) == "Managed by macOS",
      CleanupGuard.blockReason(path: path("Library/Containers/com.apple.Safari")) ?? "nil")
check("managed caches by macOS", CleanupGuard.blockReason(path: path("Library/Caches/com.apple.Safari")) == "Managed by macOS")

// The .git rule fires for a candidate outside protected folders. Scratch root
// sits directly under home: ~/guard-test-scratch/repo with a .git inside.
let scratch = home + "/guard-test-scratch/repo"
try? fm.removeItem(atPath: home + "/guard-test-scratch")
try? fm.createDirectory(atPath: scratch + "/.git", withIntermediateDirectories: true)
check("git repository blocked", CleanupGuard.blockReason(path: scratch) == "A git repository",
      CleanupGuard.blockReason(path: scratch) ?? "nil")
// A nested .git FILE (worktree pointer) also blocks.
try? fm.removeItem(atPath: scratch + "/.git")
try? "gitdir: /somewhere".write(toFile: scratch + "/.git", atomically: true, encoding: .utf8)
check("worktree .git file blocks", CleanupGuard.blockReason(path: scratch) == "A git repository")
// Without any .git the folder is fair game.
try? fm.removeItem(atPath: scratch + "/.git")
check("no .git means allowed", CleanupGuard.blockReason(path: scratch) == nil,
      CleanupGuard.blockReason(path: scratch) ?? "")

// --- S3: symlink resolution -----------------------------------------------------
// A symlink named innocently must be judged by where it lands. The link lives
// in the workspace; the targets are real home folders, probed read-only.
let link = ws + "/innocent-name"
try? fm.createSymbolicLink(atPath: link, withDestinationPath: path("Library/LaunchAgents"))
check("symlink to LaunchAgents judged by target",
      CleanupGuard.blockReason(path: link) == "Too broad: other apps keep live data here",
      CleanupGuard.blockReason(path: link) ?? "nil")
try? fm.removeItem(atPath: link)
try? fm.createSymbolicLink(atPath: link, withDestinationPath: path("Library/Mail"))
check("symlink to Mail judged by target",
      CleanupGuard.blockReason(path: link)?.hasPrefix("In ~/Library/Mail") == true,
      CleanupGuard.blockReason(path: link) ?? "nil")
try? fm.removeItem(atPath: link)
// Link to an allowed rebuildable target stays allowed (relative target).
try? fm.createSymbolicLink(atPath: link, withDestinationPath: "node_modules")
check("symlink to node_modules stays allowed", CleanupGuard.blockReason(path: link) == nil,
      CleanupGuard.blockReason(path: link) ?? "")
try? fm.removeItem(atPath: link)
// Relative link: the target is resolved against the link's own directory
// (ws), so five levels up reach ~/Documents — a protected root. The judgment
// must follow the resolved landing spot, not the link's innocent name.
try? fm.createSymbolicLink(atPath: link, withDestinationPath: "../../../../../Documents")
check("relative symlink resolves then judged", CleanupGuard.blockReason(path: link) == "In ~/Documents, which AppleTree never cleans",
      CleanupGuard.blockReason(path: link) ?? "nil")
try? fm.removeItem(atPath: link)

// --- S6: command gate ----------------------------------------------------------
check("unknown command rejected", CleanupGuard.blockReason(command: "rm -rf /") != nil)
check("arbitrary binary rejected", CleanupGuard.blockReason(command: "somecleanup-tool run") != nil)
check("empty command rejected", CleanupGuard.blockReason(command: "   ") != nil)
check("semicolon injection rejected", CleanupGuard.blockReason(command: "ollama rm x; rm -rf /") != nil)
check("pipe rejected", CleanupGuard.blockReason(command: "ollama rm x | sh") != nil)
check("ampersand rejected", CleanupGuard.blockReason(command: "ollama rm x & sh") != nil)
check("redirect rejected", CleanupGuard.blockReason(command: "ollama rm x > /tmp/f") != nil)
check("backtick rejected", CleanupGuard.blockReason(command: "ollama rm `x`") != nil)
check("dollar rejected", CleanupGuard.blockReason(command: "ollama rm $HOME") != nil)
check("glob rejected", CleanupGuard.blockReason(command: "ollama rm *") != nil)
check("backslash rejected", CleanupGuard.blockReason(command: "ollama rm x\\y") != nil)
check("newline rejected", CleanupGuard.blockReason(command: "ollama rm x\ny") != nil)
check("extra flag rejected", CleanupGuard.blockReason(command: "ollama rm x --force") != nil)
check("whitespace-wrapped allowlisted passes", CleanupGuard.blockReason(command: "  brew cleanup  ") == nil,
      CleanupGuard.blockReason(command: "  brew cleanup  ") ?? "")

// Exact-match forms from the FFI-fed table must pass.
// The table comes from bz_cleanup_allowlist (Rust); if the FFI returns an
// empty table the guard fails closed, so assert non-empty first.
check("FFI allowlist non-empty (fail-closed guard)", !CleanupGuard.allowlistCommands.isEmpty)
for cmd in CleanupGuard.allowlistCommands {
    check("allowlisted command passes: \(cmd)", CleanupGuard.blockReason(command: cmd) == nil,
          CleanupGuard.blockReason(command: cmd) ?? "")
}
// One-argument forms accept exactly one token.
check("one-arg form passes", CleanupGuard.blockReason(command: "ollama rm llama3") == nil,
      CleanupGuard.blockReason(command: "ollama rm llama3") ?? "")
check("one-arg form with two args rejected", CleanupGuard.blockReason(command: "ollama rm llama3 extra") != nil)
if CleanupGuard.oneArgumentCommands.contains("xcrun simctl erase") {
    check("simctl erase one-arg passes", CleanupGuard.blockReason(command: "xcrun simctl erase iPhone") == nil)
}

// --- a single token must be DATA, not a flag or the tools' `all` keyword --------
//
// "One space-free token" was never enough. The token is handed to `zsh -c` and
// interpreted by the tool, and Apple's own CLIs document meanings one token
// reaches: `xcrun simctl help erase` says "simctl erase <device> | all" /
// "Specifying all will erase all existing devices", and `xcrun simctl help
// runtime` documents delete (…|--unusable|--outdated) plus an `all` alias. So
// `simctl erase all` erases every simulator on the machine while the plan card
// describes one device. A leading `-` is read as a flag, not an identifier.
for cmd in ["xcrun simctl erase all",
            "xcrun simctl runtime delete --unusable",
            "xcrun simctl runtime delete --outdated",
            "xcrun simctl erase --all",
            "ollama rm --all"] {
    check("destructive single token rejected: \(cmd)", CleanupGuard.blockReason(command: cmd) != nil,
          CleanupGuard.blockReason(command: cmd) ?? "allowed!")
}
// Real identifiers are neither a flag nor `all`, so they must still pass.
for cmd in ["ollama rm llama3",
            "ollama rm gpt-oss:20b",
            "xcrun simctl erase 1234ABCD-1234-1234-1234-123456789ABC",
            "xcrun simctl runtime delete com.apple.CoreSimulator.SimRuntime.iOS-27-0"] {
    check("real identifier still allowed: \(cmd)", CleanupGuard.blockReason(command: cmd) == nil,
          CleanupGuard.blockReason(command: cmd) ?? "")
}

// --- shell glob/brace forms are metacharacters, not argument separation ---------
//
// `zsh -c` expands these before the tool sees the argument, so "no spaces" was
// never a glob rule. Each of these reached the command line as a token.
for cmd in ["ollama rm {x,y}", "ollama rm ?", "ollama rm [ab]", "xcrun simctl erase {a,b}"] {
    check("glob form rejected: \(cmd)", CleanupGuard.blockReason(command: cmd) != nil,
          CleanupGuard.blockReason(command: cmd) ?? "allowed!")
}

// --- recognition must never advertise what authorization refuses -----------------
//
// Rust's `cleanup::kind()` offers candidates; `blockReason(path:)` authorizes.
// A folder offered but refused shows the user a Move that fails with "Too
// broad". These two broad roots are refused by design and must never appear as
// candidates — the Rust side narrows `kind()` to match (see the
// `home_level_cache_roots_are_not_candidates` test in src/cleanup.rs).
for broad in [home + "/Library/Caches", home + "/.cache"] {
    check("broad cache root is refused: \(broad)", CleanupGuard.blockReason(path: broad) != nil,
          CleanupGuard.blockReason(path: broad) ?? "allowed!")
}
// Their named subfolders are one owner's data and stay permitted.
check("a named cache subfolder is permitted",
      CleanupGuard.blockReason(path: home + "/Library/Caches/pip") == nil,
      CleanupGuard.blockReason(path: home + "/Library/Caches/pip") ?? "")

// --- recentlyUsed with injected windows ------------------------------------------
// `within` is the date-injection point: cutoff = now - within.
let nm = ws + "/node_modules"
check("recentlyUsed fresh node_modules", CleanupGuard.recentlyUsed(nm))
check("recentlyUsed stale with negative window", !CleanupGuard.recentlyUsed(nm, within: -100))
check("recentlyUsed with huge window", CleanupGuard.recentlyUsed(nm, within: 365 * 86400))
// Non-rebuildable names never count as recently used.
try? "x".write(toFile: ws + "/notes.txt", atomically: true, encoding: .utf8)
check("non-rebuildable not recently used", !CleanupGuard.recentlyUsed(ws + "/notes.txt"))

// --- runningOwner mapping ---------------------------------------------------------
// With no matching path the owner is nil; assert no unrelated path leaks one.
if let owner = CleanupGuard.runningOwner(of: ["/definitely/not/an/app/bundle.zzz"]) {
    check("runningOwner nil for unrelated path", false, "leaked owner: \(owner)")
} else {
    check("runningOwner nil for unrelated path", true)
}

// Scratch-tree and home-dir fixtures are removed explicitly before exit()
// below (exit skips defer blocks). Nothing test-made survives a full run.
try? fm.removeItem(atPath: ws)
try? fm.removeItem(atPath: path(".guard-test-cache"))
try? fm.removeItem(atPath: home + "/guard-test-scratch")
print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
