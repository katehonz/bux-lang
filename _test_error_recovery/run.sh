#!/usr/bin/env bash
# Regression: buxc2 must report ALL independent semantic errors in one run.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BUXC2="$ROOT/build/selfhost/build/buxc2"
export BUX_STDLIB="$ROOT/lib"

if [[ ! -x "$BUXC2" ]]; then
  echo "=== building selfhost (buxc2) ==="
  (cd "$ROOT" && make selfhost)
fi
if [[ ! -x "$BUXC2" ]]; then
  echo "error: buxc2 not found at $BUXC2" >&2
  exit 1
fi

out="$(cd "$HERE" && "$BUXC2" check src/Main.bux 2>&1 || true)"
echo "$out"

grep -q "cannot assign String to int" <<<"$out"
grep -q "cannot assign int to bool" <<<"$out"
grep -q "undeclared identifier 'undefined_variable'" <<<"$out"

echo "PASS: all independent semantic errors reported in one run"
