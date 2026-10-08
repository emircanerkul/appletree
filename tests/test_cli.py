"""Black-box contract tests; only write/delete isolated temporary fixtures."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

BIN = Path(os.environ.get("APPLETREE_BIN", Path(__file__).resolve().parents[1] / "target/release/appletree"))


class AgentCLITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="appletree-api-")
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        self.env = dict(os.environ, HOME=str(self.home))

    def tearDown(self):
        self.temp.cleanup()

    def run_cli(self, *args, code=0):
        result = subprocess.run([str(BIN), *args], env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, code, result.stderr + result.stdout)
        data = json.loads(result.stdout)
        self.assertEqual(data["schema_version"], 1)
        return data

    def file(self, relative, size=8192):
        p = self.home / relative
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"x" * size)
        return p

    def wins(self, *args):
        return self.run_cli("quick-wins", "--min-bytes", "1", *args)["report"]

    def test_sizes_hardlinks_and_no_mutations(self):
        data = self.file("file")
        os.link(data, self.home / "second-name")
        before = data.stat()
        result = self.run_cli("scan", "--root", str(self.home), "--min-bytes", "1")
        self.assertEqual(result["summary"]["logical_bytes"], 8192)
        self.assertEqual(result["summary"]["file_count"], 2)
        self.assertEqual(result["summary"]["allocated_bytes"], before.st_blocks * 512)
        self.assertTrue(result["read_only"])
        self.assertEqual(data.stat().st_mtime_ns, before.st_mtime_ns)
        self.assertEqual(data.read_bytes(), b"x" * 8192)

    def test_no_symlink_traversal(self):
        outside = self.root / "outside"
        (outside / "node_modules").mkdir(parents=True)
        (outside / "package.json").write_text("{}")
        (outside / "node_modules/file").write_bytes(b"x" * 8192)
        (self.home / "shortcut").symlink_to(outside, target_is_directory=True)
        result = self.run_cli("scan", "--min-bytes", "0")
        self.assertEqual(result["summary"]["file_count"], 1)
        self.assertEqual(self.wins()["candidates"], [])

    def test_candidates_use_the_existing_panel_rules(self):
        for path in [
            ".gradle/gradle.properties", ".npm/npmrc", ".cache/unknown/content",
            "no-manifest/node_modules/file", "no-manifest/.venv/file",
            "python/venv/pyvenv.cfg", "rust/Cargo.toml", "rust/target/file",
            "web/package.json", "web/.next/file", "Library/Developer/Xcode/DerivedData/file",
            "Library/Caches/com.apple.example/file", "CoreSimulator/Caches/file",
            "iOS DeviceSupport/file", "macOS DeviceSupport/file", "watchOS DeviceSupport/file",
            ".bun/install/cache/file",
        ]:
            self.file(path)
        candidates = self.wins("--limit", "100")["candidates"]
        kinds = {Path(c["path"]).relative_to(self.home).as_posix(): c["category"] for c in candidates}
        self.assertEqual(kinds, {
            ".gradle": "tool_caches", ".npm": "tool_caches",
            "no-manifest/node_modules": "node_modules", "no-manifest/.venv": "python_environment",
            "python/venv": "python_environment", "rust/target": "rust_build", "web/.next": "next_build",
            "Library/Developer/Xcode/DerivedData": "xcode_derived_data",
            "CoreSimulator/Caches": "app_caches", "iOS DeviceSupport": "device_support",
            "macOS DeviceSupport": "device_support", "watchOS DeviceSupport": "device_support",
            ".bun/install/cache": "bun_cache",
        })
        # The home-level broad cache roots are deliberately NOT candidates: the
        # guard refuses `~/.cache` and `~/Library/Caches` as "Too broad", so
        # offering them would advertise a Move that always fails. Recognition
        # must not nominate what authorization refuses. A *named* subfolder is
        # still fair game, which is why the rows above survive.
        self.assertNotIn(".cache", kinds)
        self.assertNotIn("Library/Caches", kinds)
        self.assertTrue(all(c["requires_review"] for c in candidates))
        self.assertTrue(all(c["reason"] for c in candidates))
        self.assertEqual(self.run_cli("quick-wins")["options"]["min_bytes"], 50_000_000)
        self.assertEqual(self.run_cli("quick-wins")["report"]["candidates"], [])

    def test_a_folder_scan_finds_the_caches_inside_it(self):
        # The panel lets the user scan ONE folder, and the detection table's
        # rules are home-relative. Before this a scan rooted below the home had
        # no home ancestor to measure from, so it found nothing: measured,
        # scanning ~/Library/Caches offered neither pip nor Homebrew, and
        # scanning ~/Library/pnpm offered no store — even though a home scan
        # offered all three. The user picked that folder to clean what is in it.
        self.file("Library/Caches/Homebrew/api/formula.json")
        self.file("Library/Caches/pip/http-v2/x")
        self.file("Library/pnpm/store/v11/files/x")
        self.file("Library/pnpm/store/v11/index.db")

        # Scanning the cache's own parent finds it.
        caches = self.run_cli("quick-wins", "--root", str(self.home / "Library/Caches"),
                              "--min-bytes", "1")["report"]["candidates"]
        self.assertEqual([Path(c["path"]).relative_to(self.home).as_posix() for c in caches],
                         ["Library/Caches/Homebrew", "Library/Caches/pip"])
        # Scanning the store's parent finds the store.
        pnpm = self.run_cli("quick-wins", "--root", str(self.home / "Library/pnpm"),
                            "--min-bytes", "1")["report"]["candidates"]
        self.assertEqual([c["category"] for c in pnpm], ["tool_caches"])
        self.assertTrue(pnpm[0]["path"].endswith("Library/pnpm/store"))
        # Scanning the home still finds both.
        home = self.wins("--limit", "100")["candidates"]
        paths = {Path(c["path"]).relative_to(self.home).as_posix() for c in home}
        self.assertIn("Library/Caches/Homebrew", paths)
        self.assertIn("Library/pnpm/store", paths)

    def test_a_folder_scan_outside_the_home_finds_no_caches(self):
        # The other half: a folder scan outside the user's home must not offer
        # the user's *tool* caches, and a rule rooted in a system location must
        # not fire there — the guard refuses those paths as outside the home, and
        # recognition must not offer what authorization refuses.
        #
        # Scoped to `tool_caches`, the table's category: a `Caches` directory
        # under a non-home `Library` is a separate, pre-existing rule for one
        # app's own data and is expected to fire here.
        outside = self.root / "Applications"
        inner = outside / "Foo" / "Library" / "Caches" / "Homebrew" / "api"
        inner.mkdir(parents=True)
        (inner / "formula.json").write_text("{}")
        report = self.run_cli("quick-wins", "--root", str(outside), "--min-bytes", "1")["report"]
        self.assertEqual([c["path"] for c in report["candidates"] if c["category"] == "tool_caches"], [])
        # Nothing it reports can be outside the folder that was scanned.
        self.assertTrue(all(c["path"].startswith(str(outside)) for c in report["candidates"]))

    def test_tool_cache_locations_are_recognised_by_structure(self):
        # The §5 identity locations: a cache is found by *where it is* plus what
        # the tool puts there, not by its folder name. Before this the pnpm store
        # and the Homebrew cache were unreachable — measured 4.0 GB and 689 MB on
        # a real machine, both present, neither nominated, because `store` and
        # `Homebrew` were not names the engine knew.
        #
        # Each path below is the tool's fixed home-relative location, carrying
        # the marker measured on this machine.
        self.file(".npm/npmrc")
        self.file(".cache/uv/CACHEDIR.TAG")
        self.file(".cargo/registry/CACHEDIR.TAG")
        self.file(".cargo/git/db/zed-a70e2ad075855582/FETCH_HEAD")
        self.file("Library/pnpm/store/v11/files/x")
        self.file("Library/pnpm/store/v11/index.db")
        self.file("Library/Caches/pip/http-v2/x")
        self.file("Library/Caches/Homebrew/api/formula.json")
        self.file("Library/Caches/CocoaPods/Pods/x")
        self.file("Library/Caches/org.swift.swiftpm/manifests/x")

        candidates = self.wins("--limit", "100")["candidates"]
        kinds = {Path(c["path"]).relative_to(self.home).as_posix(): c["category"] for c in candidates}
        # `.npm` stays its own, older shape rule.
        expected = {
            ".npm": "tool_caches",
            ".cache/uv": "tool_caches",
            ".cargo/registry": "tool_caches",
            ".cargo/git/db": "tool_caches",
            "Library/pnpm/store": "tool_caches",
            "Library/Caches/pip": "tool_caches",
            "Library/Caches/Homebrew": "tool_caches",
            "Library/Caches/CocoaPods": "tool_caches",
            "Library/Caches/org.swift.swiftpm": "tool_caches",
        }
        self.assertEqual(kinds, expected)
        self.assertTrue(all(c["requires_review"] for c in candidates))

        # The identity table names the tool, so a `tool_caches` row says *which*
        # tool it is rather than only its class. This is what makes the
        # "a new tool is one row" claim true in the *output*, not just in the
        # matcher: adding a row is observable without touching `category`.
        tools = {Path(c["path"]).relative_to(self.home).as_posix(): c["tool"]
                 for c in candidates if c["category"] == "tool_caches"}
        self.assertEqual(tools, {
            ".npm": None,               # shape rule, no tool identity
            ".cache/uv": "uv",
            ".cargo/registry": "Cargo",
            ".cargo/git/db": "Cargo",
            "Library/pnpm/store": "pnpm",
            "Library/Caches/pip": "pip",
            "Library/Caches/Homebrew": "Homebrew",
            "Library/Caches/CocoaPods": "CocoaPods",
            "Library/Caches/org.swift.swiftpm": "SwiftPM",
        })

        # The two npm locations are *not* separate rows, and that is correct
        # rather than a gap: `find` never descends into an already-recognised
        # folder and `.npm` is recognised by shape, so a row for `_cacache` or
        # `_npx` could never be consulted. The whole `.npm` tree is the candidate.

    def test_a_folder_that_resembles_a_cache_is_not_proposed(self):
        # The negative half of acceptance criterion 2, through the public CLI.
        # A folder that merely *looks* like a cache must not be offered: the
        # rule's two halves are the tool's fixed location AND its structure, so
        # neither the name alone nor a marker alone is enough.
        #
        # Each fixture carries the real rows' markers, so only the location can
        # refuse it — which is exactly the property under test.
        markers = [
            "CACHEDIR.TAG", "api", "v11/files", "v11/index.db", "index-v5",
            "content-v2", "http-v2", "Pods", "manifests",
        ]
        for stem in ["Projects/foo/store", "tmp/Homebrew", "Library/Caches/placeholder",
                     "projects/Library/pnpm/store", "Library/pnpm/store-old",
                     ".cache/puppeteer"]:
            for marker in markers:
                self.file(f"{stem}/{marker}/x" if "." not in marker.split("/")[-1]
                          else f"{stem}/{marker}")

        # A `tmp` directory merely named `_cacache` is not npm's cache.
        self.file("tmp/_cacache/index-v5/x")
        self.file("tmp/_cacache/content-v2/x")

        self.assertEqual(self.wins("--limit", "100")["candidates"], [])
        for path in ["unrelated/target/file", "unrelated/venv/file", "unrelated/.next/file",
                     "unrelated/Caches/file", "unrelated/DerivedData/file", "unrelated/install/cache/file",
                     "swift/Package.swift", "swift/.build/file", ".Trash/node_modules/file"]:
            self.file(path)
        self.assertEqual(self.wins()["candidates"], [])

    def test_app_bundle_internals_are_not_candidates(self):
        # A bundle is one signed, sealed unit: its node_modules ship with the
        # app and are loaded at runtime, not build output to recreate. Measured
        # on a real /Applications, an unfiltered scan offered exactly two such
        # paths (Bitwarden's app.asar.unpacked/node_modules and Openship's
        # dashboard/node_modules) and the guard refused both; moving either one
        # makes `codesign --verify --strict` report "a sealed resource is
        # missing or invalid". Recognition must not nominate what authorization
        # refuses, so neither may be a candidate.
        self.file("Bitwarden.app/Contents/Info.plist")
        self.file("Bitwarden.app/Contents/Resources/app.asar.unpacked/node_modules/file")
        self.file("Openship.app/Contents/Info.plist")
        self.file("Openship.app/Contents/Resources/dashboard/node_modules/file")
        # A folder that merely ends in `.app` is not a bundle — macOS names
        # containers and app-support folders that way — so what is inside it
        # stays a candidate.
        self.file("com.example.app/node_modules/file")
        candidates = self.wins("--limit", "100")["candidates"]
        paths = {Path(c["path"]).relative_to(self.home).as_posix() for c in candidates}
        self.assertNotIn("Bitwarden.app/Contents/Resources/app.asar.unpacked/node_modules", paths)
        self.assertNotIn("Openship.app/Contents/Resources/dashboard/node_modules", paths)
        self.assertIn("com.example.app/node_modules", paths)

    def test_no_nested_candidates_or_overlapping_totals(self):
        self.file("project/package.json")
        self.file("project/node_modules/inner/package.json")
        self.file("project/node_modules/inner/node_modules/file")
        # A second, independent candidate. `~/.cache` would be the obvious
        # partner but is now correctly not a candidate (too broad for the
        # guard), so `.gradle` supplies the second row this test needs.
        self.file(".gradle/gradle.properties")
        report = self.wins()
        self.assertEqual(len(report["candidates"]), 2)
        self.assertEqual(report["candidate_allocated_bytes"], sum(c["allocated_bytes"] for c in report["candidates"]))
        limited = self.wins("--limit", "1")
        self.assertTrue(limited["truncated"])
        self.assertEqual(limited["candidate_count"], 2)
        self.assertLess(limited["displayed_allocated_bytes"], limited["candidate_allocated_bytes"])
        self.assertIsNone(limited["reclaimable_bytes"])

    def test_json_escapes_untrusted_names(self):
        name = 'space " quote\n$(touch NEVER_EXECUTE)/node_modules'
        self.file(name + "/file")
        report = self.wins()
        self.assertEqual(report["candidates"][0]["path"], str(self.home / name))
        self.assertFalse((self.home / "NEVER_EXECUTE").exists())

    def test_invalid_root_and_arguments_return_json_errors(self):
        for args in [("destroy",), ("scan", "--limit", "0"), ("scan", "--limit", "1001"),
                     ("scan", "--min-bytes", "-1"), ("scan", "--root"), ("scan", "--include-recent"), ("quick-wins", "--include-recent"),
                     ("scan", "--limit", "1", "--limit", "2")]:
            self.assertIn("error", self.run_cli(*args, code=2))
        self.assertIn("error", self.run_cli("scan", "--root", str(self.home / "missing"), code=1))
        file = self.file("a-file")
        self.assertIn("error", self.run_cli("scan", "--root", str(file), code=1))

    def test_partial_scan_reports_errors(self):
        if os.geteuid() == 0:
            self.skipTest("root bypasses fixture permission bits")
        denied = self.home / "denied"
        denied.mkdir()
        denied.chmod(0)
        try:
            report = self.run_cli("scan")
            self.assertFalse(report["coverage"]["complete"])
            self.assertGreater(report["coverage"]["errors"], 0)
            self.run_cli("scan", "--root", str(denied), code=1)
        finally:
            denied.chmod(0o700)

    def test_explicit_root_candidates_do_not_depend_on_home_or_activity(self):
        outside = self.root / "external"
        (outside / "node_modules").mkdir(parents=True)
        (outside / "node_modules/file").write_bytes(b"x" * 8192)
        self.env.pop("HOME")
        report = self.run_cli("quick-wins", "--root", str(outside), "--min-bytes", "1")
        self.assertEqual([c["path"] for c in report["report"]["candidates"]], [str(outside / "node_modules")])

    def test_data_volume_firmlink_home(self):
        alias = Path("/System/Volumes/Data") / self.home.relative_to("/")
        if not alias.exists() or not alias.samefile(self.home):
            self.skipTest("Data volume alias unavailable on this Mac")
        self.file(".npm/_cacache/file")
        report = self.run_cli("quick-wins", "--root", str(alias), "--min-bytes", "1")
        self.assertEqual(len(report["report"]["candidates"]), 1)
        self.assertEqual(report["report"]["candidates"][0]["path"], str(alias / ".npm"))

    def test_data_volume_alias_reaches_the_identity_table(self):
        # B1 through the public CLI. The app's default scan target is the Data
        # volume (`ScanTargets.macintoshHD` is `/System/Volumes/Data`), whose
        # first component is `System`. The location table used to refuse that root
        # outright, so every table row was unreachable there — measured on a real
        # machine, `quick-wins --root /System/Volumes/Data` reported 51 candidates
        # and ZERO table-row hits while the same scan rooted at `$HOME` found
        # pnpm, Homebrew, Cargo and uv. The Data volume's prefix is transparent:
        # the path below it is the volume's real one.
        alias = Path("/System/Volumes/Data") / self.home.relative_to("/")
        if not alias.exists() or not alias.samefile(self.home):
            self.skipTest("Data volume alias unavailable on this Mac")
        self.file(".cache/uv/CACHEDIR.TAG")
        self.file(".cargo/registry/CACHEDIR.TAG")
        self.file("Library/pnpm/store/v11/files/x")
        self.file("Library/pnpm/store/v11/index.db")
        self.file("Library/Caches/pip/http-v2/x")
        self.file("Library/Caches/Homebrew/api/formula.json")

        candidates = self.run_cli("quick-wins", "--root", str(alias),
                                  "--min-bytes", "1", "--limit", "100")["report"]["candidates"]
        kinds = {Path(c["path"]).relative_to(alias).as_posix(): c["category"] for c in candidates}
        self.assertEqual(kinds, {
            ".cache/uv": "tool_caches",
            ".cargo/registry": "tool_caches",
            "Library/pnpm/store": "tool_caches",
            "Library/Caches/pip": "tool_caches",
            "Library/Caches/Homebrew": "tool_caches",
        })

    def test_a_service_folder_is_not_a_home(self):
        # B5 through the public CLI: a root that is not the user's home must not
        # be read as one, or recognition offers what `CleanupGuard` refuses as
        # "Outside your home folder". `/private/tmp/<name>` is the probe from the
        # spec; the fixture is created and removed by tempfile.
        tmp = Path("/private/tmp")
        if not os.access(tmp, os.W_OK):
            self.skipTest("/private/tmp not writable")
        with tempfile.TemporaryDirectory(prefix="appletree-notahome-", dir=tmp) as root:
            root = Path(root)
            (root / "Library/Caches/pip/http-v2").mkdir(parents=True)
            (root / "Library/Caches/pip/http-v2/x").write_bytes(b"x" * 8192)
            report = self.run_cli("quick-wins", "--root", str(root), "--min-bytes", "1")["report"]
            self.assertEqual([c for c in report["candidates"] if c["category"] == "tool_caches"], [])

    def test_explicit_symlink_root_is_resolved(self):
        # `.npm` rather than `.cache`: the home-level `~/.cache` is now
        # deliberately not a candidate (too broad for the guard), so it could
        # not distinguish "the symlink resolved" from "nothing matched".
        self.file(".npm/npmrc")
        link = self.root / "home-link"
        link.symlink_to(self.home, target_is_directory=True)
        report = self.run_cli("quick-wins", "--root", str(link), "--min-bytes", "1")
        self.assertEqual(report["root"], str(self.home))
        self.assertEqual([c["path"] for c in report["report"]["candidates"]], [str(self.home / ".npm")])

    def test_inventory_top_k_is_sorted_and_bounded(self):
        for i in range(200):
            self.file(f"many/{i:03d}", size=8192 * ((i % 5) + 1))
        result = self.run_cli("scan", "--min-bytes", "0", "--limit", "7")
        files = result["report"]["largest_files"]
        expected = sorted((p for p in (self.home / "many").iterdir()),
                          key=lambda p: (-p.stat().st_blocks, str(p)))[:7]
        self.assertEqual([p["path"] for p in files], [str(p) for p in expected])

    def test_scan_root_is_not_itself_a_candidate_like_the_panel(self):
        self.file("project/node_modules/file")
        report = self.wins("--root", str(self.home / "project/node_modules"))
        self.assertEqual(report["candidates"], [])
        self.assertEqual(len(report["inventory"]["largest_files"]), 1)

    def test_markers_retain_the_panels_name_only_semantics(self):
        self.file("directory-marker/Cargo.toml/content")
        self.file("directory-marker/target/file")
        self.file("actual-package.json")
        self.file("symlink-marker/.next/file")
        (self.home / "symlink-marker/package.json").symlink_to(self.home / "actual-package.json")
        self.assertEqual({c["category"] for c in self.wins()["candidates"]}, {"rust_build", "next_build"})

    def test_explicit_scan_root_does_not_require_home(self):
        self.env.pop("HOME")
        self.file("content")
        result = self.run_cli("scan", "--root", str(self.home))
        self.assertEqual(result["summary"]["file_count"], 1)

    def test_invalid_path_and_home(self):
        file = self.file("file")
        self.run_cli("scan", "--root", str(file) + "/..", code=1)
        self.run_cli("scan", "--root", "", code=2)
        self.env["HOME"] = "relative"
        self.run_cli("quick-wins", code=2)
        self.run_cli("scan", "--limit", "0", code=2)

    def test_partial_candidates_are_labeled_without_changing_panel_selection(self):
        if os.geteuid() == 0:
            self.skipTest("root bypasses fixture permission bits")
        # `.npm` is a tool cache that is still a candidate; the home-level
        # `~/.cache` is not any more (too broad for the guard), so it could not
        # carry this test's "candidate with an unreadable child" fixture.
        self.file(".npm/visible")
        denied = self.home / ".npm/denied"
        denied.mkdir()
        denied.chmod(0)
        try:
            result = self.run_cli("quick-wins", "--min-bytes", "1")
            self.assertFalse(result["coverage"]["complete"])
            self.assertEqual(result["report"]["candidates"][0]["path"], str(self.home / ".npm"))
            self.assertFalse(result["report"]["candidates"][0]["complete"])
            self.assertTrue(result["report"]["candidates"][0]["requires_review"])
            directory = next(d for d in result["report"]["inventory"]["largest_directories"] if d["path"] == str(self.home / ".npm"))
            self.assertFalse(directory["complete"])
        finally:
            denied.chmod(0o700)

    def test_inventory_includes_large_unclassified_and_sensitive_directories(self):
        self.file("Documents/archives/big-file", size=65536)
        self.file(".npm/npmrc")
        scan = self.run_cli("scan", "--min-bytes", "1")["report"]
        self.assertEqual(scan["largest_directories"][0]["path"], str(self.home / "Documents"))
        self.assertIn(str(self.home / "Documents/archives"), [d["path"] for d in scan["largest_directories"]])
        wins = self.wins()
        self.assertEqual(wins["inventory"], scan)
        self.assertEqual([c["path"] for c in wins["candidates"]], [str(self.home / ".npm")])

    def test_inventory_is_returned_even_outside_home(self):
        outside = self.root / "outside"
        (outside / "large").mkdir(parents=True)
        (outside / "large/file").write_bytes(b"x" * 8192)
        report = self.wins("--root", str(outside))
        self.assertEqual(report["candidates"], [])
        self.assertEqual(report["inventory"]["largest_directories"][0]["path"], str(outside / "large"))

    def test_hardlink_path_allocation_and_report_order_are_stable(self):
        source = self.file("z/node_modules/file")
        destination = self.home / "a/node_modules/file"
        destination.parent.mkdir(parents=True)
        os.link(source, destination)
        reports = [self.wins() for _ in range(6)]
        self.assertTrue(all(r == reports[0] for r in reports))
        self.assertEqual([c["path"] for c in reports[0]["candidates"]], [str(destination.parent)])
        self.assertEqual(reports[0]["candidate_allocated_bytes"], source.stat().st_blocks * 512)


if __name__ == "__main__":
    unittest.main()
