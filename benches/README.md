# Bux benchmarks (E.5)

Micro-kernels + optional Nexus HTTP throughput for regression and language comparison.

## Quick run

```bash
# From repo root
make bench              # Bux micro + C + Nim (+ Zig if installed)
make bench-nexus        # wrk vs apps/nexus /api/health
BENCH_NEXUS=1 make bench
```

## Micro suites

| Suite | Kernels | Build |
|-------|---------|-------|
| `micro/` | Bux: `int_loop`, `fib30`, `string_concat`, `array_push` | `buxc build` |
| `c/` | C: `fib30`, `int_loop` | `gcc -O2` |
| `nim/` | Nim twins | `nim c -d:release --opt:speed` |
| `zig/` | Zig twins (optional) | `zig build-exe -OReleaseFast` |

Output lines:

```
BENCH <name> iters=N total_us=T us_per_op=P
```

## Nexus throughput

`tools/bench_nexus.sh` / `make bench-nexus`:

1. Builds `apps/nexus`
2. Starts on `NEXUS_PORT` (default **18080**), bind `127.0.0.1`
3. `wrk -t4 -c64 -d5s` against `/api/health`
4. Prints `BENCH nexus_health rps=…`

Env knobs:

| Variable | Default | Meaning |
|----------|---------|---------|
| `NEXUS_PORT` | `18080` | Listen port (also used by the server binary) |
| `NEXUS_WORKERS` | `4` | Worker threads |
| `NEXUS_BENCH_DURATION` | `5s` | wrk `-d` |
| `NEXUS_BENCH_C` | `64` | wrk connections |
| `NEXUS_BENCH_T` | `4` | wrk threads |

Server-side (any nexus run):

- `NEXUS_PORT`, `NEXUS_WORKERS`, `NEXUS_BIND`, `NEXUS_PUBLIC`

## Notes

- Numbers vary by machine; use them relatively (same host, same day).
- Nexus **v0.3** uses HTTP/1.1 keep-alive (default). Sample RPS on one machine:
  - close-only era: ~45k req/s
  - keep-alive: ~80k+ req/s (`wrk -t4 -c64 -d5s /api/health`)
- Requires `wrk` for `bench-nexus` (`apt install wrk` on Debian/Ubuntu).
