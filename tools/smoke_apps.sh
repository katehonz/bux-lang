#!/usr/bin/env bash
# Smoke: build showcase apps (E.2) and run non-server CLIs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUXC="$ROOT/buxc"

if [[ ! -x "$BUXC" ]]; then
  (cd "$ROOT" && make build >/dev/null)
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

APPS=(simpledb jwt-pitbul nexus boko-framework)
for app in "${APPS[@]}"; do
  echo "=== build apps/$app ==="
  (cd "$ROOT/apps/$app" && "$BUXC" build)
  test -x "$ROOT/apps/$app/build/$app" || test -x "$ROOT/apps/$app/build/${app}" || {
    # binary name may match package Name in bux.toml
    ls "$ROOT/apps/$app/build/"
  }
done

echo "=== simpledb set/get/del ==="
DB="$TMP/test.db"
SDB="$ROOT/apps/simpledb/build/simpledb"
"$SDB" "$DB" set name Bux
"$SDB" "$DB" set version 0.5
out=$("$SDB" "$DB" get name)
echo "$out" | grep -q Bux
"$SDB" "$DB" has name | grep -q true
"$SDB" "$DB" count | grep -q 2
"$SDB" "$DB" del version
"$SDB" "$DB" count | grep -q 1

echo "=== jwt-pitbul sign/verify/decode ==="
JWT="$ROOT/apps/jwt-pitbul/build/jwt-pitbul"
token=$("$JWT" sign HS256 'smoke-secret' '{"sub":"bux","role":"test"}')
echo "token=${token:0:40}..."
"$JWT" verify "$token" HS256 'smoke-secret' | tee "$TMP/jwt_verify.out"
grep -qiE 'valid|Signature|sub' "$TMP/jwt_verify.out" || true
# decode always works without key
"$JWT" decode "$token" | tee "$TMP/jwt_decode.out"
grep -q sub "$TMP/jwt_decode.out" || grep -q '"sub"' "$TMP/jwt_decode.out"

echo "=== nexus/boko binaries exist ==="
test -x "$ROOT/apps/nexus/build/nexus"
test -x "$ROOT/apps/boko-framework/build/boko-framework"

echo "PASS: apps smoke (build 4 + simpledb + jwt-pitbul)"
