#!/usr/bin/env bash
# Smoke: workspace/symbol (bux-lsp 0.6.0)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LSP="$ROOT/tools/bux-lsp"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$LSP" ]]; then
  (cd "$ROOT" && make lsp >/dev/null)
fi

mkdir -p "$TMP/src"
cat > "$TMP/src/Main.bux" <<'EOF'
func Helper() -> int { return 1; }
func Main() -> int {
    return Helper();
}
EOF
cat > "$TMP/src/Util.bux" <<'EOF'
func Util_Max(a: int, b: int) -> int {
    if a > b { return a; }
    return b;
}
EOF

rpc() {
  local body="$1"
  local len
  len=$(printf '%s' "$body" | wc -c)
  printf 'Content-Length: %s\r\n\r\n%s' "$len" "$body"
}

CONTENT_JSON=$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$TMP/src/Main.bux")
URI="file://$TMP/src/Main.bux"

{
  rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"rootUri":"file://'"$TMP"'"}}'
  rpc '{"jsonrpc":"2.0","method":"initialized","params":{}}'
  rpc '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$URI"'","languageId":"bux","version":1,"text":'"$CONTENT_JSON"'}}}'
  # workspace symbol query "Helper"
  rpc '{"jsonrpc":"2.0","id":2,"method":"workspace/symbol","params":{"query":"Helper"}}'
  # query "Util"
  rpc '{"jsonrpc":"2.0","id":3,"method":"workspace/symbol","params":{"query":"Util"}}'
  rpc '{"jsonrpc":"2.0","id":4,"method":"shutdown","params":null}'
  rpc '{"jsonrpc":"2.0","method":"exit","params":null}'
} | "$LSP" 2>/dev/null | tr '\r' '\n' > "$TMP/out.txt"

if ! grep -q 'workspaceSymbolProvider' "$TMP/out.txt"; then
  echo "FAIL: missing workspaceSymbolProvider"
  cat "$TMP/out.txt"
  exit 1
fi
if ! grep -q '0.6.0' "$TMP/out.txt"; then
  echo "WARN: version not 0.6.0"
fi
if ! grep -q 'Helper' "$TMP/out.txt"; then
  echo "FAIL: workspace/symbol did not find Helper"
  cat "$TMP/out.txt"
  exit 1
fi
# Util may come from workspace scan of Util.bux
if ! grep -q 'Util' "$TMP/out.txt"; then
  echo "WARN: Util not in workspace results (scan depth/path?)"
fi

echo "PASS: LSP workspace/symbol smoke"
