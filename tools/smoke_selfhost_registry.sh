#!/usr/bin/env bash
# Session 81 — selfhost registry: search / add by name / install / HTTP index
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export BUX_STDLIB="${BUX_STDLIB:-$ROOT/lib}"
export BUX_REGISTRY="$ROOT/config/registry.toml"

if [[ ! -x "$ROOT/build/selfhost/build/buxc2" ]]; then
  (cd "$ROOT" && make selfhost)
fi
BUXC2="$ROOT/build/selfhost/build/buxc2"

TMP=$(mktemp -d)
HTTP_PID=""
cleanup() {
  [[ -n "$HTTP_PID" ]] && kill "$HTTP_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "=== buxc2 search greet (local) ==="
"$BUXC2" search greet | tee "$TMP/s.out"
grep -q greet "$TMP/s.out"

echo "=== consumer + add greet (registry) ==="
mkdir -p "$TMP/app/src"
cat > "$TMP/app/bux.toml" <<'EOF'
[Package]
Name    = "reg_consumer"
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
    PrintLine(msg);
    Test_Pass("reg_consumer");
    return 0;
}
EOF

cd "$TMP/app"
"$BUXC2" add greet | tee "$TMP/add.out"
grep -q greet bux.toml
"$BUXC2" install .
test -f bux.lock
grep -q Checksum bux.lock
"$BUXC2" install --locked .

echo "=== buxc2 run with registry dep ==="
"$BUXC2" run . | tee "$TMP/run.out"
grep -q "Hello, Bux!" "$TMP/run.out"

echo "=== HTTP registry search ==="
mkdir -p "$TMP/http"
cat > "$TMP/http/registry.toml" <<EOF
[[package]]
name = "greet"
version = "0.1.1"
source = "file:$ROOT/registry/packages/greet"
description = "HTTP-served greet (selfhost)"
EOF
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$PORT" --bind 127.0.0.1 -d "$TMP/http" >/dev/null 2>&1 &
HTTP_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -fsS "http://127.0.0.1:${PORT}/registry.toml" >/dev/null 2>&1 && break
  sleep 0.1
done
export BUX_REGISTRY="http://127.0.0.1:${PORT}/registry.toml"
export BUX_REGISTRY_REFRESH=1
"$BUXC2" search greet | tee "$TMP/http.out"
grep -q greet "$TMP/http.out"
grep -q "http://" "$TMP/http.out" || grep -q cached "$TMP/http.out"

echo "PASS: smoke_selfhost_registry"
