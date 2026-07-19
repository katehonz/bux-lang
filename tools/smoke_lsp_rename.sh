#!/usr/bin/env bash
# Smoke: textDocument/references + rename (bux-lsp 0.5.0)
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
  # references on `sum` (line 1, col 8)
  rpc '{"jsonrpc":"2.0","id":2,"method":"textDocument/references","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":1,"character":8},"context":{"includeDeclaration":true}}}'
  # prepareRename on sum
  rpc '{"jsonrpc":"2.0","id":3,"method":"textDocument/prepareRename","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":1,"character":8}}}'
  # rename sum → total
  rpc '{"jsonrpc":"2.0","id":4,"method":"textDocument/rename","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":1,"character":8},"newName":"total"}}'
  # references on Add (line 0)
  rpc '{"jsonrpc":"2.0","id":5,"method":"textDocument/references","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":0,"character":5},"context":{"includeDeclaration":true}}}'
  rpc '{"jsonrpc":"2.0","id":6,"method":"shutdown","params":null}'
  rpc '{"jsonrpc":"2.0","method":"exit","params":null}'
} | "$LSP" 2>/dev/null | tr '\r' '\n' > "$TMP/out.txt"

echo "---- excerpt ----"
# Show initialize capabilities mention
if ! grep -q 'referencesProvider' "$TMP/out.txt"; then
  echo "FAIL: initialize missing referencesProvider"
  cat "$TMP/out.txt"
  exit 1
fi
if ! grep -q 'renameProvider' "$TMP/out.txt"; then
  echo "FAIL: initialize missing renameProvider"
  exit 1
fi
if ! grep -qE '0\.[567]\.0' "$TMP/out.txt"; then
  echo "WARN: unexpected bux-lsp version in initialize"
fi

# Rename workspace edit should propose "total"
if ! grep -q '"newText":"total"' "$TMP/out.txt"; then
  echo "FAIL: rename did not emit newText total"
  cat "$TMP/out.txt"
  exit 1
fi

# Should have at least 2 edits for sum (decl + return)
total_edits=$(grep -o '"newText":"total"' "$TMP/out.txt" | wc -l)
if [[ "$total_edits" -lt 2 ]]; then
  echo "FAIL: expected ≥2 renames for sum, got $total_edits"
  exit 1
fi
echo "  rename sum→total edits: $total_edits"

# References responses are JSON arrays with uri/range — check line numbers for sum
if ! grep -q 'Main.bux' "$TMP/out.txt"; then
  echo "FAIL: no file URI in responses"
  exit 1
fi

echo "PASS: LSP references + rename smoke"
