#!/usr/bin/env bash
# Session 80 — selfhost buxc2 install + --locked checksum parity
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export BUX_STDLIB="${BUX_STDLIB:-$ROOT/lib}"

if [[ ! -x "$ROOT/build/selfhost/build/buxc2" ]]; then
  (cd "$ROOT" && make selfhost)
fi
BUXC2="$ROOT/build/selfhost/build/buxc2"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/app/src" "$TMP/libpkg/src"
# mini lib package
cat > "$TMP/libpkg/bux.toml" <<'EOF'
[Package]
Name    = "mini"
Version = "1.2.3"
Type    = "lib"
EOF
cat > "$TMP/libpkg/src/Lib.bux" <<'EOF'
func Mini_Version() -> String { return "1.2.3"; }
EOF

cat > "$TMP/app/bux.toml" <<EOF
[Package]
Name    = "app"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"

[Dependencies]
mini = { Path = "$TMP/libpkg" }
EOF
cat > "$TMP/app/src/Main.bux" <<'EOF'
func Main() -> int { return 0; }
EOF

cd "$TMP/app"
echo "=== buxc2 install ==="
"$BUXC2" install .
test -f bux.lock
grep -q mini bux.lock
grep -q Checksum bux.lock
cat bux.lock
cp bux.lock "$TMP/lock1"

echo "=== install reproducible ==="
"$BUXC2" install .
diff -u "$TMP/lock1" bux.lock

echo "=== install --locked ==="
"$BUXC2" install --locked .

echo "=== --locked fails without lock ==="
rm bux.lock
if "$BUXC2" install --locked . >"$TMP/err" 2>&1; then
  echo "error: expected failure" >&2
  cat "$TMP/err" >&2
  exit 1
fi
grep -qi 'missing\|locked' "$TMP/err"
"$BUXC2" install . >/dev/null

echo "=== checksum mismatch ==="
python3 - <<'PY'
from pathlib import Path
import re
p = Path("bux.lock")
t = p.read_text()
lines = []
for line in t.splitlines():
    if line.startswith("Checksum"):
        m = re.search(r'"([0-9a-fA-F]+)"', line)
        if m:
            h = m.group(1)
            h2 = h[:-1] + ("0" if h[-1] != "0" else "1")
            line = f'Checksum = "{h2}"'
    lines.append(line)
p.write_text("\n".join(lines) + "\n")
PY
if "$BUXC2" install --locked . >"$TMP/err2" 2>&1; then
  echo "error: expected checksum fail" >&2
  cat "$TMP/err2" >&2
  exit 1
fi
grep -qi checksum "$TMP/err2"

echo "PASS: smoke_selfhost_install"
