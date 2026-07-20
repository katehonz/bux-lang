#!/usr/bin/env bash
# Smoke: type hierarchy across closed multi-file workspace (bux-lsp 0.16)
# Only Main.bux is opened. Drawable.bux + Shapes.bux stay closed (scanWorkspace).
# Empty `extend T for I {}` bodies — no methods — must still populate hierarchy
# via workspaceTypeRels (not method-only workspaceImpls).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LSP="$ROOT/tools/bux-lsp"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$LSP" ]]; then
  (cd "$ROOT" && make lsp >/dev/null)
fi

cat > "$TMP/Drawable.bux" <<'EOF'
interface Drawable {
    func Draw(self: &Self);
}
interface Named {
}
EOF

cat > "$TMP/Shapes.bux" <<'EOF'
struct Circle {
    radius: int;
}
struct Square {
    side: int;
}
// Empty extend bodies — no methods; relation must still be indexed
extend Circle for Drawable {
}
extend Square for Drawable {
}
extend Circle for Named {
}
EOF

# Only this file is opened. Types are closed on disk.
cat > "$TMP/Main.bux" <<'EOF'
func Use(d: Drawable, c: Circle) -> int {
    return 0;
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
# Drawable at col 12, Circle at col 25 in "func Use(d: Drawable, c: Circle)..."
DRAW_COL=12
CIRC_COL=25

{
  rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"rootUri":"file://'"$TMP"'"}}'
  rpc '{"jsonrpc":"2.0","method":"initialized","params":{}}'
  rpc '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$URI"'","languageId":"bux","version":1,"text":'"$CONTENT_JSON"'}}}'
  # prepare on Drawable (type annotation; def in closed Drawable.bux)
  rpc '{"jsonrpc":"2.0","id":2,"method":"textDocument/prepareTypeHierarchy","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":0,"character":'"$DRAW_COL"'}}}'
  # subtypes of Drawable → Circle + Square (closed Shapes.bux, empty extends)
  rpc '{"jsonrpc":"2.0","id":3,"method":"typeHierarchy/subtypes","params":{"item":{"name":"Drawable","kind":11,"uri":"file://'"$TMP"'/Drawable.bux","data":"Drawable","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":8}},"selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":8}}}}}'
  # prepare on Circle
  rpc '{"jsonrpc":"2.0","id":4,"method":"textDocument/prepareTypeHierarchy","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":0,"character":'"$CIRC_COL"'}}}'
  # supertypes of Circle → Drawable + Named
  rpc '{"jsonrpc":"2.0","id":5,"method":"typeHierarchy/supertypes","params":{"item":{"name":"Circle","kind":23,"uri":"file://'"$TMP"'/Shapes.bux","data":"Circle","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":6}},"selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":6}}}}}'
  # subtypes of Named → Circle only
  rpc '{"jsonrpc":"2.0","id":6,"method":"typeHierarchy/subtypes","params":{"item":{"name":"Named","kind":11,"uri":"file://'"$TMP"'/Drawable.bux","data":"Named","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},"selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}}}}}'
  rpc '{"jsonrpc":"2.0","id":7,"method":"shutdown","params":null}'
  rpc '{"jsonrpc":"2.0","method":"exit","params":null}'
} | "$LSP" 2>/dev/null | tr '\r' '\n' > "$TMP/out.txt"

if ! grep -q '0.16.0' "$TMP/out.txt"; then
  echo "WARN: version not 0.16.0"
fi

python3 - <<'PY' "$TMP/out.txt" "$TMP"
import json, sys, re
raw = open(sys.argv[1]).read()
tmp = sys.argv[2]
got = {}
for p in re.split(r'Content-Length:\s*\d+\s*', raw):
    p = p.strip()
    if not p.startswith('{'):
        continue
    try:
        j = json.loads(p)
    except Exception:
        continue
    if 'id' in j and 'result' in j:
        got[j['id']] = j['result']

def names(r):
    if not isinstance(r, list):
        return set()
    return {x.get('name') for x in r if isinstance(x, dict)}

def uris(r):
    if not isinstance(r, list):
        return set()
    return {x.get('uri', '') for x in r if isinstance(x, dict)}

r2 = got.get(2) or []
if 'Drawable' not in names(r2):
    print('FAIL: prepare Drawable (closed def) missing')
    print(got.get(2))
    sys.exit(1)
# Prefer closed file URI for the type item
u2 = uris(r2)
if not any('Drawable.bux' in u for u in u2):
    print(f'FAIL: prepare Drawable should point at Drawable.bux, got {u2}')
    sys.exit(1)
print('  prepare Drawable → closed Drawable.bux: OK')

r3 = got.get(3) or []
n3 = names(r3)
if 'Circle' not in n3 or 'Square' not in n3:
    print(f'FAIL: subtypes Drawable expected Circle+Square (empty extends), got {n3}')
    print(json.dumps(r3, indent=2)[:800])
    sys.exit(1)
u3 = uris(r3)
if not any('Shapes.bux' in u for u in u3):
    print(f'FAIL: subtypes should reference closed Shapes.bux, got {u3}')
    sys.exit(1)
print(f'  subtypes Drawable → {sorted(n3)} (closed, empty extend): OK')

r4 = got.get(4) or []
if 'Circle' not in names(r4):
    print('FAIL: prepare Circle missing')
    print(got.get(4))
    sys.exit(1)
print('  prepare Circle → closed Shapes.bux: OK')

r5 = got.get(5) or []
n5 = names(r5)
if 'Drawable' not in n5 or 'Named' not in n5:
    print(f'FAIL: supertypes Circle expected Drawable+Named, got {n5}')
    print(json.dumps(r5, indent=2)[:800])
    sys.exit(1)
print(f'  supertypes Circle → {sorted(n5)}: OK')

r6 = got.get(6) or []
n6 = names(r6)
if n6 != {'Circle'}:
    print(f'FAIL: subtypes Named expected only Circle, got {n6}')
    sys.exit(1)
print(f'  subtypes Named → {sorted(n6)}: OK')

print('PASS: LSP type hierarchy workspace index (0.16)')
PY
