# AppleTree — single build entry point.
#
# This Makefile replaces the former build.sh, deploy.sh, release.sh and
# tests/swift/run.sh.
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
# DiskArbitration + IOKit: Model.swift classifies mounted volumes to tell a
# real drive from a mounted disk image (ScanTargets.mountedDrives).
SWIFT_FLAGS := -O -parse-as-library -swift-version 6 -default-isolation MainActor \
               -target arm64-apple-macos$(MIN_MACOS) -framework AppKit -framework SwiftUI \
               -framework DiskArbitration -framework IOKit

.DEFAULT_GOAL := help
.PHONY: help all build engine bundle open deploy release test test-planner test-drawer test-links test-readme test-doclinks test-router test-privacy test-l10n test-rust icon clean

help:
	@echo 'AppleTree targets:'
	@echo '  make build              build/AppleTree.app (engine + UI + signing)'
	@echo '  make deploy             rebuild and clean-replace /Applications/AppleTree.app'
	@echo '  make release V=x.y.z    notarize, package dmg, publish GitHub release'
	@echo '                          optional NOTES_FILE=path/to/notes.md'
	@echo '  make test               guard unit tests (Swift over the Rust staticlib)'
	@echo '  make test-planner       planner catalog, preference and sign-out tests'
	@echo '  make test-drawer        right-drawer trash outcome and plan-group tests'
	@echo '  make test-links         Help-menu and About link destinations'
	@echo '  make test-readme        bundled README parses into renderable blocks'
	@echo '  make test-doclinks      document links resolve (no scheme-less paths)'
	@echo '  make test-router        Add-a-provider opens Model Providers + its form'
	@echo '  make test-privacy       policy reachable in-app + privacy manifest complete'
	@echo '  make test-l10n          every .strings table has the same keys, no duplicates'
	@echo '  make test-rust          cargo test --release'
	@echo '  make engine             cargo build --release only'
	@echo '  make icon               regenerate AppIcon source (assets/gen_icon.py)'
	@echo '  make clean              remove build/, .build/, dmg and checksums'

all: build

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

