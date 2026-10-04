#!/usr/bin/env bash
# btbench — one command to benchmark AppleTree's scan engine against disktree.
#
#   cd bench && ./run.sh
#
# Checks the machine, builds both engines, benchmarks a synthetic fixture and a
# real folder (/Applications by default), and writes a report naming the host.
# Everything it writes lands in ../docs/benchmarks/results/<date>-<chip>-macos<ver>/.
set -euo pipefail

cd "$(dirname "$0")"

usage() {
  cat <<'EOF'
btbench — AppleTree scan-engine benchmark

USAGE:
  ./run.sh [options]

OPTIONS:
  --path DIR        Real folder to scan (default /Applications)
  --runs N          Measured rounds per engine (default 5)
  --fixture-size N  Fixture size: small, medium, large (default small)
  --skip-fixture    Benchmark only the real folder
  --no-disktree     AppleTree only; no comparison, no network needed
  -h, --help        Show this help

EXAMPLES:
  ./run.sh                          # fixture + /Applications, 5 rounds each
  ./run.sh --path "$HOME/Downloads" # a folder you can read
  ./run.sh --runs 10 --fixture-size medium
  ./run.sh --no-disktree            # works offline

RESULTS:
  ../docs/benchmarks/results/<YYYY-MM-DD>-<chip>-macos<ver>/{run.json,report.md}
EOF
}

PATH_ARG="/Applications"
RUNS=5
FIXTURE_SIZE="small"
SKIP_FIXTURE=0
NO_DISKTREE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path) PATH_ARG="${2:?--path needs a directory}"; shift 2 ;;
    --runs) RUNS="${2:?--runs needs a number}"; shift 2 ;;
    --fixture-size) FIXTURE_SIZE="${2:?--fixture-size needs a value}"; shift 2 ;;
    --skip-fixture) SKIP_FIXTURE=1; shift ;;
    --no-disktree) NO_DISKTREE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "run.sh: unknown option $1 (try --help)" >&2; exit 2 ;;
  esac
done

# --- preflight -------------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "run.sh: this benchmark measures macOS syscalls (getattrlistbulk); it only runs on macOS." >&2
  exit 1
fi
if ! command -v cargo >/dev/null 2>&1; then
  echo "run.sh: cargo not found. Install Rust from https://rustup.rs and re-run." >&2
  exit 1
fi
if ! command -v sysctl >/dev/null 2>&1 || ! command -v sw_vers >/dev/null 2>&1; then
  echo "run.sh: sysctl/sw_vers missing; this does not look like a normal macOS install." >&2
  exit 1
fi

FEATURES=()
SCAN_FLAGS=()
BUILD_LABEL="AppleTree vs disktree"
if [[ "$NO_DISKTREE" == "1" ]]; then
  FEATURES+=(--no-default-features)
  SCAN_FLAGS+=(--no-disktree)
  BUILD_LABEL="AppleTree only"
else
  echo "==> Building (first run fetches the pinned disktree-core; needs network once)"
fi

# --- build -----------------------------------------------------------------
echo "==> Building benchmark ($BUILD_LABEL)"
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
  cargo build --release "${FEATURES[@]+"${FEATURES[@]}"}"

BTBENCH="target/release/btbench"
HOST_HUMAN="$("$BTBENCH" host --human)"
echo "==> Host: $HOST_HUMAN"

DATE_DIR="$(date +%Y-%m-%d)-$("$BTBENCH" host --slug)"
OUT="$(cd .. && pwd)/docs/benchmarks/results/$DATE_DIR"
mkdir -p "$OUT"

# --- fixture run -----------------------------------------------------------
if [[ "$SKIP_FIXTURE" == "0" ]]; then
  FIXTURE_DIR="${TMPDIR:-/tmp}/btbench-fixture-$FIXTURE_SIZE"
  echo "==> Fixture ($FIXTURE_SIZE) at $FIXTURE_DIR"
  "$BTBENCH" fixture --size "$FIXTURE_SIZE" --out "$FIXTURE_DIR" --force >/dev/null
  "$BTBENCH" verify --path "$FIXTURE_DIR"
  "$BTBENCH" scan --path "$FIXTURE_DIR" --runs "$RUNS" --out "$OUT" \
    "${SCAN_FLAGS[@]+"${SCAN_FLAGS[@]}"}" | tail -n 4
  mv "$OUT/report.md" "$OUT/report-fixture.md" 2>/dev/null || true
  mv "$OUT/run.json" "$OUT/run-fixture.json" 2>/dev/null || true
fi

# --- real-folder run -------------------------------------------------------
if [[ -d "$PATH_ARG" ]]; then
  echo
  echo "==> Real folder: $PATH_ARG"
  "$BTBENCH" scan --path "$PATH_ARG" --runs "$RUNS" --out "$OUT" \
    "${SCAN_FLAGS[@]+"${SCAN_FLAGS[@]}"}" | tail -n 4
else
  echo
  echo "run.sh: skipping real folder '$PATH_ARG' (not a directory)" >&2
fi

echo
echo "==> Results in $OUT"
ls -1 "$OUT"
