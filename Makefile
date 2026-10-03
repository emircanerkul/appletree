# AppleTree — single build entry point.
#
# This Makefile replaces the former build.sh, deploy.sh, release.sh,
# tests/swift/run.sh, benchmarks/run-agent.sh and benchmarks/run-ui.sh.
# All recipes run under bash (`SHELL` below) with errexit, nounset and
# pipefail, matching the old `set -euo pipefail` contracts.
#
# Quick reference (`make help`):
#
#   make build                 build/AppleTree.app (Rust engine + Swift UI + signing)
#   make deploy                rebuild and clean-replace /Applications/AppleTree.app
#   make release V=1.2.3       build, notarize (if Developer ID + notary profile),
#                              package AppleTree.dmg, publish GitHub release
#                              optional: NOTES_FILE=path/to/notes.md
#   make test                  guard unit tests (Swift, linked against the Rust staticlib)
#   make test-rust             cargo test --release
#   make bench-ui              UI benchmark with synthetic fixtures
#   make bench-ui SCAN_PATHS="/Applications"   real read-only scan benchmark
#   make bench-agent           agent data-algorithm benchmark (offline)
#                              optional: ARGS="--check-only"
#   make engine                cargo build --release only
#   make icon                  regenerate AppIcon source (assets/gen_icon.py)
#   make clean                 remove build/, .build/, AppleTree.dmg, SHA256SUMS.txt
#
# Notes:
# - `make build` syncs assets/logo.svg into assets/AppIcon.icon/Assets/logo.svg
#   before compiling the icon: assets/logo.svg is the single source of truth
#   for the icon artwork.
# - macOS ships GNU Make 3.81: no .ONESHELL. Every recipe line is a separate
#   shell; multi-step recipes chain with `; \` continuations.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DELETE_ON_ERROR:

VERSION := $(shell awk -F'"' '/^version/{print $$2; exit}' Cargo.toml)
MIN_MACOS := 14.0
APP := build/AppleTree.app
CARGO := $(shell command -v cargo 2>/dev/null || echo "$$HOME/.cargo/bin/cargo")

# Signing keychain used so codesign never prompts interactively.
SIGN_KC := $(HOME)/Library/Keychains/appletree-signing.keychain-db
SIGN_PASS := $(HOME)/.config/appletree-signing/keychain.pass

# Shared swiftc contract: optimization, Swift 6 language mode, default
# MainActor isolation (needs Swift 6.1 / Xcode 16.3+), arm64, macOS 14.
SWIFT_FLAGS := -O -parse-as-library -swift-version 6 -default-isolation MainActor \
               -target arm64-apple-macos$(MIN_MACOS) -framework AppKit -framework SwiftUI

# Benchmark UI/agent file subset: production sources minus Main.swift (@main,
# collides with the benchmark runners) and Settings.swift (its views are used
# only by Main). ModelProvider is needed for ProviderStore, which Model references.
BENCH_FILES := AgentSupport AgentLocator AgentSetup AgentStreamReader AgentPrompt \
               AgentRun CleanupGuard CleanupModel Cleanup ContentView Model ModelProvider \
               PlanParsing Treemap TreemapView SunburstView

.DEFAULT_GOAL := help
.PHONY: help all build engine bundle deploy release test test-rust bench-ui bench-agent icon clean

help:
	@echo 'AppleTree targets:'
	@echo '  make build              build/AppleTree.app (engine + UI + signing)'
	@echo '  make deploy             rebuild and clean-replace /Applications/AppleTree.app'
	@echo '  make release V=x.y.z    notarize, package dmg, publish GitHub release'
	@echo '                          optional NOTES_FILE=path/to/notes.md'
	@echo '  make test               guard unit tests (Swift over the Rust staticlib)'
	@echo '  make test-rust          cargo test --release'
	@echo '  make bench-ui           UI benchmark (synthetic fixtures)'
	@echo '  make bench-ui SCAN_PATHS="/Applications"   real read-only scan benchmark'
	@echo '  make bench-agent        agent data-algorithm benchmark (offline)'
	@echo '                          optional ARGS="--check-only"'
	@echo '  make engine             cargo build --release only'
	@echo '  make icon               regenerate AppIcon source (assets/gen_icon.py)'
	@echo '  make clean              remove build/, .build/, dmg and checksums'

