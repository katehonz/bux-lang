#!/usr/bin/env bash
# Smoke: method call hierarchy — extend Type + .Method() (bux-lsp 0.9)
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
extend Point {
    func Len(self: Point) -> int {
        return self.x + self.y;
    }
    func Scale(self: Point, n: int) -> int {
        return self.Len() * n;
    }
}
func Main() -> int {
    let p: Point = Point { x: 3, y: 4 };
    return p.Scale(2);
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

# Len is around line 5 (0-based: extend block)
# Scale around line 8
# Main line 11
{
  rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"rootUri":"file://'"$TMP"'"}}'
  rpc '{"jsonrpc":"2.0","method":"initialized","params":{}}'
  rpc '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$URI"'","languageId":"bux","version":1,"text":'"$CONTENT_JSON"'}}}'
  # prepare on Len method
  rpc '{"jsonrpc":"2.0","id":2,"method":"textDocument/prepareCallHierarchy","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":5,"character":9}}}'
  # incoming for Len — expect Scale (method call self.Len())
  rpc '{"jsonrpc":"2.0","id":3,"method":"callHierarchy/incomingCalls","params":{"item":{"name":"Point.Len","kind":6,"data":"Len","uri":"'"$URI"'","range":{"start":{"line":5,"character":0},"end":{"line":5,"character":12}},"selectionRange":{"start":{"line":5,"character":9},"end":{"line":5,"character":12}}}}}'
  # outgoing for Scale — expect Len
  rpc '{"jsonrpc":"2.0","id":4,"method":"callHierarchy/outgoingCalls","params":{"item":{"name":"Point.Scale","kind":6,"data":"Scale","uri":"'"$URI"'","range":{"start":{"line":8,"character":0},"end":{"line":8,"character":14}},"selectionRange":{"start":{"line":8,"character":9},"end":{"line":8,"character":14}}}}}'
  # incoming for Scale — expect Main
  rpc '{"jsonrpc":"2.0","id":5,"method":"callHierarchy/incomingCalls","params":{"item":{"name":"Point.Scale","kind":6,"data":"Scale","uri":"'"$URI"'","range":{"start":{"line":8,"character":0},"end":{"line":8,"character":14}},"selectionRange":{"start":{"line":8,"character":9},"end":{"line":8,"character":14}}}}}'
  rpc '{"jsonrpc":"2.0","id":6,"method":"shutdown","params":null}'
  rpc '{"jsonrpc":"2.0","method":"exit","params":null}'
} | "$LSP" 2>/dev/null | tr '\r' '\n' > "$TMP/out.txt"

if ! grep -q '0.9.0' "$TMP/out.txt"; then
  echo "WARN: version not 0.9.0"
fi

# prepare should return method (Point.Len or Len)
if ! grep -qE '"name":"(Point\.)?Len"' "$TMP/out.txt"; then
  echo "FAIL: prepare did not return Len method"
  cat "$TMP/out.txt"
  exit 1
fi

# Scale calls Len
if ! grep -qE '"name":"(Point\.)?Scale"' "$TMP/out.txt"; then
  echo "FAIL: missing Scale in hierarchy"
  cat "$TMP/out.txt"
  exit 1
fi

# Main calls Scale
if ! grep -q '"name":"Main"' "$TMP/out.txt"; then
  echo "FAIL: incoming Scale should include Main"
  cat "$TMP/out.txt"
  exit 1
fi

# kind 6 = Method somewhere
if ! grep -q '"kind":6' "$TMP/out.txt"; then
  echo "FAIL: expected SymbolKind.Method (6)"
  exit 1
fi

echo "PASS: LSP method call hierarchy (extend + .Method)"
