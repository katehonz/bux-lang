#!/usr/bin/env bash
# Golden-ish smoke: field-move + partial field-move Drop emission.
# Ensures C for TakeItems has no Bag_Drop (would double-free returned Array).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUXC="${BUXC:-$ROOT/buxc}"
export BUX_STDLIB="${BUX_STDLIB:-$ROOT/lib}"
unset BUX_DEBUG_FILE || true

if [[ ! -x "$BUXC" ]]; then
  (cd "$ROOT" && make build)
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- move_field (whole local into field) ---
echo "=== smoke: move_field ==="
mkdir -p "$TMP/mf/src"
cp -a "$ROOT/rt" "$TMP/mf/"
cat > "$TMP/mf/bux.toml" <<'EOF'
[Package]
Name    = "move_field"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
EOF
cp "$ROOT/examples/move_field.bux" "$TMP/mf/src/Main.bux"
(cd "$TMP/mf" && "$BUXC" run .)
# Only the MakeBox *body* (not prototypes / other functions)
if sed -n '/^Box MakeBox(void) {/,/^}/p' "$TMP/mf/build/main.c" | grep -q 'Array_Drop\|Bag_Drop'; then
  echo "error: MakeBox still drops moved Array" >&2
  sed -n '/^Box MakeBox(void) {/,/^}/p' "$TMP/mf/build/main.c"
  exit 1
fi
echo "  move_field: PASS (run + no Array_Drop of moved local)"

# --- partial field move ---
echo "=== smoke: move_field_partial ==="
mkdir -p "$TMP/mp/src"
cp -a "$ROOT/rt" "$TMP/mp/"
cat > "$TMP/mp/bux.toml" <<'EOF'
[Package]
Name    = "move_field_partial"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
EOF
cp "$ROOT/examples/move_field_partial.bux" "$TMP/mp/src/Main.bux"
(cd "$TMP/mp" && "$BUXC" run .)
# TakeItems must not call Bag_Drop after moving bag.items out
if sed -n '/^Array_int TakeItems/,/^}/p' "$TMP/mp/build/main.c" | grep -q 'Bag_Drop'; then
  echo "error: TakeItems still Bag_Drops after partial field move" >&2
  sed -n '/^Array_int TakeItems/,/^}/p' "$TMP/mp/build/main.c"
  exit 1
fi
# PeekTagAndTake must Drop the moved-out Array after Array_Len mono (defer restore)
if ! sed -n '/^int PeekTagAndTake/,/^}/p' "$TMP/mp/build/main.c" | grep -q 'Array_Drop'; then
  echo "error: PeekTagAndTake missing Array_Drop for moved local (defer restore?)" >&2
  sed -n '/^int PeekTagAndTake/,/^}/p' "$TMP/mp/build/main.c"
  exit 1
fi
echo "  move_field_partial: PASS (run + TakeItems has no Bag_Drop + PeekTag drops moved)"

# --- remaining field Drop after partial move ---
echo "=== smoke: move_field_remaining ==="
mkdir -p "$TMP/mr/src"
cp -a "$ROOT/rt" "$TMP/mr/"
cat > "$TMP/mr/bux.toml" <<'EOF'
[Package]
Name    = "move_field_remaining"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
EOF
cp "$ROOT/examples/move_field_remaining.bux" "$TMP/mr/src/Main.bux"
(cd "$TMP/mr" && "$BUXC" run .)
# TakeLeft must not PairBag_Drop, but must Tracked_Drop remaining right field
if sed -n '/^Array_int TakeLeft/,/^}/p' "$TMP/mr/build/main.c" | grep -q 'PairBag_Drop'; then
  echo "error: TakeLeft still PairBag_Drops after partial field move" >&2
  sed -n '/^Array_int TakeLeft/,/^}/p' "$TMP/mr/build/main.c"
  exit 1
fi
if ! sed -n '/^Array_int TakeLeft/,/^}/p' "$TMP/mr/build/main.c" | grep -q 'Tracked_Drop'; then
  echo "error: TakeLeft missing Tracked_Drop for remaining field" >&2
  sed -n '/^Array_int TakeLeft/,/^}/p' "$TMP/mr/build/main.c"
  exit 1
fi
echo "  move_field_remaining: PASS (run + no PairBag_Drop + Tracked_Drop on right)"

