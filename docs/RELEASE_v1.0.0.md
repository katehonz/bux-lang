# Bux v1.0.0 — Language Freeze

**Date:** 2026-07-27  
**Tag:** `v1.0.0`

## What 1.0 means

- **Language freeze** for public surface: syntax, stdlib APIs, and CLI that
  scripts depend on follow `docs/SEMVER.md`.
- **Normative spec:** `docs/LanguageRef.md`.
- **Compilers:** bootstrap (`buxc`, Nim) and selfhost (`buxc2`, Bux) both target
  the same language for the shipped feature set.
- **Platform focus:** Linux primary; cloud/containers; cross/static/minimal
  runtime. Windows is not a product platform.

## Shipped surface (summary)

| Area | Highlights |
|------|------------|
| Frontend | Pratt parser, recovery, macros (`macro!`, fragments, juxta/`tt`/`type`) |
| Types | Generics (mono), tuples, fat `func` ABI, algebraic enums |
| Ownership | `@[Checked]`, `@[Release]`, Drop/RAII, field-move + remaining Drop |
| Concurrency | M:N tasks, channels, async |
| Stdlib | Array/Map/Set/String/Iter HOF, Net/TLS, registry, Test |
| Tooling | `fmt`, `test`, `doc`, `check`, LSP (separate versioning), DWARF `#line` |
| Ecosystem | path/git/HTTP registry, lock + `--locked`, 4 apps, benches |

## Explicitly *not* 1.0 blockers

- True freestanding / bare-metal (`runtime_freestanding.c`, Cortex-M)
- Operators-only token paste; full `Array<int>` in `:type` fragments
- Windows product investment
- LLVM / non-C backends

## Upgrade notes from 0.5.x

No mandatory source migration for projects that already build on late 0.5.x.
New package scaffolds still default to package version `0.1.0` (package semver,
not language version).

### Fix included in 1.0.0

- **Closure Drop isolation:** lowering a nested closure no longer emits
  outer-function `Array_Drop` / auto-Drop on the closure’s return path
  (broke `iter_hof` and any capturing HOF over droppable locals).

## Verify

```bash
make build
./buxc --version          # bux 1.0.0 (bootstrap)
make test                 # full gate
make selfhost             # buxc2
# optional: make selfhost-loop
```
