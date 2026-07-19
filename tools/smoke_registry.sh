#!/usr/bin/env bash
# Smoke: registry search + add + install + build with greet package (E.1)
# Also verifies HTTP-fetchable registry index (E.1b).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUXC="$ROOT/buxc"
export BUX_REGISTRY="$ROOT/config/registry.toml"

if [[ ! -x "$BUXC" ]]; then
  (cd "$ROOT" && make build >/dev/null)
fi

TMP=$(mktemp -d)
HTTP_PID=""
cleanup() {
  if [[ -n "$HTTP_PID" ]]; then
    kill "$HTTP_PID" 2>/dev/null || true
    wait "$HTTP_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "=== bux search greet (local file) ==="
"$BUXC" search greet | tee "$TMP/search.out"
grep -q greet "$TMP/search.out"

echo "=== create consumer project ==="
mkdir -p "$TMP/app/src"
cat > "$TMP/app/bux.toml" <<'EOF'
[Package]
Name    = "registry_consumer"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
EOF

cat > "$TMP/app/src/Main.bux" <<'EOF'
import Std::Io::{PrintLine};
import Std::String::{String_Eq};
import Std::Test::{Test_AssertTrue, Test_Pass};

func Main() -> int {
    let msg: String = Greet_Hello("Bux");
    Test_AssertTrue(String_Eq(msg, "Hello, Bux!"));
    Test_AssertTrue(String_Eq(Greet_Version(), "0.1.1"));
    PrintLine(msg);
    Test_Pass("registry_consumer");
    return 0;
}
EOF

cd "$TMP/app"
export BUX_STDLIB="$ROOT/lib"

echo "=== bux add greet ==="
"$BUXC" add greet
grep -q greet bux.toml
cat bux.toml

echo "=== bux install ==="
"$BUXC" install
test -f bux.lock
grep -q greet bux.lock
cat bux.lock

echo "=== bux run ==="
"$BUXC" run . | tee "$TMP/run.out"
grep -q "Hello, Bux!" "$TMP/run.out"

# --- HTTP registry index ---
echo "=== HTTP registry index (E.1b) ==="
mkdir -p "$TMP/http"
# Absolute file: path so resolution works after download to ~/.bux/cache
cat > "$TMP/http/registry.toml" <<EOF
[[package]]
name = "greet"
version = "0.1.1"
source = "file:$ROOT/registry/packages/greet"
description = "HTTP-served greet package"
EOF

# Free port via python
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
(
  cd "$TMP/http"
  python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1
) &
HTTP_PID=$!
# Wait until server responds
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS "http://127.0.0.1:${PORT}/registry.toml" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

export BUX_REGISTRY="http://127.0.0.1:${PORT}/registry.toml"
export BUX_REGISTRY_REFRESH=1
"$BUXC" search greet | tee "$TMP/http_search.out"
grep -q greet "$TMP/http_search.out"
grep -q "http://127.0.0.1" "$TMP/http_search.out" || grep -q "cached" "$TMP/http_search.out"
unset BUX_REGISTRY_REFRESH
# Second search should hit cache without refresh
"$BUXC" search greet | grep -q greet

echo "PASS: registry smoke (local + HTTP search + add + install + build)"
