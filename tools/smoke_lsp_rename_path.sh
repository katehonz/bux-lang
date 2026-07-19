#!/usr/bin/env bash
# Smoke: module-path segment rename (bux-lsp 0.12) — import Std::Io style
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LSP="$ROOT/tools/bux-lsp"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$LSP" ]]; then
  (cd "$ROOT" && make lsp >/dev/null)
fi

# Two files share Std::Io imports; also an unrelated Foo::Io and enum Color::Red
# so rename of Io under Std:: must not touch them.
cat > "$TMP/Main.bux" <<'EOF'
import Std::Io::{PrintLine, PrintInt};
import Foo::Io::Helper;
enum Color {
    Red,
    Green
}
func Main() -> int {
    let c: Color = Color::Red;
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

rpc() {
  local body="$1"
  local len
  len=$(printf '%s' "$body" | wc -c)
  printf 'Content-Length: %s\r\n\r\n%s' "$len" "$body"
}

CONTENT_JSON=$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$TMP/Main.bux")
URI="file://$TMP/Main.bux"
URI2="file://$TMP/Util.bux"
CONTENT2_JSON=$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$TMP/Util.bux")

# import Std::Io — "Io" starts after "import Std::" = col 12 on line 0
# "Std" starts at col 7 on line 0
{
  rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"rootUri":"file://'"$TMP"'"}}'
  rpc '{"jsonrpc":"2.0","method":"initialized","params":{}}'
  rpc '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$URI"'","languageId":"bux","version":1,"text":'"$CONTENT_JSON"'}}}'
  rpc '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"'"$URI2"'","languageId":"bux","version":1,"text":'"$CONTENT2_JSON"'}}}'
  # rename Io (module segment under Std) → Net
  rpc '{"jsonrpc":"2.0","id":2,"method":"textDocument/rename","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":0,"character":12},"newName":"Net"}}'
  # rename Std (path head) → Core — should hit Std:: only
  rpc '{"jsonrpc":"2.0","id":3,"method":"textDocument/rename","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":0,"character":7},"newName":"Core"}}'
  # rename Red (enum variant) must still work as member — not path
  rpc '{"jsonrpc":"2.0","id":4,"method":"textDocument/rename","params":{"textDocument":{"uri":"'"$URI"'"},"position":{"line":3,"character":4},"newName":"Crimson"}}'
  rpc '{"jsonrpc":"2.0","id":5,"method":"shutdown","params":null}'
  rpc '{"jsonrpc":"2.0","method":"exit","params":null}'
} | "$LSP" 2>/dev/null | tr '\r' '\n' > "$TMP/out.txt"

if ! grep -q '0.12.0' "$TMP/out.txt"; then
  echo "WARN: version not 0.12.0"
fi

# Io → Net: Main import Std::Io + Util import Std::Io (≥2), NOT Foo::Io
net_edits=$(grep -o '"newText":"Net"' "$TMP/out.txt" | wc -l)
if [[ "$net_edits" -lt 2 ]]; then
  echo "FAIL: path Io→Net expected ≥2 edits (Main+Util), got $net_edits"
  cat "$TMP/out.txt"
  exit 1
fi
# Must not rewrite Foo::Io — if it did, we'd still only get Net on Io segments.
# Check that a Net edit range is not on the Foo line by ensuring we have exactly
# the Std::Io sites (2) and not 3 (which would include Foo::Io).
if [[ "$net_edits" -ge 3 ]]; then
  echo "FAIL: path Io→Net too many edits ($net_edits) — may have hit Foo::Io"
  cat "$TMP/out.txt"
  exit 1
fi
echo "  path Io→Net edits: $net_edits"

# Std → Core: Main Std::Io + Util Std::Io (≥2); not Color:: or bare
core_edits=$(grep -o '"newText":"Core"' "$TMP/out.txt" | wc -l)
if [[ "$core_edits" -lt 2 ]]; then
  echo "FAIL: path Std→Core expected ≥2 edits, got $core_edits"
  cat "$TMP/out.txt"
  exit 1
fi
echo "  path Std→Core edits: $core_edits"

# Red → Crimson: decl + Color::Red use (≥2)
crimson_edits=$(grep -o '"newText":"Crimson"' "$TMP/out.txt" | wc -l)
if [[ "$crimson_edits" -lt 2 ]]; then
  echo "FAIL: enum Red→Crimson expected ≥2 (still member rename), got $crimson_edits"
  cat "$TMP/out.txt"
  exit 1
fi
echo "  enum Red→Crimson edits: $crimson_edits"

echo "PASS: LSP module-path segment rename (0.12)"
