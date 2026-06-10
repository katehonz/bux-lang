# Bux Cross-Compilation Support — Design Document

> **Date:** 2026-06-10
> **Status:** Approved
> **Scope:** MVP cross-compilation via `--target` CLI flag

---

## 1. Overview

Bux compiles to C, which means cross-compilation is nearly free — we only need to pass the correct target triple to the C compiler (`cc`). This feature adds `--target <triple>` support to the Bux CLI.

### Goals
- `bux build --target aarch64-linux-gnu` produces an ARM64 binary
- `bux build --target x86_64-windows-gnu` produces a Windows binary
- No changes to the compiler pipeline — only the final `cc` invocation changes

### Non-Goals
- Automatic cross-compiler toolchain detection
- Custom linker scripts or startup code
- Multiple target builds in one invocation

---

## 2. How Cross-Compilation Works

Bux compilation pipeline:
```
.bux source → lexer → parser → sema → HIR → C code → cc → binary
```

The entire pipeline is target-independent until the final `cc` step. For cross-compilation:
1. Bux generates the same C code
2. Instead of `cc -O2 -pthread -o output ...`
3. We run `cc -O2 -pthread -target aarch64-linux-gnu -o output ...`

Or, if a cross-compiler prefix is needed:
```
aarch64-linux-gnu-gcc -O2 -pthread -o output ...
```

---

## 3. CLI Interface

```bash
# Native build (default)
bux build

# Cross-compile to ARM64 Linux
bux build --target aarch64-linux-gnu

# Cross-compile to Windows
bux build --target x86_64-pc-windows-gnu

# Also works with buxc project
buxc project . --target aarch64-linux-gnu
```

---

## 4. Implementation

### Changes to `src/cli.bux`

1. **Parse `--target` flag:** In `Cli_Run`, scan `args` for `--target` before processing the command. Extract the target triple.

2. **Store target:** Add a global variable `g_targetTriple: String` (default `""`).

3. **Pass to `cc`:** In both `Cli_Compile` (line ~251) and `Cli_BuildProject` (line ~1143), append `-target <triple>` to the `cc` command if `g_targetTriple` is set.

### Target Triple Format

We pass the triple directly to `cc` without validation. Examples:
- `aarch64-linux-gnu` → `cc -target aarch64-linux-gnu ...`
- `x86_64-pc-windows-gnu` → `cc -target x86_64-pc-windows-gnu ...`
- `wasm32-wasi` → `cc -target wasm32-wasi ...`

### Error Handling

If `cc` fails with an invalid target, the user sees the standard `cc` error message. Bux does not need custom error handling for this.

---

## 5. Files to Modify

| File | Change |
|------|--------|
| `src/cli.bux` | Parse `--target` flag, store in global, append to `cc` command |

---

## 6. Testing

1. **Native build:** `bux build` — should work as before (no `-target` flag)
2. **Invalid target:** `bux build --target invalid-target` — `cc` should fail with appropriate error
3. **Valid target (if cross-compiler available):** `bux build --target aarch64-linux-gnu` — should produce ARM64 binary
