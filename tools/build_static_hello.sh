#!/usr/bin/env bash
# Build a fully-static hello binary for container / distroless demos (session 75).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export BUX_STDLIB="${BUX_STDLIB:-$ROOT/lib}"
OUT_DIR="${1:-$ROOT/build}"
mkdir -p "$OUT_DIR"

if [[ ! -x "$ROOT/buxc" ]]; then
  (cd "$ROOT" && make build)
fi

PKG=$(mktemp -d)
trap 'rm -rf "$PKG"' EXIT
mkdir -p "$PKG/src"
cp -a "$ROOT/rt" "$PKG/"
cat > "$PKG/bux.toml" <<'EOF'
[Package]
Name    = "hello_static"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
EOF
cp "$ROOT/examples/hello.bux" "$PKG/src/Main.bux"

"$ROOT/buxc" --quiet --static --release build "$PKG"
cp "$PKG/build/hello_static" "$OUT_DIR/hello_static"
file "$OUT_DIR/hello_static"
echo "wrote $OUT_DIR/hello_static"
echo "docker: docker build -f examples/docker/Dockerfile.static --build-arg BIN=$OUT_DIR/hello_static -t bux-hello-static $ROOT"
