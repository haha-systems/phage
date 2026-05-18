#!/usr/bin/env bash
set -euo pipefail

# Cheap machine-readable benchmark smoke for autonomous workers.
# Uses a memory baseline plus a small persisted run and verifies both outputs parse as JSON.
DB_PATH="${1:-/tmp/phage-prd-s2-bench}"
MEMORY_JSON="$(mktemp "${TMPDIR:-/tmp}/phage-memory-json.XXXXXX")"
PERSISTED_JSON="$(mktemp "${TMPDIR:-/tmp}/phage-persisted-json.XXXXXX")"
cleanup() {
  rm -f "${MEMORY_JSON}" "${PERSISTED_JSON}" "${DB_PATH}" "${DB_PATH}.wal"
}
trap cleanup EXIT
cleanup

zig build -Doptimize=ReleaseFast benchmark -- 1000 --mode memory --value-size 16 --batch-size 16 --json >"${MEMORY_JSON}"
python3 -m json.tool "${MEMORY_JSON}" >/dev/null

zig build -Doptimize=ReleaseFast benchmark -- 1000 --value-size 16 --batch-size 16 --db-path "${DB_PATH}" --json >"${PERSISTED_JSON}"
python3 -m json.tool "${PERSISTED_JSON}" >/dev/null

echo "benchmark json smoke passed"
