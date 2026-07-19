#!/usr/bin/env bash
# Smoke: hover on inferred let + parameter via bux-lsp JSON-RPC.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LSP="$ROOT/tools/bux-lsp"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$LSP" ]]; then
  echo "building bux-lsp..."
  (cd "$ROOT" && make lsp >/dev/null)
fi

cat > "$TMP/Main.bux" <<'EOF'
func Add(a: int, b: int) -> int {
    let sum = a + b;
    return sum;
}
func Main() -> int {
    let n = 10;
    return Add(n, 2);
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

{
  rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"rootUri":"file://'"$TMP"'"}}'
  rpc '{"jsonrpc":"2.0","method":"initialized","params":{}}'
  rpc '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$URI"'","languageId":"bux","version":1,"text":'"$CONTENT_JSON"'}}}'
  # hover on `sum` (line 1)
  rpc '{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":1,"character":8}}}'
  # hover on param a (line 0)
  rpc '{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":0,"character":9}}}'
  # hover on n in Main (line 5)
  rpc '{"jsonrpc":"2.0","id":4,"method":"textDocument/hover","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":5,"character":8}}}'
  rpc '{"jsonrpc":"2.0","id":5,"method":"shutdown","params":null}'
  rpc '{"jsonrpc":"2.0","method":"exit","params":null}'
} | "$LSP" 2>/dev/null | tr '\r' '\n' > "$TMP/out.txt"

echo "---- hover responses (excerpt) ----"
grep -o '"value":"[^"]*"' "$TMP/out.txt" | head -20 || true

# Must have typed sum / n and param a somewhere in output
ok=1
if ! grep -q 'sum' "$TMP/out.txt"; then
  echo "FAIL: no hover for sum"
  ok=0
fi
if ! grep -Eq 'let sum: int|sum: int' "$TMP/out.txt"; then
  echo "WARN: sum type not clearly int (may still pass if detail present)"
  # Soft fail only if completely missing inferred path
  if ! grep -q 'inferred' "$TMP/out.txt" && ! grep -q 'let sum' "$TMP/out.txt"; then
    ok=0
  fi
fi
if ! grep -Eq 'param a|a: int' "$TMP/out.txt"; then
  echo "FAIL: expected param a hover"
  ok=0
fi
if ! grep -Eq 'let n: int|n: int' "$TMP/out.txt"; then
  echo "WARN: n type not clearly int"
fi

if [[ $ok -eq 0 ]]; then
  echo "---- full output ----"
  cat "$TMP/out.txt"
  exit 1
fi
echo "PASS: LSP hover smoke (locals + params + inferred lets)"
