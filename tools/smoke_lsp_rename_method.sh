#!/usr/bin/env bash
# Smoke: method rename + type/extend rename (bux-lsp 0.10)
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
    let a: int = p.Scale(2);
    return a;
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

# Len method decl ~ line 5 character 9
# Point type decl line 0 character 7
# self on line 5 ~ character 13 (param)
{
  rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"rootUri":"file://'"$TMP"'"}}'
  rpc '{"jsonrpc":"2.0","method":"initialized","params":{}}'
  rpc '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$URI"'","languageId":"bux","version":1,"text":'"$CONTENT_JSON"'}}}'
  # rename method Len → Length
  rpc '{"jsonrpc":"2.0","id":2,"method":"textDocument/rename","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":5,"character":9},"newName":"Length"}}'
  # rename type Point → Vec2 (decl)
  rpc '{"jsonrpc":"2.0","id":3,"method":"textDocument/rename","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":0,"character":7},"newName":"Vec2"}}'
  # rename self receiver param in Len — only that method's self
  rpc '{"jsonrpc":"2.0","id":4,"method":"textDocument/rename","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":5,"character":13},"newName":"this"}}'
  rpc '{"jsonrpc":"2.0","id":5,"method":"shutdown","params":null}'
  rpc '{"jsonrpc":"2.0","method":"exit","params":null}'
} | "$LSP" 2>/dev/null | tr '\r' '\n' > "$TMP/out.txt"

if ! grep -q '0.10.0' "$TMP/out.txt"; then
  echo "WARN: version not 0.10.0"
fi

# Len → Length: decl + self.Len() in Scale (≥2)
len_edits=$(grep -o '"newText":"Length"' "$TMP/out.txt" | wc -l)
if [[ "$len_edits" -lt 2 ]]; then
  echo "FAIL: method Len→Length expected ≥2 edits, got $len_edits"
  cat "$TMP/out.txt"
  exit 1
fi
echo "  method Len→Length edits: $len_edits"

# Point → Vec2: struct, extend, type annotations, constructor (≥4)
pt_edits=$(grep -o '"newText":"Vec2"' "$TMP/out.txt" | wc -l)
if [[ "$pt_edits" -lt 4 ]]; then
  echo "FAIL: type Point→Vec2 expected ≥4 edits, got $pt_edits"
  cat "$TMP/out.txt"
  exit 1
fi
echo "  type Point→Vec2 edits: $pt_edits"

# self → this: param + body uses in Len only (not Scale's self)
this_edits=$(grep -o '"newText":"this"' "$TMP/out.txt" | wc -l)
if [[ "$this_edits" -lt 2 ]]; then
  echo "FAIL: receiver self→this expected ≥2 edits in Len, got $this_edits"
  cat "$TMP/out.txt"
  exit 1
fi
# Scale also has self — if we renamed all self, count would be higher (≥4)
if [[ "$this_edits" -gt 3 ]]; then
  echo "FAIL: self→this too many edits ($this_edits) — leaked into other methods"
  exit 1
fi
echo "  receiver self→this edits: $this_edits"

echo "PASS: LSP method/type/receiver rename (0.10)"
