#!/usr/bin/env bash
# Smoke: selfhost compiler (buxc2) — move_field ownership + multi-file #line
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUXC2="$ROOT/build/selfhost/build/buxc2"
export BUX_STDLIB="$ROOT/lib"
unset BUX_DEBUG_FILE || true
unset BUX_NO_LINE || true

if [[ ! -x "$BUXC2" ]]; then
  echo "=== building selfhost (buxc2) ==="
  (cd "$ROOT" && make selfhost)
fi
if [[ ! -x "$BUXC2" ]]; then
  echo "error: buxc2 not found at $BUXC2" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# 1) move_field — Array moved into struct must not UAF; program runs
# ---------------------------------------------------------------------------
echo "=== selfhost: move_field ==="
MF="$TMP/move_field"
mkdir -p "$MF/src"
cp -a "$ROOT/rt" "$MF/"
cat > "$MF/bux.toml" <<'EOF'
[Package]
Name    = "move_field"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
EOF
cp "$ROOT/examples/move_field.bux" "$MF/src/Main.bux"

(cd "$MF" && "$BUXC2" project .)
out=$("$MF/build/move_field")
echo "$out" | tee "$TMP/mf.out"
grep -q 'sum=30' "$TMP/mf.out"
grep -q 'PASS' "$TMP/mf.out" || grep -q 'move_field' "$TMP/mf.out"
# No Drop of moved local in MakeBox
if grep -A20 'MakeBox' "$MF/build/main.c" | grep -q 'Array_Drop_int(&items)'; then
  echo "error: MakeBox still drops moved 'items'" >&2
  grep -n 'MakeBox\|Array_Drop_int' "$MF/build/main.c" | head -30
  exit 1
fi
echo "  move_field: PASS (run + no Drop of moved Array)"

# ---------------------------------------------------------------------------
# 2) multi-file #line — Util.bux + Main.bux + stdlib paths, no BUX_DEBUG_FILE
# ---------------------------------------------------------------------------
echo "=== selfhost: multi-file #line ==="
MF2="$TMP/mfline"
mkdir -p "$MF2/src"
cp -a "$ROOT/rt" "$MF2/"
cat > "$MF2/bux.toml" <<'EOF'
[Package]
Name    = "mfline"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
EOF
cat > "$MF2/src/Util.bux" <<'EOF'
module Util {
    pub func Util_Double(n: int) -> int {
        return n * 2;
    }
}
EOF
cat > "$MF2/src/Main.bux" <<'EOF'
import Std::Io::{PrintLine};
import Std::String::{String_FromInt};

func Main() -> int {
    let v: int = Util_Double(21);
    PrintLine(String_FromInt(v as int64));
    return 0;
}
EOF

(cd "$MF2" && "$BUXC2" project .)
run_out=$("$MF2/build/mfline")
echo "$run_out" | tee "$TMP/mf2.out"
grep -q '42' "$TMP/mf2.out"

MAIN_C="$MF2/build/main.c"
test -f "$MAIN_C"
# Distinct source paths in #line
if ! grep -qE '#line [0-9]+ ".*Util\.bux"' "$MAIN_C"; then
  echo "error: no #line for Util.bux" >&2
  grep -E '^#line ' "$MAIN_C" | tail -20
  exit 1
fi
if ! grep -qE '#line [0-9]+ ".*Main\.bux"' "$MAIN_C"; then
  echo "error: no #line for Main.bux" >&2
  exit 1
fi
# Stdlib also stamped
if ! grep -qE '#line [0-9]+ ".*lib/.*\.bux"' "$MAIN_C"; then
  echo "error: no #line for stdlib lib/*.bux" >&2
  exit 1
fi
echo "  multi-file #line: PASS (Util + Main + lib)"

# ---------------------------------------------------------------------------
# 3) HirNode-level sourceFile — statement #line inside Util_Double uses Util.bux
#    (not only the function prolog), and never Main.bux inside that body.
# ---------------------------------------------------------------------------
echo "=== selfhost: HirNode sourceFile (#line in body) ==="
# Function definition (not the forward decl): #line 1 "…Util.bux" then int Util_Double(
util_body=$(awk '
  /#line 1 ".*Util\.bux"/ { grab=1 }
  grab { print }
  grab && /^}/ { exit }
' "$MAIN_C")
if [[ -z "$util_body" ]]; then
  echo "error: could not find Util_Double definition block" >&2
  grep -n 'Util_Double\|Util\.bux' "$MAIN_C" | head -20
  exit 1
fi
# Statement-level #line inside body (not only prolog #line 1) must point at Util.bux
if ! echo "$util_body" | grep -vE '#line 1 "' | grep -qE '#line [0-9]+ ".*Util\.bux"'; then
  echo "error: Util_Double body has no statement #line …Util.bux" >&2
  echo "$util_body"
  exit 1
fi
# Body of Util_Double must not claim Main.bux
if echo "$util_body" | grep -qE '#line [0-9]+ ".*Main\.bux"'; then
  echo "error: Util_Double body has #line Main.bux (wrong sourceFile)" >&2
  echo "$util_body" | grep -E '#line '
  exit 1