# Last three macOS releases. Newer-only UI (Liquid Glass) is gated with
# #available, so the compiler enforces that nothing newer slips in unguarded.
#
# MACOSX_DEPLOYMENT_TARGET only governs crates cargo actually compiles; it does
# NOT retarget the prebuilt `std` a binary rustc ships with. Homebrew's rustc
# builds std for the host OS, so its objects keep that OS as `minos` and the
# final link warns "built for newer 'macOS' version than being linked". The
# check below reads the archive itself, because the env var is not evidence of
# what the objects declare; STRICT_DEPLOYMENT_TARGET=1 turns it into an error.
#
# A Homebrew std cannot be retargeted in place — the only fix is a toolchain
# whose std was built for $(MIN_MACOS) (a rustup toolchain, not Homebrew's).
#
# Keep it to one otool pass: `otool -l` over the 9 MB archive takes ~16 ms, so
# this stays in the noise of the build it follows.
engine:
	@echo '==> Rust engine'
	MACOSX_DEPLOYMENT_TARGET=$(MIN_MACOS) $(CARGO) build --release
	OTOOL=$$(otool -l target/release/libappletree.a 2>/dev/null || true); \
	BAD=$$(printf '%s\n' "$$OTOOL" | awk -v want='$(MIN_MACOS)' '/^ *(minos|version) / { n=split(want,w,"."); split($$2,v,"."); if (v[1]+0 > w[1]+0 || (v[1]+0 == w[1]+0 && v[2]+0 > w[2]+0)) print $$2 }'); \
	if [[ -n "$$BAD" ]]; then \
	    N=$$(printf '%s\n' "$$BAD" | wc -l | tr -d ' '); \
	    WORST=$$(printf '%s\n' "$$BAD" | awk '{split($$1,v,"."); k=v[1]*10000+v[2]; if (k>m) {m=k; w=$$1}} END {print w}'); \
	    if [[ '$(STRICT_DEPLOYMENT_TARGET)' == 1 ]]; then \
	        echo "ERROR: $$N object(s) in target/release/libappletree.a declare macOS $$WORST," >&2; \
	        echo "       newer than the $(MIN_MACOS) this build declares." >&2; \
	    else \
	        echo "WARNING: $$N object(s) in target/release/libappletree.a were built for" >&2; \
	        echo "         macOS $$WORST, newer than the $(MIN_MACOS) this build declares." >&2; \
	    fi; \
	    echo '         MACOSX_DEPLOYMENT_TARGET does not retarget a prebuilt std, so' >&2; \
	    echo '         the app declares minos $(MIN_MACOS) but those objects may not' >&2; \
	    echo "         load on the macOS $(MIN_MACOS) that LSMinimumSystemVersion promises." >&2; \
	    echo '         Fix: build with a rustup toolchain whose std targets $(MIN_MACOS)' >&2; \
	    echo '         instead of the Homebrew rustc (rustup install + rustup override).' >&2; \
	    if [[ '$(STRICT_DEPLOYMENT_TARGET)' == 1 ]]; then exit 1; fi; \
	fi

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
	# ATS: user-configured model providers are plain HTTP on the local
	# machine or LAN (http://localhost:11434/v1, http://192.168.1.20:11434/v1).
	# NSAllowsLocalNetworking is Apple's narrow key for local resources
	# (unqualified domains, .local domains, IP addresses); public hosts stay
	# HTTPS-only. NSAllowsArbitraryLoads is deliberately NOT set: it would
	# disable ATS for every connection this app makes.
	{ printf '%s\n' \
	    '<?xml version="1.0" encoding="UTF-8"?>' \
	    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	    '<plist version="1.0">' \
	    '<dict>' \
	    '    <key>CFBundleName</key><string>AppleTree</string>' \
	    '    <key>CFBundleDisplayName</key><string>AppleTree</string>' \
	    '    <key>CFBundleIdentifier</key><string>com.erklab.apps.appletree</string>' \
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
	    '    <key>NSAppTransportSecurity</key>' \
	    '    <dict>' \
	    '        <key>NSAllowsLocalNetworking</key><true/>' \
	    '    </dict>' \
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
	# The README ships inside the app: Help → AppleTree README reads it with no
	# browser and no network, so it cannot be fetched from GitHub at view time.
	cp README.md '$(APP)/Contents/Resources/README.md'
	# Same for the license: About's "View license" reads it in-app.
	cp LICENSE '$(APP)/Contents/Resources/LICENSE'
	# And the privacy policy: Guideline 5.1.1(i) wants it reachable in the app,
	# so About and Help both open this bundled copy rather than a URL.
	cp docs/wiki/Privacy-Policy.md '$(APP)/Contents/Resources/PrivacyPolicy.md'
	# erklab wordmark, as SVG. AppKit renders SVG natively (macOS 13+), so one
	# file serves every scale; the template rendering tints it per appearance.
	cp assets/erklab-logo.svg '$(APP)/Contents/Resources/erklab-logo.svg'
	# Privacy manifest. Required for submission: App Store Connect refuses an
	# upload whose binary links required-reason APIs without declaring them
	# (ITMS-91053). It goes in Resources, NOT the bundle root — codesign refuses
	# to seal an unsigned bundle-root item ("code object is not signed at all /
	# In subcomponent: .../Contents/PrivacyInfo.xcprivacy"), and real macOS apps
	# such as GarageBand carry theirs in Contents/Resources.
	cp app/PrivacyInfo.xcprivacy '$(APP)/Contents/Resources/PrivacyInfo.xcprivacy'
	if [[ -f '$(SIGN_KC)' && -f '$(SIGN_PASS)' ]]; then \
	    security unlock-keychain -p "$$(<$(SIGN_PASS))" '$(SIGN_KC)'; \
	fi
	IDS=$$(security find-identity -v -p codesigning 2>/dev/null); \
	DEVID=$$(awk -F'"' '/Developer ID Application/{print $$2; exit}' <<<"$$IDS"); \
	DEV=$$(awk -F'"' '/Apple Development/{print $$2; exit}' <<<"$$IDS"); \
	if [[ -n "$$DEVID" ]]; then \
	    codesign --force --options runtime --timestamp --sign "$$DEVID" '$(APP)'; \
	elif [[ -n "$$DEV" ]]; then \
	    codesign --force --sign "$$DEV" '$(APP)'; \
	else \
	    echo 'WARNING: no codesigning identity found; signing AD-HOC.' >&2; \
	    echo '         An ad-hoc signature pins the designated requirement to a' >&2; \
	    echo '         cdhash, which changes on every rebuild, so macOS TCC will' >&2; \
	    echo '         drop the app Full Disk Access grant each time you rebuild.' >&2; \
	    echo '         Fix: Xcode > Settings > Accounts > Manage Certificates > +' >&2; \
	    codesign --force --sign - '$(APP)'; \
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
#
# The V guard is its own recipe line ahead of the recursive build, so a mistyped
# `make release` fails before any compiling or signing. It carries the `+` flag
# so make still runs it under `-n` (recursive-make lines are skipped there),
# which is what makes `make -n release` show the usage error and no build.
#
# notarytool submit exits 0 even for a REJECTED submission (it prints
# "status: Invalid"), so the output is captured and required to read Accepted
# before anything is stapled or published — otherwise a rejected build went on
# to `gh release create` and printed `released`.
release:
	+@test -n '$(V)' || { echo 'usage: make release V=0.1.0 [NOTES_FILE=path]' >&2; exit 1; }
	@$(MAKE) --no-print-directory build
	@DEVID=$$(codesign -dvv '$(APP)' 2>&1 | awk -F= '/^Authority=Developer ID Application/ && !n++ {print $$2}'); \
	RELNOTES=''; \
	if [[ -n "$$DEVID" ]]; then \
	    echo '==> Notarizing app'; \
	    ZIP=$$(mktemp -d)/AppleTree.zip; \
	    ditto -c -k --keepParent '$(APP)' "$$ZIP"; \
	    OUT=$$(xcrun notarytool submit "$$ZIP" --keychain-profile appletree-notary --wait 2>&1) || { printf '%s\n' "$$OUT" >&2; echo 'ERROR: notarytool submit failed for the app.' >&2; exit 1; }; \
	    printf '%s\n' "$$OUT"; \
	    grep -qE '^ *status: Accepted$$' <<<"$$OUT" || { \
	        echo 'ERROR: notarization of the app was not Accepted; refusing to staple or publish it.' >&2; \
	        echo '       Inspect the rejection with: xcrun notarytool log <submission-id> --keychain-profile appletree-notary' >&2; \
	        exit 1; \
	    }; \
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
	    OUT=$$(xcrun notarytool submit AppleTree.dmg --keychain-profile appletree-notary --wait 2>&1) || { printf '%s\n' "$$OUT" >&2; echo 'ERROR: notarytool submit failed for the dmg.' >&2; exit 1; }; \
	    printf '%s\n' "$$OUT"; \
	    grep -qE '^ *status: Accepted$$' <<<"$$OUT" || { \
	        echo 'ERROR: notarization of the dmg was not Accepted; refusing to staple or publish it.' >&2; \
	        echo '       Inspect the rejection with: xcrun notarytool log <submission-id> --keychain-profile appletree-notary' >&2; \
	        exit 1; \
	    }; \
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
# The .strings check runs first: it is instant, and a table that drifted is a
# bug the Swift tests cannot see, so there is no reason to compile first.
test: engine test-l10n test-drawer test-links test-readme test-doclinks test-router test-privacy
	@mkdir -p .build
	swiftc tests/swift/main.swift app/CleanupGuard.swift \
	    -import-objc-header app/bz.h \
	    -swift-version 6 -default-isolation MainActor \
	    -target arm64-apple-macos$(MIN_MACOS) \
	    -L target/release -lappletree \
	    -o .build/guard-tests
	.build/guard-tests

# Right-drawer regression net: the trash outcome vocabulary and the plan-group
# classification. Compiled against the real shipping sources (the whole app
# except Main.swift, whose @main the test binary supplies), so these fail if the
# owner types drift. The fixture needs the real home directory and a guard that
# permits it, hence no stubs.
test-drawer: engine
	@mkdir -p .build
	swiftc tests/swift/drawer.swift $(filter-out app/Main.swift,$(wildcard app/*.swift)) \
	    -import-objc-header app/bz.h \
	    -parse-as-library \
	    -swift-version 6 -default-isolation MainActor \
	    -target arm64-apple-macos$(MIN_MACOS) \
	    -L target/release -lappletree \
	    -framework DiskArbitration -framework IOKit -framework Security \
	    -o .build/drawer-tests
	.build/drawer-tests

# Help-menu and About link destinations. Pure data — no FFI, no fixtures — so it
# stays fast and hermetic (it asserts the URLs, never that github.com answers).
# It exists because the first cut of the menu pointed two rows at Discussions,
# which this repository does not enable: a 404 for every reporter.
test-links:
	@mkdir -p .build
	swiftc tests/swift/links.swift app/AppMenu.swift app/DocumentView.swift app/ReadmeMarkdown.swift \
	    -parse-as-library -swift-version 6 -default-isolation MainActor \
	    -target arm64-apple-macos$(MIN_MACOS) \
	    -framework AppKit \
	    -o .build/link-tests
	.build/link-tests

# README viewer: the bundled markdown must parse into real blocks (headings,
# code fences, list items) with no HTML header leaking through as literal text.
# Compiles only ReadmeMarkdown.swift on purpose — the parsing is deliberately
# free of SwiftUI so it can be tested without linking a view framework.
test-readme:
	@mkdir -p .build
	swiftc tests/swift/readme.swift app/ReadmeMarkdown.swift \
	    -parse-as-library -swift-version 6 -default-isolation MainActor \
	    -target arm64-apple-macos$(MIN_MACOS) \
	    -o .build/readme-tests

# Document links: every relative link in the bundled README/LICENSE must resolve
# to something openable. A scheme-less link reaches macOS as a filesystem path
# and fails with "The application can't be opened. (-50)", which is what made
# clicking SECURITY.md or LICENSE in the README break.
test-doclinks:
	@mkdir -p .build
	swiftc tests/swift/doclinks.swift app/ReadmeMarkdown.swift \
	    -parse-as-library -swift-version 6 -default-isolation MainActor \
	    -target arm64-apple-macos$(MIN_MACOS) \
	    -o .build/doclink-tests

# Privacy compliance: the policy must be reachable in the app (5.1.1(i)), the
# AI disclosure must name the destination (5.1.2(i)), and the manifest must
# declare exactly the required-reason APIs the binary links (ITMS-91053).
test-privacy:
	@mkdir -p .build
	swiftc tests/swift/privacy.swift app/ReadmeMarkdown.swift \
	    -parse-as-library -swift-version 6 -default-isolation MainActor \
	    -target arm64-apple-macos$(MIN_MACOS) \
	    -o .build/privacy-tests
	.build/privacy-tests

# The Settings handoff: "Add a model provider" must select the Model Providers
# pane AND raise the add form, including when the click arrives before Settings
# exists. NOTE the test file MUST NOT be named `settingsrouter.swift`: swiftc
# then collides with the app's own SettingsRouter source and silently drops the
# @main entry point ("Undefined symbols: _main"), which is a compiler quirk, not
# a code error.
test-router:
	@mkdir -p .build
	swiftc tests/swift/router-handoff.swift app/SettingsRouter.swift \
	    -parse-as-library -swift-version 6 -default-isolation MainActor \
	    -target arm64-apple-macos$(MIN_MACOS) \
	    -o .build/router-tests
	.build/router-tests
	.build/doclink-tests
	.build/readme-tests

# Planner catalog and sign-out tests. Real shipping sources, no stubs, so this
# fails if the catalog rule, the preference resolution both surfaces share, or
# the CLI logout argv drifts. Needs Security for the provider model's Keychain
# calls.
test-planner:
	@mkdir -p .build
	swiftc tests/swift/planner.swift app/AgentSupport.swift app/AgentLocator.swift \
	    app/ModelProvider.swift app/PlanParsing.swift \
	    -parse-as-library -swift-version 6 -default-isolation MainActor \
	    -target arm64-apple-macos$(MIN_MACOS) -framework Security \
	    -o .build/planner-tests
	.build/planner-tests

# The 7 Localizable.strings tables must stay in lockstep: a key added to one
# and forgotten in another renders English in that language, and a duplicate
# key makes which translation wins undefined. Also checks that every
# String(localized:) key in app/*.swift is actually defined somewhere.
test-l10n:
	python3 tests/check-l10n.py

# ---------------------------------------------------------------------------
# Clean
# ---------------------------------------------------------------------------

clean:
	rm -rf build .build AppleTree.dmg SHA256SUMS.txt
