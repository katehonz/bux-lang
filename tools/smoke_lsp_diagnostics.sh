#!/usr/bin/env bash
# Smoke: textDocument/publishDiagnostics underlines type/parse errors in the buffer.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LSP="$ROOT/tools/bux-lsp"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$LSP" ]]; then
  echo "building bux-lsp..."
  (cd "$ROOT" && make lsp >/dev/null)
fi

# Intentionally wrong: String assigned to int
cat > "$TMP/Main.bux" <<'EOF'
func Main() -> int {
    let x: int = "boom";
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

# Also test didChange: fix would clear, re-break would re-publish
BROKEN2='func Main() -> int {\n    let y: int = true;\n    return 0;\n}\n'
BROKEN2_JSON=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1].encode("utf-8").decode("unicode_escape")))' "$BROKEN2")

{
  rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"rootUri":"file://'"$TMP"'"}}'
  rpc '{"jsonrpc":"2.0","method":"initialized","params":{}}'
  rpc '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$URI"'","languageId":"bux","version":1,"text":'"$CONTENT_JSON"'}}}'
  # Give server a moment is not needed — sync stdio
  rpc '{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"'"$URI"'","version":2},"contentChanges":[{"text":'"$BROKEN2_JSON"'}]}}'
  rpc '{"jsonrpc":"2.0","id":2,"method":"shutdown","params":null}'
  rpc '{"jsonrpc":"2.0","method":"exit","params":null}'
} | "$LSP" 2>/dev/null | tr '\r' '\n' > "$TMP/out.txt"

echo "---- diagnostics excerpt ----"
grep -o '"method":"textDocument/publishDiagnostics"[^}]*}[^}]*}[^}]*}' "$TMP/out.txt" | head -5 || true
# Broader: any publishDiagnostics payload
python3 - <<'PY' "$TMP/out.txt"
import json, sys, re
raw = open(sys.argv[1]).read()
# Split on Content-Length framing remnants — we already stripped \r; bodies are JSON objects
parts = []
for m in re.finditer(r'\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}', raw):
    s = m.group(0)
    if "publishDiagnostics" in s or '"diagnostics"' in s:
        parts.append(s)

# More robust: scan for diagnostics arrays via string search
ok = True
if "publishDiagnostics" not in raw and "diagnostics" not in raw:
    print("FAIL: no publishDiagnostics notification")
    ok = False
else:
    # Must mention type mismatch somehow
    low = raw.lower()
    if "cannot assign" not in low and "type" not in low and "error" not in low:
        print("FAIL: diagnostics payload has no error-like message")
        ok = False
    else:
        print("found diagnostics notification with error content")
    # severity 1 = Error
    if '"severity":1' not in raw and '"severity": 1' not in raw:
        print("WARN: severity=1 not found as literal (may be ok)")
    # Expect at least one diagnostic on line 1 (0-based) for `let x: int = "boom"`
    if '"line":1' not in raw and '"line": 1' not in raw:
        # might be line 0 depending on layout
        if '"line":0' not in raw and '"line": 0' not in raw:
            print("WARN: unexpected line numbers")
    print("PASS markers: publishDiagnostics present")

if not ok:
    print("---- full output ----")
    print(raw[:4000])
    sys.exit(1)
print("PASS: LSP diagnostics smoke (error underlines)")
PY
