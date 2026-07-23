#!/usr/bin/env bash
# Build examples/http_health.bux → build/http_health for container packaging.
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
Name    = "http_health"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
EOF
cp "$ROOT/examples/http_health.bux" "$PKG/src/Main.bux"

"$ROOT/buxc" --quiet --release build "$PKG"
cp "$PKG/build/http_health" "$OUT_DIR/http_health"
file "$OUT_DIR/http_health"
echo "wrote $OUT_DIR/http_health"
echo "docker: docker build -f examples/docker/Dockerfile.health -t bux-health $ROOT"
