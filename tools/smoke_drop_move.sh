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
echo "  move_field_partial: PASS (run + TakeItems has no Bag_Drop)"

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

echo "PASS: smoke_drop_move (field-move + partial + early-return)"
