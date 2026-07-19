#!/usr/bin/env bash
# Smoke: DWARF / #line maps for debugger (E.4)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUXC="$ROOT/buxc"

if [[ ! -x "$BUXC" ]]; then
  (cd "$ROOT" && make build >/dev/null)
fi

PKG="$ROOT/examples_pkg/hello"
mkdir -p "$PKG/src"
cp "$ROOT/examples/hello.bux" "$PKG/src/Main.bux"
if [[ ! -f "$PKG/bux.toml" ]]; then
  cat > "$PKG/bux.toml" <<'EOF'
[Package]
Name    = "hello"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
EOF
fi

echo "=== debug build (default -O0 -g + #line) ==="
"$BUXC" build "$PKG"
MAIN_C="$PKG/build/main.c"
BIN="$PKG/build/hello"
test -f "$MAIN_C"
test -x "$BIN"

# Expect #line pointing at .bux sources (user or stdlib)
if ! grep -qE '^#line [0-9]+ ".*\.bux"' "$MAIN_C"; then
  echo "error: no #line …\".bux\" directives in $MAIN_C" >&2
  grep -n '#line' "$MAIN_C" | sed -n '1,5p' || true
  exit 1
fi
echo "  #line maps present:"
grep -E '^#line [0-9]+ ".*\.bux"' "$MAIN_C" | sed -n '1,5p' || true
# User Main should map back to the package Main.bux
if ! grep -qE '^#line [0-9]+ ".*Main\.bux"' "$MAIN_C"; then
  echo "error: no #line for user Main.bux" >&2
  exit 1
fi
echo "  user Main.bux #line present"

# DWARF sections
if command -v readelf >/dev/null 2>&1; then
  if ! readelf -S "$BIN" | grep -q '\.debug_info'; then
    echo "error: no .debug_info in $BIN" >&2
    exit 1
  fi
  echo "  .debug_info present"
  if readelf -p .debug_str "$BIN" 2>/dev/null | grep -q '\.bux'; then
    echo "  .debug_str contains .bux paths"
  else
    echo "  (note: .debug_str may omit .bux; line tables still OK)"
  fi
fi

# gdb: list Main
if command -v gdb >/dev/null 2>&1; then
  echo "=== gdb list Main ==="
  set +e
  gdb -batch -ex "file $BIN" -ex "list Main" 2>/dev/null | sed -n '1,20p'
  set -e
fi

echo "=== release build (no #line, no -g required) ==="
"$BUXC" build --release "$PKG"
if grep -qE '^#line ' "$MAIN_C"; then
  echo "error: release build still has #line" >&2
  exit 1
fi
echo "  release: no #line (OK)"
if command -v readelf >/dev/null 2>&1; then
  if readelf -S "$BIN" | grep -q '\.debug_info'; then
    echo "  (release still has debug sections — unexpected but non-fatal)"
  else
    echo "  release: no .debug_info (OK)"
  fi
fi

# Rebuild debug so leftover state is debug-friendly for other tests
"$BUXC" build "$PKG" >/dev/null

echo "PASS: dwarf smoke (#line + .debug_info + --release)"