all: build

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

# Last three macOS releases. Newer-only UI (Liquid Glass) is gated with
# #available, so the compiler enforces that nothing newer slips in unguarded.
engine:
	@echo '==> Rust engine'
	MACOSX_DEPLOYMENT_TARGET=$(MIN_MACOS) $(CARGO) build --release

# Probe the installed Swift for -default-isolation (Swift 6.1, Xcode 16.3+).
SWIFT_PROBE := if ! echo 'func bzProbe() {}' | swiftc -swift-version 6 -default-isolation MainActor -typecheck - >/dev/null 2>&1; then echo 'error: the installed Swift predates 6.1 and cannot build the UI; default-MainActor isolation needs Xcode 16.3 or newer.' >&2; exit 1; fi

# build/AppleTree.app: Rust staticlib + Swift UI, bundled, icon compiled,
# localizations copied, then signed.
#
# Signing prefers a real identity so a stable code requirement keeps TCC/FDA
# grants alive across rebuilds: Developer ID (paid program) with hardened
# runtime and secure timestamp — what notarization needs — falls back to
# Apple Development, then ad-hoc. The Developer ID key lives in its own
# keychain so codesign never prompts; unlock it when present.
bundle: engine
	@echo '==> Swift UI'
	@$(SWIFT_PROBE)
	rm -rf '$(APP)'
	mkdir -p '$(APP)/Contents/MacOS' '$(APP)/Contents/Resources' build
	# assets/logo.svg is the icon source of truth; the AppIcon.icon copy must
	# not go stale (this cp used to be a manual step before every build).
	cp assets/logo.svg assets/AppIcon.icon/Assets/logo.svg
	swiftc app/*.swift \
	    -import-objc-header app/bz.h \
	    $(SWIFT_FLAGS) \
	    -L target/release -lappletree \
	    -o '$(APP)/Contents/MacOS/AppleTree'
	{ printf '%s\n' \
	    '<?xml version="1.0" encoding="UTF-8"?>' \
	    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	    '<plist version="1.0">' \
	    '<dict>' \
	    '    <key>CFBundleName</key><string>AppleTree</string>' \
	    '    <key>CFBundleDisplayName</key><string>AppleTree</string>' \
	    '    <key>CFBundleIdentifier</key><string>dev.emircan.appletree</string>' \
	    "    <key>CFBundleVersion</key><string>$(VERSION)</string>" \
	    "    <key>CFBundleShortVersionString</key><string>$(VERSION)</string>" \
	    '    <key>CFBundleExecutable</key><string>AppleTree</string>' \
	    '    <key>CFBundlePackageType</key><string>APPL</string>' \
	    "    <key>LSMinimumSystemVersion</key><string>$(MIN_MACOS)</string>" \
	    '    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>' \
	    '    <key>CFBundleIconFile</key><string>AppIcon</string>' \
	    '    <key>CFBundleIconName</key><string>AppIcon</string>' \
	    '    <key>NSHighResolutionCapable</key><true/>' \
	    '    <key>NSHumanReadableCopyright</key><string>Emircan ERKUL</string>' \
	    '    <key>CFBundleDevelopmentRegion</key><string>en</string>' \
	    '</dict>' \
	    '</plist>'; } > '$(APP)/Contents/Info.plist'
	echo -n 'APPL????' > '$(APP)/Contents/PkgInfo'
	# Icon Composer source → Assets.car (Liquid Glass, macOS 26+) plus a flat
	# AppIcon.icns that older systems use. Regenerate the source with `make icon`.
	xcrun actool $$(pwd)/assets/AppIcon.icon \
	    --compile $$(pwd)/$(APP)/Contents/Resources \
	    --platform macosx --target-device mac \
	    --minimum-deployment-target $(MIN_MACOS) \
	    --app-icon AppIcon \
	    --output-partial-info-plist $$(pwd)/build/icon-partial.plist >/dev/null
	# Classic .lproj Localizable.strings tables (swiftc, no Xcode build system).
	for lproj in app/*.lproj; do cp -R "$$lproj" '$(APP)/Contents/Resources/'; done
	if [[ -f '$(SIGN_KC)' && -f '$(SIGN_PASS)' ]]; then \
	    security unlock-keychain -p "$$(<$(SIGN_PASS))" '$(SIGN_KC)'; \
	fi
	IDS=$$(security find-identity -v -p codesigning 2>/dev/null); \
	DEVID=$$(awk -F'"' '/Developer ID Application/{print $$2; exit}' <<<"$$IDS"); \
	DEV=$$(awk -F'"' '/Apple Development/{print $$2; exit}' <<<"$$IDS"); \
	if [[ -n "$$DEVID" ]]; then \
	    codesign --force --options runtime --timestamp --sign "$$DEVID" '$(APP)'; \
	else \
	    codesign --force --sign "$${DEV:--}" '$(APP)'; \
	fi
	@echo "==> Built $(APP)"

build: bundle

open: build
	@open '$(APP)'

icon:
	python3 assets/gen_icon.py
	cp assets/logo.svg assets/AppIcon.icon/Assets/logo.svg

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------

# Clean replace, not a ditto-merge over the old bundle: a merged bundle can
# corrupt the signature, and an invalid signature makes TCC silently ignore
# the FDA grant.
deploy: build
	@echo '==> Deploying to /Applications/AppleTree.app'
	rm -rf /Applications/AppleTree.app
	ditto '$(APP)' /Applications/AppleTree.app
	codesign --verify --strict /Applications/AppleTree.app
	@echo '==> Deployed to /Applications/AppleTree.app (signature verified)'

# ---------------------------------------------------------------------------
# Release
# ---------------------------------------------------------------------------

# Build, notarize when possible, package as dmg, publish a GitHub release.
#
# Notarization needs a Developer ID signature and stored notary credentials
# (one-time: `xcrun notarytool store-credentials appletree-notary --key
# <AuthKey.p8> --key-id <id> --issuer <uuid>`). The app is stapled before
# packaging so it opens offline once copied out of the dmg; the dmg is then
# signed, notarized and stapled itself. (-dvv: plain -dv never prints the
# Authority lines.)
#
# Re-running over an existing (e.g. draft) release replaces its files.
release: build
	@test -n '$(V)' || { echo 'usage: make release V=0.1.0 [NOTES_FILE=path]' >&2; exit 1; }
	@DEVID=$$(codesign -dvv '$(APP)' 2>&1 | awk -F= '/^Authority=Developer ID Application/ && !n++ {print $$2}'); \
	RELNOTES=''; \
	if [[ -n "$$DEVID" ]]; then \
	    echo '==> Notarizing app'; \
	    ZIP=$$(mktemp -d)/AppleTree.zip; \
	    ditto -c -k --keepParent '$(APP)' "$$ZIP"; \
	    xcrun notarytool submit "$$ZIP" --keychain-profile appletree-notary --wait; \
	    xcrun stapler staple '$(APP)'; \
	    rm -f "$$ZIP"; \
	fi; \
	STAGE=$$(mktemp -d); \
	cp -R '$(APP)' "$$STAGE/"; \
	ln -s /Applications "$$STAGE/Applications"; \
	rm -f AppleTree.dmg; \
	hdiutil create -volname AppleTree -srcfolder "$$STAGE" -ov -format UDZO -quiet AppleTree.dmg; \
	rm -rf "$$STAGE"; \
	if [[ -n "$$DEVID" ]]; then \
	    echo '==> Notarizing dmg'; \
	    codesign --force --timestamp --sign "$$DEVID" AppleTree.dmg; \
	    xcrun notarytool submit AppleTree.dmg --keychain-profile appletree-notary --wait; \
	    xcrun stapler staple AppleTree.dmg; \
	    spctl --assess --type open --context context:primary-signature -v AppleTree.dmg; \
	    RELNOTES='Download AppleTree.dmg and drag it to Applications, then grant Full Disk Access when asked and relaunch.'; \
	else \
	    RELNOTES='Download AppleTree.dmg, drag to Applications. First launch: System Settings → Privacy & Security → Open Anyway (unnotarized build), then grant Full Disk Access and relaunch.'; \
	fi; \
	if [[ -n '$(NOTES_FILE)' ]]; then RELNOTES=$$(<$(NOTES_FILE)); fi; \
	shasum -a 256 AppleTree.dmg > SHA256SUMS.txt; \
	if gh release view 'v$(V)' >/dev/null 2>&1; then \
	    gh release upload 'v$(V)' AppleTree.dmg SHA256SUMS.txt --clobber; \
	    gh release edit 'v$(V)' --title 'AppleTree $(V)' --notes "$$RELNOTES" --draft=false --latest; \
	else \
	    gh release create 'v$(V)' AppleTree.dmg SHA256SUMS.txt \
	        --title 'AppleTree $(V)' \
	        --notes "$$RELNOTES"; \
	fi; \
	rm -f SHA256SUMS.txt; \
	echo '==> released v$(V)'

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test-rust:
	$(CARGO) test --release

# Guard unit tests (plan T8). Same swiftc contract as the app build:
# -import-objc-header, Swift 6, default-MainActor isolation, linked against
# the Rust staticlib because the guard's command table comes from the
# bz_cleanup_allowlist FFI (fail-closed).
test: engine
	@mkdir -p .build
	swiftc tests/swift/main.swift app/CleanupGuard.swift \
	    -import-objc-header app/bz.h \
	    -swift-version 6 -default-isolation MainActor \
	    -target arm64-apple-macos$(MIN_MACOS) \
	    -L target/release -lappletree \
	    -o .build/guard-tests
	.build/guard-tests

# ---------------------------------------------------------------------------
# Benchmarks
# ---------------------------------------------------------------------------

# Python patcher for the agent benchmark: freeze production Swift and inject
# benchmark hooks. Exported so the recipe shell reads it from the environment.
define AGENT_PATCH_PY
from pathlib import Path
import sys
p=Path(sys.argv[1]); source=p.read_text()
changes={
    'private var preparationTask: Task<Void, Never>?': 'var preparationTask: Task<Void, Never>?',
    'start(input: input, env: env)': 'AgentBenchmarkLaunch.record(input)',
    'AgentPrompt.build(tree: tree, scanRoot: scanRoot, known: known, running: running)': 'AgentBenchmarkGate.shared.waitIfArmed(); return AgentPrompt.build(tree: tree, scanRoot: scanRoot, known: known, running: running)',
}
for old,new in changes.items():
    assert source.count(old)==1, f'Expected one benchmark hook: {old}'
    source=source.replace(old,new)
p.write_text(source)
p=Path(sys.argv[2]); source=p.read_text()
old='let result = await Trash.trash(items.map(\\.path))'
assert source.count(old)==1, 'Expected one shared-trash pathway call'
p.write_text(source.replace(old, 'let result = await AgentBenchmarkTrash.trash(items.map(\\.path))'))
p=Path(sys.argv[3]); source=p.read_text()
old='''    func startAgent(_ agent: InstalledAgent) {
'''
new='''    func startAgent(_ agent: InstalledAgent) {
        AgentBenchmarkLaunch.agentStarts += 1
'''
assert source.count(old)==1, 'Expected one agent start'
p.write_text(source.replace(old, new))
endef
export AGENT_PATCH_PY

# Agent data algorithms, entirely offline: the production sources are copied
# to a temp dir (frozen while other work may edit shared files), patched with
# benchmark hooks, checksummed, compiled against the C fixture, and run.
bench-agent: engine
	@TMP=$$(mktemp -d /tmp/appletree-agent-bench.XXXXXX); \
	trap 'rm -rf "$$TMP"' EXIT; \
	mkdir "$$TMP/app"; \
	cp app/*.swift "$$TMP/app/"; \
	shasum -a 256 "$$TMP/app/AgentRun.swift" "$$TMP/app/CleanupModel.swift" "$$TMP/app/Model.swift"; \
	python3 -c "$$AGENT_PATCH_PY" "$$TMP/app/AgentRun.swift" "$$TMP/app/CleanupModel.swift" "$$TMP/app/Model.swift"; \
	clang -O2 -mmacosx-version-min=$(MIN_MACOS) -c benchmarks/ui_fixture.c -o "$$TMP/fixture.o"; \
	swiftc "$$TMP/app/AgentSupport.swift" \
	  "$$TMP/app/AgentLocator.swift" "$$TMP/app/AgentSetup.swift" \
	  "$$TMP/app/AgentStreamReader.swift" "$$TMP/app/AgentPrompt.swift" \
	  "$$TMP/app/AgentRun.swift" "$$TMP/app/CleanupGuard.swift" \
	  "$$TMP/app/CleanupModel.swift" "$$TMP/app/Cleanup.swift" "$$TMP/app/ContentView.swift" \
	  "$$TMP/app/Model.swift" "$$TMP/app/ModelProvider.swift" \
	  "$$TMP/app/PlanParsing.swift" "$$TMP/app/Treemap.swift" \
	  "$$TMP/app/TreemapView.swift" "$$TMP/app/SunburstView.swift" \
	  benchmarks/AgentReference.swift benchmarks/AgentPerformance.swift "$$TMP/fixture.o" \
	  -import-objc-header benchmarks/ui_fixture.h \
	  $(SWIFT_FLAGS) \
	  -o "$$TMP/agent-bench"; \
	"$$TMP/agent-bench" $(ARGS)

# UI benchmark: production Swift sources with synthetic fixtures, or a real
# read-only scan when SCAN_PATHS is set (`make bench-ui SCAN_PATHS="/Applications"`).
bench-ui:
	@TMP=$$(mktemp -d /tmp/appletree-ui-bench.XXXXXX); \
	trap 'rm -rf "$$TMP"' EXIT; \
	mkdir "$$TMP/app"; \
	cp app/*.swift "$$TMP/app/"; \
	shasum -a 256 "$$TMP/app/Cleanup.swift" "$$TMP/app/Model.swift" "$$TMP/app/ContentView.swift"; \
	INPUTS='benchmarks/UIPerformance.swift'; \
	LINK=''; \
	HEADER=benchmarks/ui_fixture.h; \
	if [[ -n '$(SCAN_PATHS)' ]]; then \
	    [[ -f target/release/libappletree.a ]] || { echo 'Build the Rust library first: make engine' >&2; exit 2; }; \
	    INPUTS='benchmarks/UICleanupScan.swift'; \
	    LINK='-L target/release -lappletree'; \
	    HEADER=app/bz.h; \
	else \
	    clang -O2 -mmacosx-version-min=$(MIN_MACOS) -c benchmarks/ui_fixture.c -o "$$TMP/fixture.o"; \
	    INPUTS="$$INPUTS $$TMP/fixture.o"; \
	fi; \
	BENCH_PATHS=(); \
	for f in $(BENCH_FILES); do BENCH_PATHS+=("$$TMP/app/$$f.swift"); done; \
	swiftc "$${BENCH_PATHS[@]}" \
	  $${INPUTS} benchmarks/UIReferenceCleanup.swift $${LINK} \
	  -import-objc-header "$$HEADER" \
	  $(SWIFT_FLAGS) \
	  -o "$$TMP/ui-bench"; \
	"$$TMP/ui-bench" $(SCAN_PATHS) $(ARGS)

# ---------------------------------------------------------------------------
# Clean
# ---------------------------------------------------------------------------

clean:
	rm -rf build .build AppleTree.dmg SHA256SUMS.txt