# --- nested path move outer.inner.items ---
echo "=== smoke: move_field_nested ==="
mkdir -p "$TMP/mn/src"
cp -a "$ROOT/rt" "$TMP/mn/"
cat > "$TMP/mn/bux.toml" <<'EOF'
[Package]
Name    = "move_field_nested"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
EOF
cp "$ROOT/examples/move_field_nested.bux" "$TMP/mn/src/Main.bux"
(cd "$TMP/mn" && "$BUXC" run .)
# TakeNestedItems: no Outer_Drop; must Tracked_Drop remaining note + tag
if sed -n '/^Array_int TakeNestedItems/,/^}/p' "$TMP/mn/build/main.c" | grep -q 'Outer_Drop'; then
  echo "error: TakeNestedItems still Outer_Drops after nested path move" >&2
  sed -n '/^Array_int TakeNestedItems/,/^}/p' "$TMP/mn/build/main.c"
  exit 1
fi
tdrops=$(sed -n '/^Array_int TakeNestedItems/,/^}/p' "$TMP/mn/build/main.c" | grep -c 'Tracked_Drop' || true)
if [[ "${tdrops:-0}" -lt 2 ]]; then
  echo "error: TakeNestedItems expected ≥2 Tracked_Drop (inner.note + tag), got $tdrops" >&2
  sed -n '/^Array_int TakeNestedItems/,/^}/p' "$TMP/mn/build/main.c"
  exit 1
fi
echo "  move_field_nested: PASS (run + no Outer_Drop + Tracked_Drop remaining)"

# --- pointer field move p.items / (*p).items ---
echo "=== smoke: move_field_ptr ==="
mkdir -p "$TMP/mptr/src"
cp -a "$ROOT/rt" "$TMP/mptr/"
cat > "$TMP/mptr/bux.toml" <<'EOF'
[Package]
Name    = "move_field_ptr"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
EOF
cp "$ROOT/examples/move_field_ptr.bux" "$TMP/mptr/src/Main.bux"
(cd "$TMP/mptr" && "$BUXC" run .)
if sed -n '/^Array_int TakeViaPtr/,/^}/p' "$TMP/mptr/build/main.c" | grep -q 'Bag_Drop'; then
  echo "error: TakeViaPtr still Bag_Drops after p.items move" >&2
  sed -n '/^Array_int TakeViaPtr/,/^}/p' "$TMP/mptr/build/main.c"
  exit 1
fi
if ! sed -n '/^Array_int TakeViaPtr/,/^}/p' "$TMP/mptr/build/main.c" | grep -q 'Tracked_Drop'; then
  echo "error: TakeViaPtr missing Tracked_Drop for remaining tag" >&2
  sed -n '/^Array_int TakeViaPtr/,/^}/p' "$TMP/mptr/build/main.c"
  exit 1
fi
echo "  move_field_ptr: PASS (run + no Bag_Drop + Tracked_Drop remaining)"

# --- cross-function pointer ownership TakeItems(&bag) ---
echo "=== smoke: move_cross_fn ==="
mkdir -p "$TMP/mcf/src"
cp -a "$ROOT/rt" "$TMP/mcf/"
cat > "$TMP/mcf/bux.toml" <<'EOF'
[Package]
Name    = "move_cross_fn"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
EOF
cp "$ROOT/examples/move_cross_fn.bux" "$TMP/mcf/src/Main.bux"
out=$(cd "$TMP/mcf" && "$BUXC" run .)
echo "$out" | grep -q 'cross_fn_drops=2'
echo "$out" | grep -q 'PASS'
# CallTakeItems must Tracked_Drop remaining tag, not Bag_Drop (would free moved items)
if sed -n '/^int CallTakeItems/,/^}/p' "$TMP/mcf/build/main.c" | grep -q 'Bag_Drop'; then
  echo "error: CallTakeItems still Bag_Drops after TakeItems(&bag)" >&2
  sed -n '/^int CallTakeItems/,/^}/p' "$TMP/mcf/build/main.c"
  exit 1
fi
if ! sed -n '/^int CallTakeItems/,/^}/p' "$TMP/mcf/build/main.c" | grep -q 'Tracked_Drop'; then
  echo "error: CallTakeItems missing Tracked_Drop for remaining tag" >&2
  sed -n '/^int CallTakeItems/,/^}/p' "$TMP/mcf/build/main.c"
  exit 1
fi
echo "  move_cross_fn: PASS (run + no Bag_Drop + Tracked_Drop remaining)"

# --- early return Drop counts ---
echo "=== smoke: drop_early_return ==="
mkdir -p "$TMP/de/src"
cp -a "$ROOT/rt" "$TMP/de/"
cat > "$TMP/de/bux.toml" <<'EOF'
[Package]
Name    = "drop_early_return"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
EOF
cp "$ROOT/examples/drop_early_return.bux" "$TMP/de/src/Main.bux"
out=$(cd "$TMP/de" && "$BUXC" run .)
echo "$out" | grep -q 'PASS'
echo "  drop_early_return: PASS"

echo "PASS: smoke_drop_move (field-move + partial + remaining + nested + ptr + cross-fn + early-return)"
