#!/usr/bin/env bash
# Smoke: call hierarchy prepare / incoming / outgoing (bux-lsp 0.8)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LSP="$ROOT/tools/bux-lsp"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$LSP" ]]; then
  (cd "$ROOT" && make lsp >/dev/null)
fi

cat > "$TMP/Main.bux" <<'EOF'
func Add(a: int, b: int) -> int {
    return a + b;
}
func Mul(a: int, b: int) -> int {
    return a * b;
}
func Compute(n: int) -> int {
    let s: int = Add(n, 1);
    let p: int = Mul(s, 2);
    return Add(p, s);
}
func Main() -> int {
    return Compute(3);
}
EOF

rpc() {
  local body="$1"
  local len
  len=$(printf '%s' "$body" | wc -c)
  printf 'Content-Length: %s\r\n\r\n%s' "$len" "$body"
}

CONTENT_JSON=$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$TMP/Main.bux")
URI="file://$TMP/Main.bux"

# Prepare on Add (line 0, character 5)
# Incoming for Add — expect Compute
# Outgoing for Compute — expect Add and Mul
{
  rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"rootUri":"file://'"$TMP"'"}}'
  rpc '{"jsonrpc":"2.0","method":"initialized","params":{}}'
  rpc '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$URI"'","languageId":"bux","version":1,"text":'"$CONTENT_JSON"'}}}'
  rpc '{"jsonrpc":"2.0","id":2,"method":"textDocument/prepareCallHierarchy","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":0,"character":5}}}'
  # incomingCalls — item for Add from prepare (we construct manually)
  rpc '{"jsonrpc":"2.0","id":3,"method":"callHierarchy/incomingCalls","params":{"item":{"name":"Add","kind":12,"uri":"'"$URI"'","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":8}},"selectionRange":{"start":{"line":0,"character":5},"end":{"line":0,"character":8}}}}}'
  rpc '{"jsonrpc":"2.0","id":4,"method":"callHierarchy/outgoingCalls","params":{"item":{"name":"Compute","kind":12,"uri":"'"$URI"'","range":{"start":{"line":6,"character":0},"end":{"line":6,"character":12}},"selectionRange":{"start":{"line":6,"character":5},"end":{"line":6,"character":12}}}}}'
  rpc '{"jsonrpc":"2.0","id":5,"method":"shutdown","params":null}'
  rpc '{"jsonrpc":"2.0","method":"exit","params":null}'
} | "$LSP" 2>/dev/null | tr '\r' '\n' > "$TMP/out.txt"

if ! grep -q 'callHierarchyProvider' "$TMP/out.txt"; then
  echo "FAIL: missing callHierarchyProvider"
  cat "$TMP/out.txt"
  exit 1
fi
if ! grep -qE '0\.(8|9|10|11)\.0' "$TMP/out.txt"; then
  echo "WARN: unexpected bux-lsp version"
fi

# prepare should mention Add
if ! grep -q '"name":"Add"' "$TMP/out.txt"; then
  echo "FAIL: prepareCallHierarchy did not return Add"
  cat "$TMP/out.txt"
  exit 1
fi

# incoming: Compute calls Add
if ! grep -q '"name":"Compute"' "$TMP/out.txt"; then
  echo "FAIL: incomingCalls missing Compute"
  cat "$TMP/out.txt"
  exit 1
fi

# outgoing from Compute: Add and Mul
if ! grep -q '"name":"Mul"' "$TMP/out.txt"; then
  echo "FAIL: outgoingCalls missing Mul"
  cat "$TMP/out.txt"
  exit 1
fi

# fromRanges present
if ! grep -q 'fromRanges' "$TMP/out.txt"; then
  echo "FAIL: missing fromRanges"
  exit 1
fi

echo "PASS: LSP call hierarchy (prepare + incoming + outgoing)"
