#!/usr/bin/env bash
# Nexus HTTP throughput bench (E.5) — wrk against /api/health
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUXC="$ROOT/buxc"
NEXUS_DIR="$ROOT/apps/nexus"
PORT="${NEXUS_PORT:-18080}"
DURATION="${NEXUS_BENCH_DURATION:-5s}"
CONNECTIONS="${NEXUS_BENCH_C:-64}"
THREADS="${NEXUS_BENCH_T:-4}"
WORKERS="${NEXUS_WORKERS:-4}"

if [[ ! -x "$BUXC" ]]; then
  (cd "$ROOT" && make build >/dev/null)
fi

if ! command -v wrk >/dev/null 2>&1; then
  echo "error: wrk not found (apt install wrk / package manager)" >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl required" >&2
  exit 1
fi

echo "=== build nexus ==="
(cd "$NEXUS_DIR" && "$BUXC" build)

# Free port if something leftover
if command -v fuser >/dev/null 2>&1; then
  fuser -k "${PORT}/tcp" 2>/dev/null || true
fi

export NEXUS_PORT="$PORT"
export NEXUS_BIND="127.0.0.1"
export NEXUS_WORKERS="$WORKERS"
export NEXUS_PUBLIC="$NEXUS_DIR/public"

PID=""
cleanup() {
  if [[ -n "$PID" ]]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "=== start nexus :${PORT} (workers=${WORKERS}) ==="
(
  cd "$NEXUS_DIR"
  ./build/nexus
) >"$ROOT/benches/nexus_run.log" 2>&1 &
PID=$!

URL="http://127.0.0.1:${PORT}/api/health"
ready=0
for _ in $(seq 1 50); do
  if curl -fsS "$URL" >/dev/null 2>&1; then
    ready=1
    break
  fi
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "error: nexus exited early; log:" >&2
    cat "$ROOT/benches/nexus_run.log" >&2 || true
    exit 1
  fi
  sleep 0.1
done
if [[ "$ready" -ne 1 ]]; then
  echo "error: nexus did not become ready on $URL" >&2
  cat "$ROOT/benches/nexus_run.log" >&2 || true
  exit 1
fi

echo "=== curl sanity ==="
curl -fsS "$URL"
echo ""

echo "=== wrk -t${THREADS} -c${CONNECTIONS} -d${DURATION} ${URL} ==="
wrk -t"$THREADS" -c"$CONNECTIONS" -d"$DURATION" --latency "$URL" | tee "$ROOT/benches/nexus_wrk.out"

# Parse a compact summary line if possible
if grep -q "Requests/sec" "$ROOT/benches/nexus_wrk.out"; then
  rps=$(grep "Requests/sec" "$ROOT/benches/nexus_wrk.out" | awk '{print $2}')
  echo "BENCH nexus_health rps=${rps} port=${PORT} workers=${WORKERS} c=${CONNECTIONS} t=${THREADS} d=${DURATION}"
fi

echo "PASS: nexus throughput bench"