fi
echo "  HirNode sourceFile: PASS (Util_Double stmts → Util.bux)"

# ---------------------------------------------------------------------------
# 4) Expr/Stmt sourceFile — statement maps still per-file after AST stamp
#    (Util body must not pick up Main.bux via empty inherit)
# ---------------------------------------------------------------------------
echo "=== selfhost: Expr/Stmt sourceFile stamp ==="
# Re-use mfline main.c: every #line inside Util_Double already checked;
# additionally ensure Main body has no Util.bux (symmetric isolation).
main_body=$(awk '
  /#line 1 ".*Main\.bux"/ { grab=1 }
  grab { print }
  grab && /^}/ { exit }
' "$MAIN_C")
if [[ -z "$main_body" ]]; then
  echo "error: could not find Main definition block" >&2
  exit 1
fi
if echo "$main_body" | grep -qE '#line [0-9]+ ".*Util\.bux"'; then
  echo "error: Main body has #line Util.bux (Expr/Stmt stamp leak)" >&2
  echo "$main_body" | grep -E '#line '
  exit 1
fi
if ! echo "$main_body" | grep -vE '#line 1 "' | grep -qE '#line [0-9]+ ".*Main\.bux"'; then
  echo "error: Main body missing statement #line Main.bux" >&2
  echo "$main_body" | head -30
  exit 1
fi
echo "  Expr/Stmt sourceFile: PASS (Main stmts → Main.bux only)"

# ---------------------------------------------------------------------------
# 5) Binary op parentheses — C precedence must not rewrite Mul(Add,c)
#    Without parens selfhost emitted `a + b * c` → 7 instead of (a+b)*c → 9
# ---------------------------------------------------------------------------
echo "=== selfhost: binary op parentheses (C precedence) ==="
PREC="$TMP/c_precedence"
mkdir -p "$PREC/src"
cp -a "$ROOT/rt" "$PREC/"
cat > "$PREC/bux.toml" <<'EOF'
[Package]
Name    = "c_precedence"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
EOF
cp "$ROOT/examples/c_precedence.bux" "$PREC/src/Main.bux"

(cd "$PREC" && "$BUXC2" project .)
prec_out=$("$PREC/build/c_precedence")
echo "$prec_out" | tee "$TMP/prec.out"
grep -q 'PASS c_precedence' "$TMP/prec.out"
# Generated C must parenthesize the sum before multiply
if ! grep -A3 '^int MulSum' "$PREC/build/main.c" | grep -qE '\(a \+ b\) \* c|\(\(a \+ b\) \* c\)'; then
  echo "error: MulSum C lacks parentheses around a+b before *c" >&2
  grep -n -A5 '^int MulSum' "$PREC/build/main.c" | head -20
  exit 1
fi
if ! grep -A3 '^int SubDiv' "$PREC/build/main.c" | grep -qE '\(a - b\) / c|\(\(a - b\) / c\)'; then
  echo "error: SubDiv C lacks parentheses around a-b before /c" >&2
  grep -n -A5 '^int SubDiv' "$PREC/build/main.c" | head -20
  exit 1
fi
echo "  binary parens: PASS (run 9/3/6/7 + C has (a + b) * c)"

# ---------------------------------------------------------------------------
# 6) declarative macro! / quote! expand (session 60 selfhost parity)
# ---------------------------------------------------------------------------
echo "=== selfhost: macro! expand ==="
MAC="$TMP/macro_twice"
mkdir -p "$MAC/src"
cp -a "$ROOT/rt" "$MAC/"
cat > "$MAC/bux.toml" <<'EOF'
[Package]
Name    = "macro_twice"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
EOF
cp "$ROOT/examples/macro_twice.bux" "$MAC/src/Main.bux"
(cd "$MAC" && "$BUXC2" project .)
mac_out=$("$MAC/build/macro_twice")
echo "$mac_out" | tee "$TMP/mac.out"
grep -q 'PASS macro_twice' "$TMP/mac.out"
grep -q '42' "$TMP/mac.out"
echo "  macro!: PASS (twice/add2/quote → 42/42/43)"

# ---------------------------------------------------------------------------
# 7) multi-rep / compound zip / nested template $(…)* (session 63)
# ---------------------------------------------------------------------------
echo "=== selfhost: macro_nested multi-rep ==="
MACN="$TMP/macro_nested"
mkdir -p "$MACN/src"
cp -a "$ROOT/rt" "$MACN/"
cat > "$MACN/bux.toml" <<'EOF'
[Package]
Name    = "macro_nested"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
EOF
cp "$ROOT/examples/macro_nested.bux" "$MACN/src/Main.bux"
(cd "$MACN" && "$BUXC2" project .)
macn_out=$("$MACN/build/macro_nested")
echo "$macn_out" | tee "$TMP/macn.out"
grep -q 'PASS macro_nested' "$TMP/macn.out"
grep -q '33' "$TMP/macn.out"
grep -q '63' "$TMP/macn.out"
echo "  macro_nested: PASS (add_pairs/sum_groups/double_each/named_sum)"

echo "PASS: selfhost smoke (move_field + multi-file #line + HirNode/Expr sourceFile + binop parens + macro! + multi-rep)"
