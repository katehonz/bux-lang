#!/usr/bin/env bash
# Smoke: registry search + add + install + lock reproducibility + HTTPS (E.1 / session 79)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUXC="$ROOT/buxc"
export BUX_REGISTRY="$ROOT/config/registry.toml"

if [[ ! -x "$BUXC" ]]; then
  (cd "$ROOT" && make build >/dev/null)
fi

TMP=$(mktemp -d)
HTTP_PID=""
HTTPS_PID=""
cleanup() {
  if [[ -n "$HTTP_PID" ]]; then
    kill "$HTTP_PID" 2>/dev/null || true
    wait "$HTTP_PID" 2>/dev/null || true
  fi
  if [[ -n "$HTTPS_PID" ]]; then
    kill "$HTTPS_PID" 2>/dev/null || true
    wait "$HTTPS_PID" 2>/dev/null || true
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

echo "=== bux install (with checksum) ==="
"$BUXC" install
test -f bux.lock
grep -q greet bux.lock
grep -q Checksum bux.lock
cat bux.lock
cp bux.lock "$TMP/lock1"

echo "=== lock reproducibility (second install) ==="
"$BUXC" install
# Source path + version + checksum must match
diff -u "$TMP/lock1" bux.lock

echo "=== bux install --locked ==="
"$BUXC" install --locked

echo "=== install --locked fails without lock ==="
rm -f bux.lock
if "$BUXC" install --locked 2>"$TMP/locked_err"; then
  echo "error: expected --locked to fail without lock" >&2
  exit 1
fi
grep -qi 'missing\|locked' "$TMP/locked_err"
"$BUXC" install
test -f bux.lock

echo "=== checksum mismatch detected ==="
# Corrupt checksum
python3 - <<'PY'
from pathlib import Path
p = Path("bux.lock")
t = p.read_text()
# flip last hex nibble of Checksum line if present
lines = []
for line in t.splitlines():
    if line.startswith("Checksum"):
        # Checksum = "abcdef..."
        import re
        m = re.search(r'"([0-9a-fA-F]+)"', line)
        if m:
            h = m.group(1)
            h2 = h[:-1] + ("0" if h[-1] != "0" else "1")
            line = f'Checksum = "{h2}"'
    lines.append(line)
p.write_text("\n".join(lines) + "\n")
PY
if "$BUXC" install --locked 2>"$TMP/csum_err"; then
  echo "error: expected checksum mismatch failure" >&2
  exit 1
fi
grep -qi 'checksum' "$TMP/csum_err"
# restore good lock
"$BUXC" install >/dev/null

echo "=== bux run ==="
"$BUXC" run . | tee "$TMP/run.out"
grep -q "Hello, Bux!" "$TMP/run.out"

# --- HTTP registry index ---
echo "=== HTTP registry index ==="
mkdir -p "$TMP/http"
cat > "$TMP/http/registry.toml" <<EOF
[[package]]
name = "greet"
version = "0.1.1"
source = "file:$ROOT/registry/packages/greet"
description = "HTTP-served greet package"
EOF

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
(
  cd "$TMP/http"
  python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1
) &
HTTP_PID=$!
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
unset BUX_REGISTRY_REFRESH
"$BUXC" search greet | grep -q greet

# --- HTTPS registry (self-signed) ---
echo "=== HTTPS registry index (self-signed + BUX_REGISTRY_INSECURE) ==="
mkdir -p "$TMP/https"
cp "$TMP/http/registry.toml" "$TMP/https/registry.toml"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/https/key.pem" -out "$TMP/https/cert.pem" \
  -days 1 -subj "/CN=localhost" 2>/dev/null

SPORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 - <<PY &
import http.server, ssl, os
os.chdir("$TMP/https")
httpd = http.server.HTTPServer(("127.0.0.1", $SPORT), http.server.SimpleHTTPRequestHandler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain("$TMP/https/cert.pem", "$TMP/https/key.pem")
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
PY
HTTPS_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if curl -kfsS "https://127.0.0.1:${SPORT}/registry.toml" >/dev/null 2>&1; then
    break
  fi
  sleep 0.15
done

export BUX_REGISTRY="https://127.0.0.1:${SPORT}/registry.toml"
export BUX_REGISTRY_REFRESH=1
export BUX_REGISTRY_INSECURE=1
"$BUXC" search greet | tee "$TMP/https_search.out"
grep -q greet "$TMP/https_search.out"
grep -q "https://" "$TMP/https_search.out" || grep -q "cached" "$TMP/https_search.out"
unset BUX_REGISTRY_INSECURE
unset BUX_REGISTRY_REFRESH
unset BUX_REGISTRY

echo "PASS: registry smoke (local + lock/checksum + locked + HTTP + HTTPS)"
