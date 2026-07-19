#!/usr/bin/env bash
# Run Bux micro-benchmarks + language twins (C / Nim / optional Zig). E.5
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUXC="$ROOT/buxc"
RUN_NEXUS="${BENCH_NEXUS:-0}"

if [[ ! -x "$BUXC" ]]; then
  (cd "$ROOT" && make build >/dev/null)
fi

echo "=== build benches/micro ==="
(cd "$ROOT/benches/micro" && "$BUXC" build)

echo ""
echo "--- Bux ---"
"$ROOT/benches/micro/build/micro"

echo ""
echo "--- C reference (gcc -O2) ---"
mkdir -p "$ROOT/benches/c/build"
gcc -O2 -o "$ROOT/benches/c/build/fib" "$ROOT/benches/c/fib.c"
gcc -O2 -o "$ROOT/benches/c/build/int_loop" "$ROOT/benches/c/int_loop.c"
echo -n "C  "; "$ROOT/benches/c/build/fib"
echo -n "C  "; "$ROOT/benches/c/build/int_loop"

echo ""
echo "--- Nim reference (-d:release) ---"
if command -v nim >/dev/null 2>&1; then
  mkdir -p "$ROOT/benches/nim/build"
  nim c -d:release --opt:speed --hints:off --warnings:off \
    -o:"$ROOT/benches/nim/build/fib" \
    "$ROOT/benches/nim/fib.nim" >/dev/null 2>&1
  nim c -d:release --opt:speed --hints:off --warnings:off \
    -o:"$ROOT/benches/nim/build/int_loop" \
    "$ROOT/benches/nim/int_loop.nim" >/dev/null 2>&1
  echo -n "Nim "; "$ROOT/benches/nim/build/fib"
  echo -n "Nim "; "$ROOT/benches/nim/build/int_loop"
else
  echo "(nim not installed — skip)"
fi

echo ""
echo "--- Zig reference (-OReleaseFast) ---"
if command -v zig >/dev/null 2>&1; then
  mkdir -p "$ROOT/benches/zig/build"
  (cd "$ROOT/benches/zig" && zig build-exe -OReleaseFast -femit-bin=build/fib fib.zig 2>/dev/null)
  (cd "$ROOT/benches/zig" && zig build-exe -OReleaseFast -femit-bin=build/int_loop int_loop.zig 2>/dev/null)
  echo -n "Zig "; "$ROOT/benches/zig/build/fib"
  echo -n "Zig "; "$ROOT/benches/zig/build/int_loop"
else
  echo "(zig not installed — skip; sources in benches/zig/)"
fi

if [[ "$RUN_NEXUS" == "1" ]]; then
  echo ""
  echo "=== Nexus throughput (BENCH_NEXUS=1) ==="
  chmod +x "$ROOT/tools/bench_nexus.sh"
  "$ROOT/tools/bench_nexus.sh"
fi

echo ""
if [[ "$RUN_NEXUS" == "1" ]]; then
  echo "PASS: bench (Bux + language twins + nexus)"
else
  echo "PASS: bench (Bux + language twins)"
fi
