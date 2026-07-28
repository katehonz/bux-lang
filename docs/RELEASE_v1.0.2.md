# Bux v1.0.2 — Patch

**Date:** 2026-07-28  
**Tag:** `v1.0.2`

Patch release on the **v1.0 language freeze**. No language-surface breakage;
stdlib + codegen correctness only.

## Fixes

| Area | Issue | Fix |
|------|--------|-----|
| `Array_Push` | `Array_New(0)` + push → segfault (`cap * 2 == 0`) | Grow to at least 4 when capacity was 0 (same as `Array_Insert`) |
| `Map` / `StringMap` | Full table → infinite loop in open-addressing probe; `cap == 0` → SIGFPE on `%` | Default min cap 8; auto-rehash when load ≥ 50% |
| `Set` | Same as Map | Same grow / min-cap policy |
| Integer `/` and `%` | Divisor 0 → raw SIGFPE | Emit `bux_div_i64` / `bux_mod_i64` (bootstrap LIR + C backends, selfhost C backend) |

## Verify

```bash
make build
./buxc --version          # bux 1.0.2 (bootstrap)
make test-stdlib test-examples
```
