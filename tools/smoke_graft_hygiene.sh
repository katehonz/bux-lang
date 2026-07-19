#!/usr/bin/env bash
# Smoke: macro/quote sourceFile hygiene foundation
# - Mono instances from lib keep definition-site #line (Array.bux / etc.)
# - User Main keeps Main.bux (no leak of lib paths into Main body)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUXC2="$ROOT/build/selfhost/build/buxc2"
export BUX_STDLIB="$ROOT/lib"
unset BUX_DEBUG_FILE || true
unset BUX_NO_LINE || true

if [[ ! -x "$BUXC2" ]]; then
  (cd "$ROOT" && make selfhost >/dev/null)
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/src"
cp -a "$ROOT/rt" "$TMP/"

cat > "$TMP/bux.toml" <<'EOF'
[Package]
Name    = "graft_hygiene"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
EOF

# Main uses generic Array from stdlib — mono body must stay lib/*.bux (def site)
cat > "$TMP/src/Main.bux" <<'EOF'
import Std::Io::{PrintLine};
import Std::String::{String_FromInt};

func Main() -> int {
    let a: Array<int> = Array_New<int>(4);
    Array_Push<int>(&a, 1);
    Array_Push<int>(&a, 2);
    let n: int = Array_Len<int>(&a) as int;
    PrintLine(String_FromInt(n as int64));
    return 0;
}
EOF

(cd "$TMP" && "$BUXC2" project .)
out=$("$TMP/build/graft_hygiene")
echo "$out" | tee "$TMP/run.out"
grep -q '2' "$TMP/run.out"

MAIN_C="$TMP/build/main.c"
test -f "$MAIN_C"

# Array mono helpers must map to lib (definition site)
if ! grep -qE '#line [0-9]+ ".*lib/.*Array\.bux"|#line [0-9]+ ".*lib/Array\.bux"' "$MAIN_C"; then
  # Also accept any lib path with Array mono function nearby
  if ! grep -qE '#line [0-9]+ ".*lib/.*\.bux"' "$MAIN_C"; then
    echo "error: no #line for stdlib (definition-site mono hygiene)" >&2
    grep -E '^#line ' "$MAIN_C" | head -20
    exit 1
  fi
fi
echo "  def-site mono: PASS (lib #line present)"

# Main function body must not claim Array.bux
main_body=$(awk '
  /#line 1 ".*Main\.bux"/ { grab=1 }
  grab { print }
  grab && /^}/ { exit }
' "$MAIN_C")
if echo "$main_body" | grep -qE '#line [0-9]+ ".*Array\.bux"'; then
  echo "error: Main body has Array.bux #line (call-site leak)" >&2
  echo "$main_body" | grep '#line '
  exit 1
fi
if ! echo "$main_body" | grep -vE '#line 1 "' | grep -qE '#line [0-9]+ ".*Main\.bux"'; then
  echo "error: Main body missing statement #line Main.bux" >&2
  exit 1
fi
echo "  call-site Main: PASS (no Array.bux leak)"

# Array_Push_int region: first #line after its definition should not be Main.bux
if grep -q 'Array_Push_int' "$MAIN_C"; then
  # Grab ~30 lines after the Array_Push_int function start
  push_region=$(grep -n 'Array_Push_int(' "$MAIN_C" | head -1 | cut -d: -f1)
  if [[ -n "$push_region" ]]; then
    region=$(sed -n "${push_region},$((push_region + 35))p" "$MAIN_C")
    if echo "$region" | grep -vE '#line 1 ' | grep -qE '#line [0-9]+ ".*Main\.bux"'; then
      echo "error: Array_Push_int region maps statements to Main.bux" >&2
      echo "$region" | grep '#line ' || true
      exit 1
    fi
  fi
  echo "  Array_Push_int hygiene: PASS"
fi

echo "PASS: graft/quote hygiene (def-site mono + call-site Main isolation)"
