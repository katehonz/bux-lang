#!/usr/bin/env bash
# Session 78 — Nexus HTTPS smoke (self-signed cert + curl -k).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export BUX_STDLIB="${BUX_STDLIB:-$ROOT/lib}"
PORT="${NEXUS_PORT:-18443}"
BIND="${NEXUS_BIND:-127.0.0.1}"

if [[ ! -x "$ROOT/apps/nexus/build/nexus" ]]; then
  (cd "$ROOT/apps/nexus" && "$ROOT/buxc" --release build)
fi
NEXUS="$ROOT/apps/nexus/build/nexus"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; kill $NPID 2>/dev/null || true' EXIT

# Self-signed cert (10y, CN=localhost)
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -subj "/CN=localhost" 2>/dev/null

NEXUS_PORT="$PORT" NEXUS_BIND="$BIND" NEXUS_WORKERS=2 NEXUS_ACCESS_LOG=1 \
NEXUS_TLS=1 NEXUS_TLS_CERT="$TMP/cert.pem" NEXUS_TLS_KEY="$TMP/key.pem" \
  "$NEXUS" >"$TMP/nexus.log" 2>&1 &
NPID=$!
sleep 0.6

if ! kill -0 "$NPID" 2>/dev/null; then
  echo "error: nexus failed to start" >&2
  cat "$TMP/nexus.log" >&2
  exit 1
fi

body=$(curl -sk --max-time 5 "https://${BIND}:${PORT}/api/health")
echo "$body"
echo "$body" | grep -q '"status":"ok"'
echo "$body" | grep -q '0.6.0'

info=$(curl -sk --max-time 5 "https://${BIND}:${PORT}/api/info")
echo "$info" | grep -q 'TLS'

kill -TERM "$NPID" 2>/dev/null || true
sleep 0.8
if kill -0 "$NPID" 2>/dev/null; then
  kill -9 "$NPID" 2>/dev/null || true
  echo "WARN: forced kill after SIGTERM"
else
  echo "PASS: SIGTERM exit"
fi

grep -q 'Listening on https://' "$TMP/nexus.log" || {
  echo "error: expected https banner" >&2
  cat "$TMP/nexus.log" >&2
  exit 1
}
grep -q 'GET /api/health' "$TMP/nexus.log" || true

echo "PASS: smoke_nexus_tls"
