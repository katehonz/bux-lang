#!/usr/bin/env bash
# Smoke: registry search + add + install + build with greet package (E.1)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUXC="$ROOT/buxc"
export BUX_REGISTRY="$ROOT/config/registry.toml"

if [[ ! -x "$BUXC" ]]; then
  (cd "$ROOT" && make build >/dev/null)
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "=== bux search greet ==="
"$BUXC" search greet | tee "$TMP/search.out"
grep -q greet "$TMP/search.out"

echo "=== create consumer project ==="
mkdir -p "$TMP/app/src"
cat > "$TMP/app/bux.toml" <<'EOF'
[Package]
Name    = "registry_consumer"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
EOF

cat > "$TMP/app/src/Main.bux" <<'EOF'
import Std::Io::{PrintLine};
import Std::String::{String_Eq};
import Std::Test::{Test_AssertTrue, Test_Pass};

func Main() -> int {
    let msg: String = Greet_Hello("Bux");
    Test_AssertTrue(String_Eq(msg, "Hello, Bux!"));
    Test_AssertTrue(String_Eq(Greet_Version(), "0.1.1"));
    PrintLine(msg);
    Test_Pass("registry_consumer");
    return 0;
}
EOF

cd "$TMP/app"
export BUX_STDLIB="$ROOT/lib"

echo "=== bux add greet ==="
"$BUXC" add greet
grep -q greet bux.toml
cat bux.toml

echo "=== bux install ==="
"$BUXC" install
test -f bux.lock
grep -q greet bux.lock
cat bux.lock

echo "=== bux run ==="
"$BUXC" run . | tee "$TMP/run.out"
grep -q "Hello, Bux!" "$TMP/run.out"

echo "PASS: registry smoke (search + add + install + build)"
