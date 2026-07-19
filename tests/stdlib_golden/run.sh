#!/usr/bin/env bash
# Golden behavioral tests for stdlib modules.
# Usage: from repo root: tests/stdlib_golden/run.sh [path/to/buxc]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUXC_ARG="${1:-$ROOT/buxc}"
DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve to absolute path so `cd` into test packages still finds the binary.
if [[ "$BUXC_ARG" = /* ]]; then
  BUXC="$BUXC_ARG"
else
  BUXC="$(cd "$(dirname "$BUXC_ARG")" && pwd)/$(basename "$BUXC_ARG")"
fi

if [[ ! -x "$BUXC" && ! -f "$BUXC" ]]; then
  echo "error: buxc not found at $BUXC (run make build first)"
  exit 1
fi

passed=0
failed=0
skipped=0

normalize_out() {
  # Drop absolute paths; trim trailing whitespace/blank lines
  sed -E \
    -e "s|$ROOT|ROOT|g" \
    -e "s|$DIR|DIR|g" \
    -e 's/[[:space:]]+$//' \
    | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

for case_dir in "$DIR"/*/; do
  name="$(basename "$case_dir")"
  [[ -f "$case_dir/bux.toml" ]] || continue
  [[ -f "$case_dir/src/Main.bux" ]] || continue

  if [[ ! -f "$case_dir/expected.out" ]]; then
    echo "  SKIP $name (no expected.out)"
    skipped=$((skipped + 1))
    continue
  fi

  # Build + run; capture stdout+stderr
  out=""
  if ! out="$(cd "$case_dir" && "$BUXC" run . 2>&1)"; then
    echo "  FAIL $name (build/run non-zero)"
    printf '%s\n' "$out" | head -40
    failed=$((failed + 1))
    continue
  fi

  got="$(printf '%s\n' "$out" | normalize_out)"
  exp="$(cat "$case_dir/expected.out" | normalize_out)"

  # Match on key status lines (tests may also print build noise)
  if printf '%s\n' "$got" | grep -Fqx "$(printf '%s' "$exp" | head -1)" 2>/dev/null; then
    # Prefer full expected lines all present
    all_ok=1
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if ! printf '%s\n' "$got" | grep -Fqx "$line"; then
        all_ok=0
        break
      fi
    done <<< "$exp"
    if [[ $all_ok -eq 1 ]]; then
      echo "  PASS $name"
      passed=$((passed + 1))
      continue
    fi
  fi

  # Fallback: every non-empty expected line appears as substring
  all_ok=1
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if ! printf '%s\n' "$got" | grep -Fq "$line"; then
      all_ok=0
      break
    fi
  done <<< "$exp"

  if [[ $all_ok -eq 1 ]]; then
    echo "  PASS $name"
    passed=$((passed + 1))
  else
    echo "  FAIL $name"
    echo "---- expected lines ----"
    printf '%s\n' "$exp"
    echo "---- got (tail) ----"
    printf '%s\n' "$got" | tail -20
    echo "--------------"
    failed=$((failed + 1))
  fi
done

echo "Stdlib golden tests: $passed passed, $failed failed, $skipped skipped"
if [[ $failed -gt 0 ]]; then
  exit 1
fi
