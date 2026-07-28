#!/usr/bin/env bash
# Smoke: freestanding runtime compiles under -ffreestanding; optional package build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RT="$ROOT/rt/runtime_freestanding.c"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ ! -f "$RT" ]]; then
  echo "FAIL: missing $RT"
  exit 1
fi

CC="${BUX_CC:-cc}"

echo "=== freestanding: -ffreestanding -c runtime ==="
"$CC" -ffreestanding -std=c11 -Wall -Wextra -c "$RT" -o "$TMP/rt_fs.o"
echo "PASS: runtime_freestanding.o"

echo "=== freestanding: BUX_RUNTIME=freestanding build hello-ish ==="
mkdir -p "$TMP/pkg/src"
cat > "$TMP/pkg/bux.toml" <<'EOF'
[Package]
Name = "fs_smoke"
Version = "0.1.0"
EOF
cat > "$TMP/pkg/src/Main.bux" <<'EOF'
func Main() -> int {
    return 42;
}
EOF

if [[ ! -x "$ROOT/buxc" ]]; then
  echo "building buxc..."
  (cd "$ROOT" && make build >/dev/null)
fi

# Hosted link still uses libc for crt0; runtime body is freestanding.
BUX_RUNTIME=freestanding "$ROOT/buxc" build "$TMP/pkg" --release >/dev/null
OUT="$TMP/pkg/build/fs_smoke"
if [[ ! -x "$OUT" ]]; then
  echo "FAIL: binary not produced"
  exit 1
fi
CODE=$("$OUT"; echo $?)
if [[ "$CODE" != "42" ]]; then
  echo "FAIL: expected exit 42, got $CODE"
  exit 1
fi
echo "PASS: freestanding runtime package exit 42"

# Optional: object-level nostdlib link experiment (may need extra crt — soft)
echo "=== freestanding: optional -ffreestanding object of Main.c ==="
# Generate C then compile Main only with freestanding flags
BUX_RUNTIME=freestanding "$ROOT/buxc" build "$TMP/pkg" --release >/dev/null
if [[ -f "$TMP/pkg/build/main.c" ]]; then
  if "$CC" -ffreestanding -std=c11 -c "$TMP/pkg/build/main.c" -o "$TMP/main_fs.o" 2>"$TMP/main_fs.err"; then
    echo "PASS: main.c compiles under -ffreestanding"
  else
    # Hosted headers in generated C may pull stdint — not a hard fail
    echo "SKIP: main.c -ffreestanding (generated C may need hosted headers)"
    head -5 "$TMP/main_fs.err" || true
  fi
fi

echo "PASS: freestanding smoke"
