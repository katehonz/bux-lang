#!/usr/bin/env bash
# Session 75 — Linux / cloud / embedded smoke:
#   1) BUX_RUNTIME=minimal  (thin runtime, run hello)
#   2) --static --release   (fully-static binary, file(1) check)
#   3) --target aarch64-linux-gnu (cross build if toolchain present)
#   4) CTFE CRC example under minimal runtime
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export BUX_STDLIB="${BUX_STDLIB:-$ROOT/lib}"
unset BUX_DEBUG_FILE || true
unset BUX_RUNTIME || true
unset BUX_STATIC || true
unset BUX_CC || true

if [[ -x "$ROOT/buxc" ]]; then
  BUXC="$ROOT/buxc"
else
  (cd "$ROOT" && make build)
  BUXC="$ROOT/buxc"
fi

mkpkg() {
  local name="$1" src="$2"
  local d
  d=$(mktemp -d)
  mkdir -p "$d/src"
  cp -a "$ROOT/rt" "$d/"
  cat > "$d/bux.toml" <<EOF
[Package]
Name    = "$name"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
EOF
  cp "$src" "$d/src/Main.bux"
  echo "$d"
}

pass=0
fail=0
note() { echo "=== $* ==="; }

# ── 1) minimal runtime ──────────────────────────────────────────────────
note "minimal runtime (BUX_RUNTIME=minimal)"
PKG=$(mkpkg hello_min "$ROOT/examples/hello.bux")
trap 'rm -rf "$PKG" "${PKG2:-}" "${PKG3:-}" "${PKG4:-}"' EXIT
export BUX_RUNTIME=minimal
out=$("$BUXC" --quiet run "$PKG" 2>&1) || { echo "$out" >&2; exit 1; }
echo "$out" | grep -q 'Hello, Bux!'
grep -q 'minimal / embedded / static' "$PKG/build/runtime.c"
# must not pull full POSIX
if grep -q 'openssl/evp\|pthread.h' "$PKG/build/runtime.c"; then
  echo "error: minimal runtime still has pthread/openssl includes" >&2
  exit 1
fi
echo "PASS: minimal runtime"
pass=$((pass+1))
unset BUX_RUNTIME

# ── 2) fully-static (thin runtime implied) ──────────────────────────────
note "static link (--static --release)"
PKG2=$(mkpkg hello_static "$ROOT/examples/hello.bux")
out=$("$BUXC" --quiet --static --release build "$PKG2" 2>&1) || { echo "$out" >&2; exit 1; }
BIN="$PKG2/build/hello_static"
[[ -x "$BIN" ]] || BIN="$PKG2/build/hello_static.exe"
file_out=$(file "$BIN")
echo "$file_out"
echo "$file_out" | grep -qi 'statically linked\|static-pie\|static '
# run only if host arch matches
if echo "$file_out" | grep -qi 'x86-64\|x86_64\|Intel 80386'; then
  run_out=$("$BIN" 2>&1) || { echo "$run_out" >&2; exit 1; }
  echo "$run_out" | grep -q 'Hello, Bux!'
fi
grep -q 'minimal / embedded / static' "$PKG2/build/runtime.c"
echo "PASS: static link"
pass=$((pass+1))

# ── 3) cross aarch64 (optional toolchain) ───────────────────────────────
note "cross aarch64-linux-gnu"
PKG3=$(mkpkg hello_arm "$ROOT/examples/hello.bux")
if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
  out=$("$BUXC" --quiet --static --release --target aarch64-linux-gnu build "$PKG3" 2>&1) || {
    echo "$out" >&2
    exit 1
  }
  BIN3="$PKG3/build/hello_arm"
  [[ -x "$BIN3" ]] || BIN3="$PKG3/build/hello_arm.exe"
  file_out=$(file "$BIN3")
  echo "$file_out"
  echo "$file_out" | grep -qi 'ARM aarch64\|aarch64'
  echo "$file_out" | grep -qi 'statically linked\|static-pie\|static '
  echo "PASS: cross aarch64"
  pass=$((pass+1))
else
  echo "SKIP: aarch64-linux-gnu-gcc not on PATH"
fi

# ── 4) CTFE CRC under minimal runtime ───────────────────────────────────
note "ctfe_crc (minimal)"
if [[ -f "$ROOT/examples/ctfe_crc.bux" ]]; then
  PKG4=$(mkpkg ctfe_crc "$ROOT/examples/ctfe_crc.bux")
  export BUX_RUNTIME=minimal
  out=$("$BUXC" --quiet run "$PKG4" 2>&1) || { echo "$out" >&2; exit 1; }
  echo "$out"
  echo "$out" | grep -q 'PASS ctfe_crc'
  echo "PASS: ctfe_crc"
  pass=$((pass+1))
  unset BUX_RUNTIME
else
  echo "SKIP: examples/ctfe_crc.bux missing"
fi

echo ""
echo "smoke_linux_targets: $pass checks passed"
echo "PASS: smoke_linux_targets"
