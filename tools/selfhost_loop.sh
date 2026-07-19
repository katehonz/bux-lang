#!/usr/bin/env bash
# Selfhost loop (CI-optional / not in default `make test`).
#
# Default mode — bootstrap determinism (fast, required):
#   buxc builds src/ twice → path-normalized main.c + stripped ELF must match.
#
# Optional fixed-point (slow, experimental — set BUX_SELFHOST_FIXED_POINT=1):
#   buxc → buxc2 → buxc3; compare gen1 vs gen2. Currently may fail until
#   selfhost C backend matches bootstrap on full compiler sources.
#
# Usage: tools/selfhost_loop.sh
#        make selfhost-loop
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT="${OUT:-buxc}"
export BUX_STDLIB="${BUX_STDLIB:-$ROOT/lib}"
unset BUX_DEBUG_FILE || true
unset BUX_NO_LINE || true

if [[ ! -x "$ROOT/$OUT" ]]; then
  echo "=== building bootstrap ($OUT) ==="
  make -C "$ROOT" build
fi

A="$ROOT/build/selfhost-loop-a"
B="$ROOT/build/selfhost-loop-b"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

prepare_tree() {
  local dest="$1"
  rm -rf "$dest"
  mkdir -p "$dest/src"
  cp src/*.bux "$dest/src/"
  cp src/bux.toml "$dest/"
  if [[ -f "$dest/src/main.bux" ]]; then
    mv "$dest/src/main.bux" "$dest/src/Main.bux"
  fi
}

# Normalize #line paths so different build dirs / abs roots don't fail the diff.
normalize_c() {
  local src="$1" dst="$2"
  sed -E \
    -e 's|#line ([0-9]+) "[^"]*/(src/[^"]+\.bux)"|#line \1 "\2"|g' \
    -e 's|#line ([0-9]+) "[^"]*/(lib/[^"]+\.bux)"|#line \1 "\2"|g' \
    -e 's|#line ([0-9]+) "[^"]+/([^"/]+\.bux)"|#line \1 "\2"|g' \
    "$src" > "$dst"
}

compare_c_and_elf() {
  local label_a="$1" bin_a="$2" c_a="$3"
  local label_b="$4" bin_b="$5" c_b="$6"
  local ok=0

  echo "--- Compare path-normalized C ($label_a vs $label_b) ---"
  normalize_c "$c_a" "$TMP/main_a.c"
  normalize_c "$c_b" "$TMP/main_b.c"
  if diff -q "$TMP/main_a.c" "$TMP/main_b.c" >/dev/null 2>&1; then
    echo "  C output: IDENTICAL ✓ (paths normalized)"
  else
    echo "  C output: DIFFERENT ✗"
    diff -u "$TMP/main_a.c" "$TMP/main_b.c" | head -60 || true
    ok=1
  fi

  echo "--- Compare stripped ELF ($label_a vs $label_b) ---"
  cp "$bin_a" "$TMP/elf_a"
  cp "$bin_b" "$TMP/elf_b"
  strip -d "$TMP/elf_a" 2>/dev/null || strip "$TMP/elf_a"
  strip -d "$TMP/elf_b" 2>/dev/null || strip "$TMP/elf_b"
  if diff -q "$TMP/elf_a" "$TMP/elf_b" >/dev/null 2>&1; then
    echo "  ELF binary: IDENTICAL ✓"
  else
    echo "  ELF binary: DIFFERENT ✗"
    ls -la "$TMP/elf_a" "$TMP/elf_b"
    ok=1
  fi
  return $ok
}

# ---------------------------------------------------------------------------
# Mode 1: bootstrap determinism (always)
# ---------------------------------------------------------------------------
echo "=== Selfhost loop: bootstrap determinism (buxc × 2) ==="
echo "--- Build A (bootstrap) ---"
prepare_tree "$A"
(cd "$A" && "$ROOT/$OUT" build)
echo "--- Build B (bootstrap) ---"
prepare_tree "$B"
(cd "$B" && "$ROOT/$OUT" build)

if ! compare_c_and_elf \
  "A" "$A/build/buxc2" "$A/build/main.c" \
  "B" "$B/build/buxc2" "$B/build/main.c"
then
  echo "=== Selfhost loop FAILED (bootstrap determinism) ==="
  exit 1
fi
echo "=== Bootstrap determinism PASSED ==="

# ---------------------------------------------------------------------------
# Mode 2: fixed-point buxc2 → buxc3 (optional)
# ---------------------------------------------------------------------------
if [[ "${BUX_SELFHOST_FIXED_POINT:-0}" != "1" ]]; then
  echo ""
  echo "Note: fixed-point buxc2→buxc3 skipped (set BUX_SELFHOST_FIXED_POINT=1 to run)."
  echo "=== Selfhost loop PASSED ==="
  exit 0
fi

echo ""
echo "=== Fixed-point: buxc2 → buxc3 (experimental) ==="
BUXC2="$A/build/buxc2"
if [[ ! -x "$BUXC2" ]]; then
  echo "error: buxc2 missing at $BUXC2" >&2
  exit 1
fi

# Rebuild B with buxc2
prepare_tree "$B"
set +e
(cd "$B" && "$BUXC2" build)
fp_status=$?
set -e
if [[ $fp_status -ne 0 ]]; then
  echo "=== Fixed-point FAILED (buxc2 could not build gen2) ==="
  exit 1
fi

BUXC3="$B/build/buxc2"
if [[ ! -x "$BUXC3" ]]; then
  echo "error: gen2 binary missing" >&2
  exit 1
fi

if ! compare_c_and_elf \
  "buxc2" "$BUXC2" "$A/build/main.c" \
  "buxc3" "$BUXC3" "$B/build/main.c"
then
  echo "=== Fixed-point FAILED (gen1 vs gen2 mismatch) ==="
  exit 1
fi

echo "=== Selfhost loop PASSED (determinism + fixed-point) ==="
