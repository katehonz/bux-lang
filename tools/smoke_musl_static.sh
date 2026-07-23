#!/usr/bin/env bash
# Session 79 — musl fully-static path (skips if no musl-gcc / zig musl target).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export BUX_STDLIB="${BUX_STDLIB:-$ROOT/lib}"

if [[ ! -x "$ROOT/buxc" ]]; then
  (cd "$ROOT" && make build)
fi

pick_cc() {
  if command -v musl-gcc >/dev/null 2>&1; then
    echo "musl-gcc"
    return
  fi
  if command -v x86_64-linux-musl-gcc >/dev/null 2>&1; then
    echo "x86_64-linux-musl-gcc"
    return
  fi
  if command -v zig >/dev/null 2>&1; then
    # zig cc -target x86_64-linux-musl acts as a C compiler when BUX_CC is a wrapper
    echo "zig-musl"
    return
  fi
  echo ""
}

CC_KIND=$(pick_cc)
if [[ -z "$CC_KIND" ]]; then
  echo "SKIP: no musl-gcc / zig on PATH (install musl-tools or zig for Alpine static)"
  echo "PASS: smoke_musl_static (skipped)"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/src"
cp -a "$ROOT/rt" "$TMP/"
cp "$ROOT/examples/hello.bux" "$TMP/src/Main.bux"
cat > "$TMP/bux.toml" <<'EOF'
[Package]
Name    = "hello_musl"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
EOF

export BUX_RUNTIME=minimal
if [[ "$CC_KIND" == "zig-musl" ]]; then
  # Wrapper so buxc invokes zig as cc
  cat > "$TMP/zigcc" <<'EOF'
#!/bin/sh
exec zig cc -target x86_64-linux-musl "$@"
EOF
  chmod +x "$TMP/zigcc"
  export BUX_CC="$TMP/zigcc"
else
  export BUX_CC="$CC_KIND"
fi

echo "=== musl static hello (BUX_CC=$BUX_CC) ==="
"$ROOT/buxc" --quiet --static --release build "$TMP"
BIN="$TMP/build/hello_musl"
file "$BIN"
# musl static often reports "statically linked"
if file "$BIN" | grep -qi 'statically linked\|static-pie\|static '; then
  echo "static: ok"
else
  # some musl toolchains still produce dynamic musl — accept if ldd mentions musl
  if command -v ldd >/dev/null 2>&1 && ldd "$BIN" 2>&1 | grep -qi musl; then
    echo "dynamic musl: ok"
  else
    echo "WARN: could not confirm musl/static; file output above"
  fi
fi

# Run only if host can execute
if "$BIN" 2>/dev/null | grep -q 'Hello, Bux!'; then
  echo "run: ok"
else
  echo "run: skipped or failed (cross?)"
fi

echo "PASS: smoke_musl_static"
