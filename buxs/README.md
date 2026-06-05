# BUXS — Windows-Compatible Project Root

This directory serves as an alternative project root for Windows environments
where the name `bux` may conflict with system paths or tooling.

## Usage

From this directory, you can build and run the Bux compiler using the
provided wrapper scripts.

## Structure

The actual project source lives in the parent directory (`../`):

- `../compiler/bootstrap/` — Nim bootstrap compiler
- `../compiler/selfhost/` — Self-hosting compiler (Bux)
- `../library/std/` — Standard library modules
- `../library/runtime/` — C runtime files
- `../tests/` — Integration tests
- `../docs/` — Documentation
