#!/usr/bin/env bash
# Golden tests for Rust-style compiler diagnostics.
# Usage: from repo root: tests/error_golden/run.sh [path/to/buxc]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUXC="${1:-$ROOT/buxc}"
DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -x "$BUXC" ]]; then
  echo "error: buxc not found at $BUXC (run make build first)"
  exit 1
fi

passed=0
failed=0

normalize() {
  # Replace absolute path prefix with FILE, drop trailing blank lines
  sed -E \
    -e "s|$DIR/[^:]+:|FILE:|g" \
    -e "s|$ROOT/[^:]+:|FILE:|g" \
    -e "s|//+|/|g" \
    | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

for case_dir in "$DIR"/*/; do
  name="$(basename "$case_dir")"
  [[ -f "$case_dir/expected.err" ]] || continue
  [[ -f "$case_dir/bux.toml" ]] || continue

  out="$("$BUXC" build "$case_dir" --color off 2>&1 || true)"
  got="$(printf '%s\n' "$out" | normalize)"
  exp="$(cat "$case_dir/expected.err")"

  # Compare ignoring full absolute path differences already normalized
  if [[ "$got" == "$exp" ]]; then
    echo "  PASS $name"
    passed=$((passed + 1))
  else
    echo "  FAIL $name"
    echo "---- expected ----"
    printf '%s\n' "$exp"
    echo "---- got ----"
    printf '%s\n' "$got"
    echo "--------------"
    failed=$((failed + 1))
  fi
done

echo "Error golden tests: $passed passed, $failed failed"
if [[ $failed -gt 0 ]]; then
  exit 1
fi
