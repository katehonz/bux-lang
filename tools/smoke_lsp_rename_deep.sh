#!/usr/bin/env bash
# Smoke: deeper rename — struct fields + enum variants (bux-lsp 0.7)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LSP="$ROOT/tools/bux-lsp"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$LSP" ]]; then
  (cd "$ROOT" && make lsp >/dev/null)
fi

cat > "$TMP/Main.bux" <<'EOF'
struct Point {
    x: int;
    y: int;
}
enum Color {
    Red,
    Green,
    Blue,
}
func Main() -> int {
    let p: Point = Point { x: 1, y: 2 };
    let a: int = p.x;
    let c: Color = Color::Red;
    let x: int = 99;
    return a + x;
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
  # rename field x on decl line 1 col 4 (struct field `x`)
  rpc '{"jsonrpc":"2.0","id":2,"method":"textDocument/rename","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":1,"character":4},"newName":"px"}}'
  # rename Color::Red variant — position on Red in enum (line 5)
  rpc '{"jsonrpc":"2.0","id":3,"method":"textDocument/rename","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":5,"character":4},"newName":"Crimson"}}'
  # rename local x (line 11) should NOT rename p.x field — use "xx"
  rpc '{"jsonrpc":"2.0","id":4,"method":"textDocument/rename","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":11,"character":8},"newName":"xx"}}'
  rpc '{"jsonrpc":"2.0","id":5,"method":"shutdown","params":null}'
  rpc '{"jsonrpc":"2.0","method":"exit","params":null}'
} | "$LSP" 2>/dev/null | tr '\r' '\n' > "$TMP/out.txt"

if ! grep -qE '0\.(7|8|9|10)\.0' "$TMP/out.txt"; then
  echo "WARN: unexpected bux-lsp version"
fi

# Field rename x → px: expect ≥3 (decl, init x:, access p.x)
px_count=$(grep -o '"newText":"px"' "$TMP/out.txt" | wc -l)
if [[ "$px_count" -lt 3 ]]; then
  echo "FAIL: field rename x→px expected ≥3 edits, got $px_count"
  cat "$TMP/out.txt"
  exit 1
fi
echo "  field x→px edits: $px_count"

# Variant Red → Crimson: decl + Color::Red
cr_count=$(grep -o '"newText":"Crimson"' "$TMP/out.txt" | wc -l)
if [[ "$cr_count" -lt 2 ]]; then
  echo "FAIL: variant Red→Crimson expected ≥2 edits, got $cr_count"
  cat "$TMP/out.txt"
  exit 1
fi
echo "  variant Red→Crimson edits: $cr_count"

# Local x→xx: should be small (decl + use in return), not include field
xx_count=$(grep -o '"newText":"xx"' "$TMP/out.txt" | wc -l)
if [[ "$xx_count" -lt 1 ]]; then
  echo "FAIL: local x→xx expected edits"
  exit 1
fi
if [[ "$xx_count" -gt 3 ]]; then
  echo "FAIL: local x→xx too many edits ($xx_count) — may have hit fields"
  cat "$TMP/out.txt"
  exit 1
fi
echo "  local x→xx edits: $xx_count"

echo "PASS: LSP deeper rename (field + variant + local shadowing)"
