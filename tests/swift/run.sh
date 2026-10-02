#!/bin/zsh
# Build and run the guard unit tests (plan T8).
# Same swiftc contract as build.sh: -import-objc-header, -swift-version 6,
# -default-isolation MainActor, linked against the Rust staticlib because the
# guard's command table comes from the bz_cleanup_allowlist FFI (fail-closed).
set -euo pipefail
cd "$(dirname "$0")/../.."

if ! cargo build --release 2>&1 >/dev/null; then
    echo "error: cargo build --release failed" >&2
    exit 1
fi

mkdir -p .build
swiftc tests/swift/main.swift app/CleanupGuard.swift \
    -import-objc-header app/bz.h \
    -swift-version 6 -default-isolation MainActor \
    -target arm64-apple-macos14.0 \
    -L target/release -lappletree \
    -o .build/guard-tests

.build/guard-tests
