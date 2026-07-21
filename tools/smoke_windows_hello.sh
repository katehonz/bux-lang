#!/usr/bin/env bash
# Session 71 — Windows / MinGW hello smoke (also testable on Unix via BUX_RUNTIME=win).
# Builds examples/hello.bux with the minimal runtime and checks stdout.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export BUX_STDLIB="${BUX_STDLIB:-$ROOT/lib}"
unset BUX_DEBUG_FILE || true

# Prefer buxc.exe on Windows, else buxc
if [[ -x "$ROOT/buxc.exe" ]]; then
  BUXC="$ROOT/buxc.exe"
elif [[ -x "$ROOT/buxc" ]]; then
  BUXC="$ROOT/buxc"
else
  (cd "$ROOT" && make build)
  if [[ -x "$ROOT/buxc.exe" ]]; then BUXC="$ROOT/buxc.exe"
  else BUXC="$ROOT/buxc"
  fi
fi

# Force minimal runtime when not already on Windows (Linux/macOS local check)
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT) ;;
  *)
    export BUX_RUNTIME="${BUX_RUNTIME:-win}"
    ;;
esac

if ! command -v gcc >/dev/null 2>&1 && ! command -v cc >/dev/null 2>&1; then
  echo "error: need gcc/cc on PATH (MinGW on Windows)" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/src"
cp -a "$ROOT/rt" "$TMP/"
cat > "$TMP/bux.toml" <<'EOF'
[Package]
Name    = "hello"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
EOF
cp "$ROOT/examples/hello.bux" "$TMP/src/Main.bux"

echo "=== smoke_windows_hello: build+run ==="
out=$("$BUXC" run "$TMP" 2>&1) || {
  echo "$out" >&2
  exit 1
}
echo "$out"
echo "$out" | grep -q 'Hello, Bux!'

# Confirm minimal runtime was used when forced / on Windows
if [[ -f "$TMP/build/runtime.c" ]]; then
  if ! grep -q 'Windows / MinGW minimal' "$TMP/build/runtime.c"; then
    # On native Windows the CLI always copies runtime_win.c content into runtime.c
    if grep -q 'pthread\|openssl/evp' "$TMP/build/runtime.c"; then
      echo "error: expected runtime_win.c content, found full POSIX runtime" >&2
      exit 1
    fi
  fi
fi

echo "PASS: smoke_windows_hello"
