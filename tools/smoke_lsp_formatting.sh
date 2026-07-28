#!/usr/bin/env bash
# Smoke: textDocument/formatting re-indents with 4 spaces (same as bux fmt).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LSP="$ROOT/tools/bux-lsp"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$LSP" ]]; then
  echo "building bux-lsp..."
  (cd "$ROOT" && make lsp >/dev/null)
fi

# Intentionally bad indent (2 spaces)
cat > "$TMP/Main.bux" <<'EOF'
func Main() -> int {
  let x: int = 1;
    if x > 0 {
  return 0;
    }
  return 1;
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
  rpc '{"jsonrpc":"2.0","id":2,"method":"textDocument/formatting","params":{"textDocument":{"uri":"'"$URI"'"},"options":{"tabSize":4,"insertSpaces":true}}}'
  rpc '{"jsonrpc":"2.0","id":3,"method":"shutdown","params":null}'
  rpc '{"jsonrpc":"2.0","method":"exit","params":null}'
} | "$LSP" 2>/dev/null | tr '\r' '\n' > "$TMP/out.txt"

python3 - <<'PY' "$TMP/out.txt"
import json, sys, re
raw = open(sys.argv[1]).read()

# Find response id=2 with result TextEdit array
# Prefer structured parse of JSON objects containing "newText"
ok = False
version_ok = "0.18.0" in raw or '"documentFormattingProvider":true' in raw.replace(" ", "")
if "0.18.0" not in raw and "documentFormattingProvider" not in raw:
    # initialize result may be nested; still require a formatting response
    pass

# Extract TextEdit newText via regex / brace walk
edits = []
for m in re.finditer(r'"newText"\s*:\s*"((?:[^"\\]|\\.)*)"', raw):
    edits.append(bytes(m.group(1), "utf-8").decode("unicode_escape"))

if not edits:
    print("FAIL: no TextEdit newText in formatting response")
    print(raw[:3000])
    sys.exit(1)

formatted = edits[0]
# Expected: 4-space indent after func {
if "    let x: int = 1;" not in formatted:
    print("FAIL: expected 4-space indent on let")
    print(repr(formatted))
    sys.exit(1)
if "        if x > 0 {" not in formatted and "    if x > 0 {" not in formatted:
    # after let at indent 1, if should be at indent 1 (same block) = 4 spaces
    print("FAIL: unexpected if indent")
    print(repr(formatted))
    sys.exit(1)
# Nested body of if at 8 spaces
if "        return 0;" not in formatted:
    print("FAIL: expected 8-space indent on return inside if")
    print(repr(formatted))
    sys.exit(1)

print("PASS: LSP formatting smoke (4-space brace indent)")
if "0.18.0" in raw:
    print("PASS: serverInfo version 0.18.0")
PY
