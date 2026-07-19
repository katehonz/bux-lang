#!/usr/bin/env bash
# Smoke: type hierarchy prepare / subtypes / supertypes (bux-lsp 0.15)
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

# Drawable ~ line 0 col 10; Circle ~ line 3 col 7
{
  rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"rootUri":"file://'"$TMP"'"}}'
  rpc '{"jsonrpc":"2.0","method":"initialized","params":{}}'
  rpc '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$URI"'","languageId":"bux","version":1,"text":'"$CONTENT_JSON"'}}}'
  # prepare on interface Drawable
  rpc '{"jsonrpc":"2.0","id":2,"method":"textDocument/prepareTypeHierarchy","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":0,"character":10}}}'
  # subtypes of Drawable
  rpc '{"jsonrpc":"2.0","id":3,"method":"typeHierarchy/subtypes","params":{"item":{"name":"Drawable","kind":11,"uri":"'"$URI"'","data":"Drawable","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":18}},"selectionRange":{"start":{"line":0,"character":10},"end":{"line":0,"character":18}}}}}'
  # prepare on Circle
  rpc '{"jsonrpc":"2.0","id":4,"method":"textDocument/prepareTypeHierarchy","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":3,"character":7}}}'
  # supertypes of Circle → Drawable
  rpc '{"jsonrpc":"2.0","id":5,"method":"typeHierarchy/supertypes","params":{"item":{"name":"Circle","kind":23,"uri":"'"$URI"'","data":"Circle","range":{"start":{"line":3,"character":0},"end":{"line":3,"character":13}},"selectionRange":{"start":{"line":3,"character":7},"end":{"line":3,"character":13}}}}}'
  rpc '{"jsonrpc":"2.0","id":6,"method":"shutdown","params":null}'
  rpc '{"jsonrpc":"2.0","method":"exit","params":null}'
} | "$LSP" 2>/dev/null | tr '\r' '\n' > "$TMP/out.txt"

if ! grep -q '0.15.0' "$TMP/out.txt"; then
  echo "WARN: version not 0.15.0"
fi

if ! grep -q 'typeHierarchyProvider' "$TMP/out.txt"; then
  echo "FAIL: missing typeHierarchyProvider capability"
  cat "$TMP/out.txt"
  exit 1
fi

python3 - <<'PY' "$TMP/out.txt"
import json, sys, re
raw = open(sys.argv[1]).read()
parts = re.split(r'Content-Length:\s*\d+\s*', raw)
got = {}
for p in parts:
    p = p.strip()
    if not p.startswith('{'):
        continue
    try:
        j = json.loads(p)
    except Exception:
        continue
    if 'id' in j and 'result' in j:
        got[j['id']] = j['result']

# id 2: prepare Drawable
r2 = got.get(2) or []
if not any(isinstance(x, dict) and x.get('name') == 'Drawable' for x in r2):
    print('FAIL: prepare on Drawable missing item')
    print(got.get(2))
    sys.exit(1)
print('  prepare Drawable: OK')

# id 3: subtypes ≥2 (Circle, Square)
r3 = got.get(3) or []
names = {x.get('name') for x in r3 if isinstance(x, dict)}
if 'Circle' not in names or 'Square' not in names:
    print(f'FAIL: subtypes of Drawable expected Circle+Square, got {names}')
    print(json.dumps(r3, indent=2)[:600])
    sys.exit(1)
print(f'  subtypes Drawable → {sorted(names)}')

# id 4: prepare Circle
r4 = got.get(4) or []
if not any(isinstance(x, dict) and x.get('name') == 'Circle' for x in r4):
    print('FAIL: prepare on Circle missing item')
    sys.exit(1)
print('  prepare Circle: OK')

# id 5: supertypes → Drawable
r5 = got.get(5) or []
snames = {x.get('name') for x in r5 if isinstance(x, dict)}
if 'Drawable' not in snames:
    print(f'FAIL: supertypes of Circle expected Drawable, got {snames}')
    sys.exit(1)
print(f'  supertypes Circle → {sorted(snames)}')

print('PASS: LSP type hierarchy (0.15)')
PY
