#!/usr/bin/env bash
# Smoke: workspace-wide import path index (bux-lsp 0.14)
# Util.bux is never opened — only indexed via scanWorkspace(rootUri).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LSP="$ROOT/tools/bux-lsp"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$LSP" ]]; then
  (cd "$ROOT" && make lsp >/dev/null)
fi

# Only Main is opened. Util lives on disk and must still be renamed via
# workspace import index + path-seg disk scan.
cat > "$TMP/Main.bux" <<'EOF'
import Std::Io::{PrintLine};
func Main() -> int {
    PrintLine("hi");
    return 0;
}
EOF

cat > "$TMP/Util.bux" <<'EOF'
import Std::Io::PrintLine;
func Util() -> int {
    return 0;
}
EOF

# Extra module path only in closed file — classification of use sites can still
# match workspace-known prefixes after scan.
cat > "$TMP/Closed.bux" <<'EOF'
import Vendor::Crypto::Hash;
func Closed() -> int { return 0; }
EOF

rpc() {
  local body="$1"
  local len
  len=$(printf '%s' "$body" | wc -c)
  printf 'Content-Length: %s\r\n\r\n%s' "$len" "$body"
}

CONTENT_JSON=$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$TMP/Main.bux")
URI="file://$TMP/Main.bux"

# Open ONLY Main — Util/Closed stay closed (indexed by initialized → scanWorkspace)
{
  rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"rootUri":"file://'"$TMP"'"}}'
  rpc '{"jsonrpc":"2.0","method":"initialized","params":{}}'
  rpc '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$URI"'","languageId":"bux","version":1,"text":'"$CONTENT_JSON"'}}}'
  # rename Io under Std (Main open; Util closed) → Net
  rpc '{"jsonrpc":"2.0","id":2,"method":"textDocument/rename","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":0,"character":12},"newName":"Net"}}'
  rpc '{"jsonrpc":"2.0","id":3,"method":"shutdown","params":null}'
  rpc '{"jsonrpc":"2.0","method":"exit","params":null}'
} | "$LSP" 2>/dev/null | tr '\r' '\n' > "$TMP/out.txt"

if ! grep -q '0.14.0' "$TMP/out.txt"; then
  echo "WARN: version not 0.14.0"
fi

# Io→Net must hit Main + closed Util (≥2). URI for Util should appear in changes.
net_edits=$(grep -o '"newText":"Net"' "$TMP/out.txt" | wc -l)
if [[ "$net_edits" -lt 2 ]]; then
  echo "FAIL: Io→Net expected ≥2 edits with Util closed, got $net_edits"
  cat "$TMP/out.txt"
  exit 1
fi
echo "  path Io→Net edits (Main open, Util closed): $net_edits"

# Workspace edit should mention Util.bux
if ! grep -q 'Util.bux' "$TMP/out.txt"; then
  echo "FAIL: rename did not include closed Util.bux in WorkspaceEdit"
  cat "$TMP/out.txt"
  exit 1
fi
echo "  closed Util.bux included in WorkspaceEdit"

echo "PASS: LSP workspace import path index (0.14)"
