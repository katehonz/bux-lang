#!/usr/bin/env bash
# Smoke: textDocument/implementation (bux-lsp 0.13)
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
struct Square {
    side: int;
}
extend Circle for Drawable {
    func Draw(self: &Circle) {
        let r: int = self.radius;
    }
}
extend Square for Drawable {
    func Draw(self: &Square) {
        let s: int = self.side;
    }
}
func Render(c: Circle) {
    c.Draw();
}
func Main() -> int {
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

# Drawable interface name ~ line 0 character 10
# Draw iface method ~ line 1 character 9
# c.Draw() call ~ line 22 character 6 (approx)
{
  rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"rootUri":"file://'"$TMP"'"}}'
  rpc '{"jsonrpc":"2.0","method":"initialized","params":{}}'
  rpc '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$URI"'","languageId":"bux","version":1,"text":'"$CONTENT_JSON"'}}}'
  # implementation on interface type Drawable
  rpc '{"jsonrpc":"2.0","id":2,"method":"textDocument/implementation","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":0,"character":10}}}'
  # implementation on iface method Draw
  rpc '{"jsonrpc":"2.0","id":3,"method":"textDocument/implementation","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":1,"character":9}}}'
  rpc '{"jsonrpc":"2.0","id":4,"method":"shutdown","params":null}'
  rpc '{"jsonrpc":"2.0","method":"exit","params":null}'
} | "$LSP" 2>/dev/null | tr '\r' '\n' > "$TMP/out.txt"

if ! grep -q '0.13.0' "$TMP/out.txt"; then
  echo "WARN: version not 0.13.0"
fi

if ! grep -q 'implementationProvider' "$TMP/out.txt"; then
  echo "FAIL: missing implementationProvider capability"
  cat "$TMP/out.txt"
  exit 1
fi

# id 2: interface → Circle + Square type locations
# Count locations in response for id 2 roughly via line ranges mentioning Circle/Square
# Parse with python for robustness
python3 - <<'PY' "$TMP/out.txt"
import json, sys, re
raw = open(sys.argv[1]).read()
# Split Content-Length messages into JSON bodies
bodies = []
for m in re.finditer(r'Content-Length:\s*(\d+)\s*\n\s*\n', raw):
    pass
# Simpler: find all JSON objects with "id"
parts = re.split(r'Content-Length:\s*\d+\s*', raw)
for p in parts:
    p = p.strip()
    if not p.startswith('{'):
        continue
    try:
        j = json.loads(p)
    except Exception:
        continue
    if j.get('id') == 2:
        r = j.get('result') or []
        if len(r) < 2:
            print(f"FAIL: interface Drawable expected ≥2 implementor types, got {len(r)}")
            print(json.dumps(j, indent=2)[:800])
            sys.exit(1)
        print(f"  interface Drawable → {len(r)} type location(s)")
    if j.get('id') == 3:
        r = j.get('result') or []
        if len(r) < 2:
            print(f"FAIL: iface method Draw expected ≥2 implementors, got {len(r)}")
            print(json.dumps(j, indent=2)[:800])
            sys.exit(1)
        # Expect two method sites (Circle.Draw + Square.Draw)
        print(f"  iface Draw → {len(r)} method location(s)")
print("PASS: LSP textDocument/implementation (0.13)")
PY
