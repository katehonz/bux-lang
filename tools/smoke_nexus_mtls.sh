#!/usr/bin/env bash
# Session 80 — Nexus mTLS: reject no-client-cert; accept with client cert.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export BUX_STDLIB="${BUX_STDLIB:-$ROOT/lib}"
PORT="${NEXUS_PORT:-18444}"
BIND="${NEXUS_BIND:-127.0.0.1}"

if [[ ! -x "$ROOT/apps/nexus/build/nexus" ]]; then
  (cd "$ROOT/apps/nexus" && "$ROOT/buxc" --release build)
fi
NEXUS="$ROOT/apps/nexus/build/nexus"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; kill $NPID 2>/dev/null || true' EXIT

# CA + server + client certs
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/ca.key" -out "$TMP/ca.pem" \
  -days 1 -subj "/CN=TestCA" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout "$TMP/server.key" -out "$TMP/server.csr" \
  -subj "/CN=localhost" 2>/dev/null
openssl x509 -req -in "$TMP/server.csr" -CA "$TMP/ca.pem" -CAkey "$TMP/ca.key" \
  -CAcreateserial -out "$TMP/server.pem" -days 1 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout "$TMP/client.key" -out "$TMP/client.csr" \
  -subj "/CN=client" 2>/dev/null
openssl x509 -req -in "$TMP/client.csr" -CA "$TMP/ca.pem" -CAkey "$TMP/ca.key" \
  -CAcreateserial -out "$TMP/client.pem" -days 1 2>/dev/null

NEXUS_PORT="$PORT" NEXUS_BIND="$BIND" NEXUS_WORKERS=2 NEXUS_ACCESS_LOG=0 \
NEXUS_TLS=1 NEXUS_TLS_CERT="$TMP/server.pem" NEXUS_TLS_KEY="$TMP/server.key" \
NEXUS_TLS_CLIENT_CA="$TMP/ca.pem" \
  "$NEXUS" >"$TMP/nexus.log" 2>&1 &
NPID=$!
sleep 0.7

if ! kill -0 "$NPID" 2>/dev/null; then
  echo "error: nexus failed" >&2
  cat "$TMP/nexus.log" >&2
  exit 1
fi

# Without client cert → fail
if curl -sk --max-time 3 "https://${BIND}:${PORT}/api/health" -o /dev/null 2>/dev/null; then
  # some curl versions might still get empty; check exit code
  :
fi
set +e
curl -sk --max-time 3 "https://${BIND}:${PORT}/api/health" >/dev/null 2>&1
noclient=$?
set -e
if [[ $noclient -eq 0 ]]; then
  # Try again more strictly — handshake should fail
  if curl -sk --max-time 3 "https://${BIND}:${PORT}/api/health" 2>&1 | grep -q status; then
    echo "error: mTLS allowed request without client cert" >&2
    cat "$TMP/nexus.log" >&2
    exit 1
  fi
fi
echo "no-client: rejected (curl exit $noclient)"

# With client cert → ok
body=$(curl -sk --max-time 5 \
  --cert "$TMP/client.pem" --key "$TMP/client.key" \
  --cacert "$TMP/ca.pem" \
  "https://${BIND}:${PORT}/api/health")
echo "$body"
echo "$body" | grep -q '"status":"ok"'
echo "$body" | grep -q '0.6.0'

kill -TERM "$NPID" 2>/dev/null || true
sleep 0.6
kill -0 "$NPID" 2>/dev/null && kill -9 "$NPID" 2>/dev/null || true

grep -q 'mTLS' "$TMP/nexus.log" || grep -q 'client certificates' "$TMP/nexus.log"

echo "PASS: smoke_nexus_mtls"
