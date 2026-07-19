#!/usr/bin/env bash
# Smoke: interface dispatch call hierarchy (bux-lsp 0.11)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LSP="$ROOT/tools/bux-lsp"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$LSP" ]]; then
  (cd "$ROOT" && make lsp >/dev/null)
fi

cat > "$TMP/Main.bux" <<'EOF'
interface Drawable {
    func Draw(self: &Self);
}
struct Circle {
    radius: int;
}
extend Circle for Drawable {
    func Draw(self: &Circle) {
        let r: int = self.radius;
    }
}
func Render(c: Circle) {
    c.Draw();
}
func Main() -> int {
    let c: Circle = Circle { radius: 5 };
    Render(c);
    return 0;
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

# Draw iface method ~ line 1
# outgoing on interface Draw → implementor Circle.Draw
# incoming on interface Draw → Render (c.Draw())
{
  rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"rootUri":"file://'"$TMP"'"}}'
  rpc '{"jsonrpc":"2.0","method":"initialized","params":{}}'
  rpc '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$URI"'","languageId":"bux","version":1,"text":'"$CONTENT_JSON"'}}}'
  rpc '{"jsonrpc":"2.0","id":2,"method":"textDocument/prepareCallHierarchy","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":1,"character":9}}}'
  rpc '{"jsonrpc":"2.0","id":3,"method":"callHierarchy/outgoingCalls","params":{"item":{"name":"Drawable.Draw","kind":11,"data":"Drawable#Draw","uri":"'"$URI"'","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":13}},"selectionRange":{"start":{"line":1,"character":9},"end":{"line":1,"character":13}}}}}'
  rpc '{"jsonrpc":"2.0","id":4,"method":"callHierarchy/incomingCalls","params":{"item":{"name":"Drawable.Draw","kind":11,"data":"Drawable#Draw","uri":"'"$URI"'","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":13}},"selectionRange":{"start":{"line":1,"character":9},"end":{"line":1,"character":13}}}}}'
  rpc '{"jsonrpc":"2.0","id":5,"method":"shutdown","params":null}'
  rpc '{"jsonrpc":"2.0","method":"exit","params":null}'
} | "$LSP" 2>/dev/null | tr '\r' '\n' > "$TMP/out.txt"

if ! grep -q '0.11.0' "$TMP/out.txt"; then
  echo "WARN: version not 0.11.0"
fi

# prepare should surface Drawable.Draw
if ! grep -qE 'Drawable\.Draw|Draw' "$TMP/out.txt"; then
  echo "FAIL: prepare missing Draw"
  cat "$TMP/out.txt"
  exit 1
fi

# outgoing: implementor Circle (or Circle.Draw)
if ! grep -qE 'Circle' "$TMP/out.txt"; then
  echo "FAIL: outgoing interface method should list Circle implementor"
  cat "$TMP/out.txt"
  exit 1
fi

# incoming: Render calls c.Draw()
if ! grep -q '"name":"Render"' "$TMP/out.txt"; then
  echo "FAIL: incoming should include Render"
  cat "$TMP/out.txt"
  exit 1
fi

# kind 11 interface somewhere
if ! grep -q '"kind":11' "$TMP/out.txt"; then
  echo "FAIL: expected SymbolKind.Interface (11) for iface method"
  exit 1
fi

echo "PASS: LSP interface dispatch hierarchy (Drawable.Draw ↔ Circle / Render)"
