# Bux Programming Language — Roadmap to v1.0.0

> **Version:** 0.3.1 (2026-06-06)
> **Bootstrap:** Nim (`bootstrap/`) — compiles `src/` → `buxc`
> **Self-host:** Bux (`src/`) — compiles via `buxc` → `buxc2`
> **Target:** Bux v1.0.0 — fully self-hosting, gradual ownership, tooling

---

## Overview

Bux is a fast, compiled, strongly-typed, multi-paradigm systems programming language. The strategy is **bootstrap via Nim** — we built the first Bux compiler in Nim, then rewrote it in Bux. The Nim bootstrap now exists only as a build scaffold.

**Core philosophy:** Systems-level control with modern ergonomics. No hidden costs, no hidden allocations, no hidden control flow.

**Killer feature:** Gradual ownership — write fast like C, add safety like Rust, but only where you choose (`@[Checked]`).

---

## Language Design Goals (Bux vs Rust vs Nim vs Zig)

| Dimension | Bux Target | Rust | Nim | Zig |
|-----------|-----------|------|-----|-----|
| **Memory safety** | Gradual ownership (opt-in borrow checking) | Strict borrow checker | GC / manual | Manual + comptime |
| **Error handling** | `Result<T,E>` + `?` + `!` | `Result<T,E>` + `?` | Exceptions | Error unions + `try` |
| **Concurrency** | Lightweight tasks + channels + `async`/`await` | `async`/`await` + threads | Async/await + threads | Async I/O (io_uring) |
| **Metaprogramming** | Compile-time function execution (CTFE) + macros | Proc/decl macros | Static generics + macros | `comptime` (best-in-class) |
| **Generics** | Monomorphization + trait bounds | Monomorphization + trait bounds | Static generics | `comptime` generics |
| **Backend** | C transpiler (bootstrap) → native x86-64 + LLVM | LLVM | C/JS/JS backend | LLVM + custom |
| **Compile speed** | Fast (Nim-like goal: <1s for medium projects) | Slow (LLVM) | Fast | Very fast |
| **FFI** | Seamless C interop (zero-cost) | Good | Good (native) | Excellent (best-in-class) |
| **Stdlib** | Batteries-included (collections, IO, net, sync) | Rich | Rich | Minimal (allocators) |
| **Tooling** | Built-in formatter, LSP, test runner, debugger | External tools | External tools | `zig build` (excellent) |
| **Simplicity** | Clean C-like syntax + modern ergonomics | Complex | Clean | Minimal, explicit |

---

## Phase 0 — Bootstrap Foundation ✅ (Complete)

**Goal:** Working Nim project that can lex, parse, and dump a Bux AST.

| Task | Status | Details |
|------|--------|---------|
| `0.1` Project skeleton | ✅ | `buxc` CLI in Nim, `bux.toml` manifest parser |
| `0.2` Token model | ✅ | Full token set (`TokenKind`, `SourceLocation`, literal suffixes) |
| `0.3` Lexer | ✅ | UTF-8 source, identifiers, numbers (dec/hex/bin/oct), strings (`c8""`, `c16""`, `c32""`), chars, operators, nested `/* */`, `//` comments, intrinsics (`#line`, `#file`, etc.) |
| `0.4` CLI commands | ✅ | `bux new`, `bux init`, `bux build`, `bux run`, `bux check` |
| `0.5` Test harness | ✅ | Golden-file tests for lexer output (`.tokens`) |

**Deliverable:** `echo 'let x = 42' | bux check` prints token stream.

---

## Phase 1 — Frontend: Parser & AST ✅ (Complete)

**Goal:** Parse every Bux language construct into a Nim AST.

| Task | Status | Details |
|------|--------|---------|
| `1.1` AST nodes | ✅ | All `Expr`, `Stmt`, `Decl`, `Pattern`, `TypeExpr`, `Block` variants |
| `1.2` Pratt parser | ✅ | Full precedence climbing for all binary/unary/postfix operators including `**` (right-assoc) and range `..` / `..=` |
| `1.3` Declarations | ✅ | `func`, `struct`, `enum`, `union`, `interface`, `extend`/`impl`, `module`, `const`, `type`, `extern`, `import`/`use` |
| `1.4` Statements | ✅ | `let`/`var`, `if`/`else if`/`else`, `while`, `do while`, `loop`, `for in`, `match`, `return`, `break`/`continue` (with labels) |
| `1.5` Expressions | ✅ | Literals, identifiers, paths (`a::b`), calls, index, field access, struct init, slice init `[a,b]`, tuple `(a,b)`, cast `as`, test `is`, ternary `? :`, block-expr `{ ... }` |
| `1.6` Patterns | ✅ | Wildcard `_`, literal, ident, range, enum destructuring, struct destructuring, tuple, guarded `if` |
| `1.7` Attributes | ✅ | `@[Import(lib: "...")]`, calling-convention, platform-conditional imports |
| `1.8` Error recovery | ✅ | Synchronize on declaration/statement boundaries; emit multiple diagnostics |

**Deliverable:** All `tests/frontend/**/*.bux` files parse without error and produce `.ast` dumps.

---

## Phase 2 — Semantic Analysis ✅ (Complete)

**Goal:** Type-check the AST and produce a typed symbol table.

| Task | Status | Details |
|------|--------|---------|
| `2.1` Type model | ✅ | `TypeRef` with primitives, pointers, slices, tuples, named types, type parameters, functions |
| `2.2` Scopes | ✅ | Module scope, block scope, namespace resolution for `Std::Io::PrintLine` |
| `2.3` First pass | ✅ | Collect global symbols (functions, structs, enums, unions, interfaces, consts, type aliases, imports) |
| `2.4` Type checking | ✅ | Expression typing, operator overload resolution, assignment compatibility |
| `2.5` Name resolution | ✅ | Resolve identifiers, paths, `self`, `super`; report undeclared / ambiguous names |
| `2.6` Interface conformance | ✅ | Check that `extend T for I` provides all required methods; build vtable map |
| `2.7` Generics (basic) | ✅ | Monomorphization of generic functions and generic structs at call sites |
| `2.8` Diagnostics | ✅ | Multi-file error messages with source locations |
| `2.9` **Algebraic enums** | ✅ | Enums with data (like Rust's `enum Result<T,E> { Ok(T), Err(E) }`) — lowered to tagged unions |
| `2.10` **Method resolution** | ✅ | Resolve `obj.method()` calls to `Type_method(obj)` based on receiver type; supports generic struct methods with lazy monomorphization |

**Deliverable:** `bux check` rejects ill-typed programs and passes all 9 example programs.

---

## Phase 3 — High-Level IR (HIR) ✅ (Complete)

**Goal:** Lower AST to a simplified, fully-typed HIR.

| Task | Status | Details |
|------|--------|---------|
| `3.1` HIR nodes | ✅ | Desugared equivalents of AST nodes |
| `3.2` Lowering | ✅ | Desugar `for` → `while`+counter, `match` → if-else chains, method calls to explicit receiver calls |
| `3.3` Constant folding | ⏳ | Evaluate `const` and simple compile-time expressions |
| `3.4` Interface lowering | ⏳ | Convert interface values to fat pointers `{data_ptr, vtable_ptr}`; generate vtable labels |
| `3.5` **Generic instantiation** | ✅ | Monomorphize generic functions and generic structs at call sites |
| `3.6` **Enum lowering** | ✅ | Lower algebraic enums to tagged unions `{tag: uint, data: union}` |

**Deliverable:** HIR lowering produces valid C code for all example programs.

---

## Phase 4 — Low-Level IR (LIR) (Week 9-10)

**Goal:** Generate SSA-like LIR with virtual registers and basic blocks.

| Task | Details |
|------|---------|
| `4.1` LIR model | `LirInstr`, `LirBlock`, `LirTerminator`, `LirFunc`, `LirReg`, opcodes (`Const`, `Alloca`, `Load`, `Store`, arithmetic, `Call`, `Phi`, `GlobalAddr`, etc.) |
| `4.2` Control flow | Lower `if`, `while`, `loop`, `match` to blocks with `Jump` / `Branch` / `Switch` terminators |
| `4.3` Memory | Stack allocation (`alloca`), pointer arithmetic, field/index pointer computation |
| `4.4` Calls | Direct calls, indirect calls, extern calls with correct ABI marking (System V / Win64) |

**Deliverable:** `bux build --emit-lir` produces readable LIR for all test programs.

---

## Phase 5 — Backend & Code Generation (Week 11-14)

**Strategy:** Two backends in parallel — a **C transpiler** for instant portability and a **native x86-64** backend for performance.

### 5A — C Transpiler (Primary bootstrap path) ✅

| Task | Status | Details |
|------|--------|---------|
| `5A.1` C emitter | ✅ | Walk HIR and emit C11 code |
| `5A.2` Types to C | ✅ | Bux primitives → C primitives; structs → C structs; enums → C enums + tagged unions; slices → `T*` |
| `5A.3` Functions to C | ✅ | Bux functions → C functions with `static` / `extern`; name mangling for overloads/generics |
| `5A.4` FFI | ✅ | `extern` / `@[Import]` → `extern` declarations; link with system `cc` |
| `5A.5` Runtime shim | ✅ | Small C runtime providing `bux_alloc`, `bux_print`, panic/abort for div-by-zero, etc. |
| `5A.6` Build integration | ✅ | `bux build` invokes `cc` / `clang` / `gcc` automatically |

**Deliverable:** `bux run` on all 9 examples produces working binaries.

### 5B — Native x86-64 Backend (Secondary, for self-hosting speed)

| Task | Details |
|------|---------|
| `5B.1` Assembly emitter | NASM-syntax text output |
| `5B.2` Register allocation | Naive stack-spill allocator first; later linear-scan |
| `5B.3` ABI lowering | System V AMD64 ABI (Linux/macOS) and Win64 ABI (Windows) |
| `5B.4` Object format | Emit ELF64 (Linux), Mach-O (macOS), PE/COFF (Windows) — or use `nasm` + system linker |
| `5B.5` Custom linker (optional) | `.bcu` (Bux Compiled Unit) format + bespoke linker |

**Deliverable:** `bux build --backend=native` produces working Linux x86-64 binary.

---

## Phase 6 — Standard Library 🔄 (Mostly Complete)

**Goal:** Enough stdlib to write the compiler in Bux.

| Module | Status | Requirements |
|--------|--------|-------------|
| `Std::Io` | ✅ | `Print`, `PrintLine`, `PrintInt`, `ReadLine` (wrap C stdio) |
| `Std::Mem` | ✅ | `Alloc`, `Realloc`, `Free`, `MemEq`, `New<T>` — wrappers around C runtime |
| `Std::String` | ✅ | Full API: `String_Len`, `String_Eq`, `String_Concat`, `String_Copy`, `String_StartsWith`, `String_EndsWith`, `String_Contains`, `String_Slice`, `String_Trim`, `String_TrimLeft`, `String_TrimRight`, `String_FromInt`, `String_ToInt`, `StringBuilder`; plus `String_Find`, `String_Replace`, `String_Format1/2/3`; C wrappers in `runtime.c` |
| `Std::Array` | ✅ | Fully generic `Array<T>` with `Array_New<T>`, `Array_Push<T>`, `Array_Get<T>`, `Array_Len<T>`, `Array_Free<T>`; generic struct methods with auto-addressing |
| `Std::Map` | ✅ | Generic `Map<K,V>` with `Map_New`, `Map_Set`, `Map_Get`, `Map_Has`, `Map_Len`, `Map_Free`; value-type keys with strcmp |
| `Std::StringMap` | ✅ | Specialized `StringMap<V>` for String keys using `strcmp` |
| `Std::Set` | ✅ | Generic `Set<T>` with `Set_New`, `Set_Add`, `Set_Has`, `Set_Len`, `Set_Free` |
| `Std::Math` | ✅ | `Sqrt`, `Pow`, `Min`, `Max`, `Abs`, `MinF`, `MaxF`, `AbsF` (float64 + int64 variants, C runtime wrappers) |
| `Std::Path` | ✅ | `Path_Join`, `Path_Parent`, `Path_Ext` |
| `Std::Fs` | ✅ | `DirExists`, `Mkdir`, `ListDir` |
| `Std::Os` | ⏳ | `Args`, `Env`, `Exit`, `Cwd` |
| `Std::Process` | ⏳ | Spawn subprocess, read stdout/stderr |
| **`Std::Result`** | ✅ | Algebraic enums `Result<T,E>` and `Option<T>` with `NewOk`/`NewErr`/`NewSome`/`NewNone`; `?` try operator desugared in HIR |
| **`Std::Iter`** | ⏳ | Iterator trait with `map`, `filter`, `fold`, `collect` |
| **`Std::Fmt`** | ⏳ | String formatting: `"Hello, {}!"` interpolation |

**Additional completed:**
- ✅ Generic type inference: `Max(10, 20)` instead of `Max<int>(10, 20)` — compiler infers `T` from argument types
- ✅ `extend Box<T>` syntax: parser support for generic impl blocks
- ✅ String slicing, trimming, contains, StringBuilder (`strings2` example)
- ✅ String find, replace, format (`String_Find`, `String_Replace`, `String_Format`)
- ✅ Generic `Map<K,V>` with value-type keys
- ✅ Generic `Set<T>` for deduplication
- ✅ File system operations (`Std::Fs`)
- ✅ Memory management wrappers (`Std::Mem`)

**Deliverable:** Can write a non-trivial CLI tool entirely in Bux. ✅ 20+ example programs working.

---

## Phase 6.5 — Self-Hosting Audit (Completed 2026-05-31)

### Source File Analysis

| File | Lines | Procs | Complexity | Bux Readiness |
|------|-------|-------|------------|---------------|
| `source_location.nim` | 8 | 0 | Trivial struct | ✅ Ready |
| `main.nim` | 6 | 0 | CLI entry | ✅ Ready |
| `scope.nim` | 47 | 4 | Simple | ✅ Ready |
| `manifest.nim` | 79 | 2 | TOML parser | ⚠️ Needs TOML/INI parser |
| `hir.nim` | 184 | 0 | Type defs | ✅ Ready |
| `types.nim` | 185 | 44 | Factories | ✅ Ready |
| `token.nim` | 305 | 12 | Enum + helpers | ✅ Ready |
| `cli.nim` | 390 | 15 | File I/O, process | ⚠️ Needs File I/O, path ops |
| `ast.nim` | 400 | 6 | Complex case-object | ✅ Ready (algebraic enums) |
| `c_backend.nim` | 519 | 16 | Code generation | ⚠️ Needs String formatting |
| `lexer.nim` | 567 | 37 | State machine | ⚠️ Needs String split/compare |
| `sema.nim` | 892 | 27 | Type checking | ⚠️ Needs Table[String,...] |
| `parser.nim` | 1220 | 81 | Pratt parser | ⚠️ Needs seq/array ops |
| `hir_lower.nim` | 1233 | 29 | Tree transform | ⚠️ Needs Table, HashSet |

### Nim Patterns → Bux Equivalents

| Nim Pattern | Used In | Bux Status |
|-------------|---------|------------|
| `Table[string, T]` | sema, hir_lower, c_backend (23 uses) | ❌ **Blocker** — need `StringMap<V>` |
| `HashSet[string]` | hir_lower (1 use) | ✅ `Set<T>` available |
| `seq[T]` with push/len/iter | All files (200+ uses) | ⚠️ `Array<T>` exists, needs richer API |
| `&"..."` / `fmt"..."` | sema, c_backend (119 uses) | ✅ `String_Format1/2/3` available |
| `split()`, `join()` | lexer, parser, cli | ✅ `String_SplitCount`, `String_SplitPart`, `String_Join2` |
| `case obj.kind of...` | All files (90+ uses) | ✅ `match` with algebraic enums |
| `for x in collection` | All files (200+ uses) | ✅ Supported |
| `var` parameters | Multiple | ✅ Use pointers (`*T`) |
| File read/write | cli | ✅ `ReadFile`, `WriteFile` in `Std::Io` |
| OS path operations | cli, manifest | ✅ `Path_Join`, `DirExists`, `Mkdir` in `Std::Path`/`Std::Fs` |

### Rewrite Order (Dependency-driven)

```
Phase 7.0 — Stdlib blockers (all resolved ✅):
  ├── StringMap<V> ✅
  ├── String split/join ✅
  ├── String formatting ✅
  ├── File I/O (readFile, writeFile, fileExists) ✅
  └── OS path (joinPath, parentDir) ✅

Remaining gaps for self-host polish:
  ├── `Std::Os` — `Args`, `Env`, `Exit`, `Cwd`
  └── `Std::Process` — spawn subprocess

Phase 7.1 — Foundation (no internal deps):
  ├── token.bux (enum + helpers)
  ├── source_location.bux (struct)
  ├── types.bux (enum + factories)
  ├── scope.bux (symbol table — needs StringMap)
  └── hir.bux (type definitions)

Phase 7.2 — Frontend (depends on 7.1):
  ├── lexer.bux (needs String split/compare)
  ├── ast.bux (algebraic enums)
  └── parser.bux (Pratt parser, needs Array<T>)

Phase 7.3 — Analysis (depends on 7.2):
  ├── sema.bux (type checking, needs StringMap, formatting)
  └── manifest.bux (TOML parser)

Phase 7.4 — Backend (depends on 7.3):
  ├── hir_lower.bux (tree transform, needs StringMap, HashSet)
  └── c_backend.bux (code gen, needs String formatting)

Phase 7.5 — Driver (depends on all):
  ├── cli.bux (file I/O, argument parsing)
  └── main.bux (entry point)
```

### Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| StringMap not working for String keys | **High** | Already have working `StringMap<V>` in stdlib using strcmp |
| `&key as *void` precedence bug | **Medium** | Workaround: use intermediate `*K` variable |
| Cross-module generics not working | **Medium** | All compiler code will be in one package (merged via stdlib mechanism) |
| `Map_Len` / `Set_Len` monomorphization bug | **Low** | C backend issue — use explicit type args or avoid; QBE backend unaffected |
| String formatting | **Medium** | `String_Format1/2/3` available via `bux_str_format` |
| Array<T> API gaps | **Low** | Extend Array module as needed during porting |

### Estimated Effort

| Phase | Bux LOC | Effort |
|-------|---------|--------|
| 7.0 Stdlib blockers | ~300 | 1-2 sessions |
| 7.1 Foundation | ~600 | 1-2 sessions |
| 7.2 Frontend | ~1800 | 3-4 sessions |
| 7.3 Analysis | ~900 | 2-3 sessions |
| 7.4 Backend | ~1700 | 3-4 sessions |
| 7.5 Driver | ~400 | 1 session |
| **Total** | **~5700** | **11-16 sessions** |

---

## Phase 7 — Self-Hosting: The Great Rewrite ✅ (Complete)

**Goal:** Bux compiler compiles itself. This is the **main milestone**.

**All 14 modules ported** in `src/` (4094 LOC total). Built via `make selfhost`.

| Task | Status | Details | LOC |
|------|--------|---------|-----|
| `7.1` Port foundation | ✅ | `token.bux`, `source_location.bux`, `types.bux`, `scope.bux`, `hir.bux` | ~771 |
| `7.2` Port lexer | ✅ | `lexer.bux` — full state machine, UTF-8, error reporting | 697 |
| `7.3` Port AST + parser | ✅ | `ast.bux` + `parser.bux` — Pratt parser, algebraic enums | ~1361 |
| `7.4` Port sema | ✅ | `sema.bux` — type checking, symbol resolution | 395 |
| `7.5` Port manifest | ✅ | `manifest.bux` — TOML/bux.toml parser | 86 |
| `7.6` Port HIR lowering | ✅ | `hir_lower.bux` — tree transformation | 309 |
| `7.7` Port C backend | ✅ | `c_backend.bux` — C code generator | 266 |
| `7.8` Port CLI | ✅ | `cli.bux` + `main.bux` — command dispatch | ~181 |
| `7.9` Dogfooding | ✅ | `buxc` (Nim) compiles `buxc2` (Bux) — **WORKING BINARY** (88KB ELF x86-64) | — |
| `7.10` Bootstrap loop | ✅ | `buxc2 check` works on all examples. `buxc2 build` generates valid C. | 7.9 |

### Phase 7.10 — Bootstrap Loop (Completed 2026-05-31)

**Status:** `buxc2 check` passes on **all examples**. `buxc2 build` generates valid C code that compiles with `gcc`.

**What works:**
- ✅ `buxc2 version` — shows version from command-line args
- ✅ `buxc2 check <file.bux>` — lexes, parses, type-checks, generates C (validates pipeline)
- ✅ `buxc2 build <in.bux> <out.c>` — generates C code
- ✅ **Struct init** — `TypeName { field: value, ... }` fully supported across all phases
- ✅ **Postfix `!`** (unwrap) + prefix `!` (logical not)
- ✅ **Extra call arguments** — gracefully consumed (parser stores 2, skips rest)
- ✅ **`async`/`await`/`spawn`** — stackful coroutines with round-robin scheduler
- ✅ **Pointer types** — `*void`, `*int`, etc. emitted correctly in C backend
- ✅ **`sizeof(Type)`** — with parenthesized type syntax
- ✅ **Import with `::{...}`** — multi-name import syntax

**`buxc2 check` status per module:**

| Module | Status | Notes |
|--------|--------|-------|
| `token` | ✅ Pass | 319 lines, int constants + helpers |
| `source_location` | ✅ Pass | 12 lines, simple struct |
| `types` | ✅ Pass | 185 lines, Type factories |
| `scope` | ✅ Pass | 47 lines, symbol table |
| `hir` | ✅ Pass | 205 lines, HIR node types + constructors |
| `manifest` | ✅ Pass | 79 lines, TOML parser |
| `c_backend` | ✅ Pass | 573 lines, C code generation |
| `cli` | ✅ Pass | 361 lines, CLI driver |
| `Main` | ✅ Pass | 16 lines, entry point |
| `ast` | ✅ Pass | 363 lines, complex enums/variants |
| `sema` | ✅ Pass | 397 lines, type checker |
| `hir_lower` | ✅ Pass | 490 lines, HIR lowering |
| `lexer` | ✅ Pass | 704 lines, UTF-8 state machine |
| `parser` | ✅ Pass | 1250 lines, Pratt parser |

**Self-hosted compiler stats:**
```
$ src/build/buxc2 version
Bux 0.2.0 (self-hosting bootstrap)
Pipeline modules:
  Lexer      ✅  695 lines
  Parser     ✅ 1004 lines
  Sema       ✅  393 lines
  HirLower   ✅  307 lines
  CBackend   ✅  264 lines
  Total: 3830 lines of Bux
```

**Bootstrap loop goal:**
```
buxc (Nim) → compile src/*.bux → buxc2 (Bux binary)
buxc2 (Bux) → compile src/*.bux → buxc3 (Bux binary)
compare buxc2 == buxc3 → SELF-HOSTED ✅
```

### Phase 7.9 — Completed 2026-05-31 🎉

**`buxc2` — Bux compiler written in Bux — builds and runs!**

```
$ ./buxc2 version
Bux Self-Hosting Compiler v0.2.0
Pipeline modules:
  Lexer      ✅  695 lines
  Parser     ✅ 1004 lines
  Sema       ✅  393 lines
  HirLower   ✅  307 lines
  CBackend   ✅  264 lines
  Total: 3830 lines of Bux
```

**All bugs fixed to achieve Phase 7.9:**
- ✅ Duplicate symbol — user funcs shadow stdlib funcs (`mergeDecls` in cli.nim)
- ✅ Parser infinite loop — keywords allowed as field names + advance-on-error safeguard
- ✅ `var` without initializer — optional `=` for var declarations (zero-init)
- ✅ Multi-line `||`/`&&` — continuation expressions across newlines
- ✅ Else-if chain newlines — newlines skipped between `}` and `else`
- ✅ Forward declarations — func decl without body followed by definition (both orderings)
- ✅ Extern func dedup — same extern declared in multiple files
- ✅ Type kind naming — `types.bux` uses `ty*` prefix, `token.bux` uses `tk*`
- ✅ Const emission — C backend emits `#define` for const declarations
- ✅ `discard` keyword — added as language keyword, lowered to expression statement or no-op
- ✅ C backend load optimization — `load(field_ptr(base, f))` → `base.f` (fixes lvalue errors)
- ✅ StringMap → `*void` workaround in sema.bux
- ✅ HirParam vs Param — field-by-field copy helper `Lcx_LowerParam`
- ✅ HirFunc array — dereference on assignment (`*f` instead of `f`)
- ✅ `ekReturn` removed — return is a statement, not expression
- ✅ `pathStr.len` → `String_Len(pathStr)` — String has no `.len` field
- ✅ String concatenation — `"*" + x` → `String_Concat("*", x)`
- ✅ `ReadFile`/`WriteFile` → `bux_read_file`/`bux_write_file` (avoid symbol conflicts)

**Deliverable:** `make selfhost` succeeds; Bux compiler is written entirely in Bux.

---

## Phase 8 — Advanced Language Features 🔄 (In Progress)

**Goal:** Features that make Bux competitive with Rust/Nim/Zig.

### 8.1 — Error Handling (Result/Option + `?` + `!` operators) ✅

| Task | Status | Details |
|------|--------|---------|
| `8.1.1` Result type | ✅ | `Result<T, E>` with `Ok(T)` and `Err(E)` constructors |
| `8.1.2` Option type | ✅ | `Option<T>` with `Some(T)` and `None` constructors |
| `8.1.3` `?` operator | ✅ | `expr?` desugars to: if `Err`/`None`, early-return from function |
| `8.1.4` `!` suffix | ✅ | `expr!` unwraps or panics (for prototyping) — parser, sema, HIR, C backend all implemented |

```bux
func ReadFile(path: String) -> Result<String, IoError> {
    let file = Open(path)?;        // early-returns Err if open fails
    let content = file.ReadAll()?; // early-returns Err if read fails
    return Ok(content);
}
```

### 8.2 — Ownership & Borrowing (Gradual Safety) ✅ (Basic Implementation Complete)

| Task | Status | Details |
|------|--------|---------|
| `8.2.1` `own` keyword | ✅ | `own T` parsed and resolves to `T`; ready for borrow checker integration |
| `8.2.2` `borrow` / `&` | ✅ | `&T` shared reference type checked and enforced |
| `8.2.3` `mut` references | ✅ | `&mut T` mutable reference type checked and enforced |
| `8.2.4` Lifetime elision | ⏳ | Simple rules for common cases; explicit `'a` for complex |
| `8.2.5` Opt-in checker | ✅ | `@[Checked]` attribute enables borrow checking: writes through `&T` are rejected |

```bux
// Opt-in safety — by default, Bux is permissive like Nim
func UnsafeSwap(a: *int, b: *int) {
    let tmp = *a;
    *a = *b;
    *b = tmp;
}

// Opt-in safety — with @[Checked], borrow checker kicks in
@[Checked]
func SafeSwap(a: &mut int, b: &mut int) {
    let tmp = *a;
    *a = *b;
    *b = tmp;
}
```

### 8.3 — Concurrency

| Task | Details |
|------|---------|
| `8.3.1` Tasks | Lightweight green threads (M:N scheduler) |
| `8.3.2` Channels | `Channel<T>` for message passing between tasks |
| `8.3.3` `async`/`await` | Async functions compile to state machines |
| `8.3.4` `Send`/`Sync` traits | Compile-time thread safety markers |
| `8.3.5` Atomics | `atomic<T>` type with memory ordering |

```bux
import Std::Task;
import Std::Channel;

func Producer(ch: Channel<int>) {
    for i in 0..100 {
        ch.Send(i);
    }
    ch.Close();
}

func Main() -> int {
    let (tx, rx) = Channel::New<int>();
    Task::Spawn(|| Producer(tx));
    for value in rx {
        PrintLine(value);
    }
    return 0;
}
```

### 8.4 — Compile-Time Function Execution (CTFE) ✅ (Basic Implementation Complete)

| Task | Status | Details |
|------|--------|---------|
| `8.4.1` `const` functions | ✅ | `const func` evaluated at compile time; supports recursion, if/else, arithmetic |
| `8.4.2` `const` variables | ✅ | `const X = expr` — compile-time evaluated; C backend emits `#define` |
| `8.4.3` Compile-time blocks | ✅ | `comptime { ... }` for arbitrary compile-time code |
| `8.4.4` Static assertions | ✅ | `static_assert(cond, msg)` for compile-time checks |
| `8.4.5` Generated code | ✅ | `#emit` for compile-time code generation |

```bux
const func Factorial(n: int) -> int {
    if n <= 1 { return 1; }
    return n * Factorial(n - 1);
}

const TABLE_SIZE = Factorial(10);  // Computed at compile time
```

### 8.5 — Trait System (Interfaces++) ✅ (Basic Implementation)

| Task | Status | Details |
|------|--------|---------|
| `8.5.1` Traits | ✅ | `interface` + `extend Type for Interface` |
| `8.5.2` Associated types | ✅ | `type Output` inside trait definitions; substituted in impl blocks |
| `8.5.3` Trait bounds | ✅ | `func Sort<T: Comparable>(arr: &mut Array<T>)` — semantic check at call sites |
| `8.5.4` Trait objects | ✅ | `&dyn Trait` for dynamic dispatch (fat pointer) |
| `8.5.5` Blanket impls | ⏳ | `impl<T: Display> Printable for T` |

### 8.6 — Metaprogramming

| Task | Details |
|------|---------|
| `8.6.1` Declarative macros | `macro! Name { ... }` pattern-matching macros |
| `8.6.2` Procedural macros | `#[derive(Clone)]`, `#[derive(Debug)]` |
| `8.6.3` Reflection | Compile-time type introspection for serialization |

### 8.7 — Optimization & Release Mode

**Goal:** C-speed for hot paths. `@[Release]` disables all runtime checks and inlines auto-drop.

| Task | Status | Details |
|------|--------|---------|
| `8.7.1` `@[Release]` attribute | ⏳ | Disables bounds checking, borrow checking, null checks inside the function |
| `8.7.2` Auto-drop inline | ⏳ | Emit `free`/`close` directly instead of `Type_Drop(&var)` call |
| `8.7.3` Dead-store elimination | ⏳ | C backend removes redundant temp variables (`_t1`, `_t2`) |
| `8.7.4` `-O3` by default | ⏳ | `bux build --release` passes `-O3 -flto` to C compiler |
| `8.7.5` Profile-guided optimization | ⏳ | `bux profile` + `bux build --pgo` for guided inlining |

```bux
// Default: safe but slower — bounds checks + borrow checks
@[Checked]
func SafeSum(arr: Array<int>) -> int { ... }

// Hot path: zero-cost — straight C
@[Release]
func HotLoop(data: *float64, n: int) {
    for i in 0..n {
        data[i] = data[i] * 2.0;  // no bounds check, inlined
    }
}
```

**Why this matters:** Nim compiles to C but has ARC/ORC overhead. Crystal has Boehm GC. Bux with `@[Release]` has **literally zero overhead** — the generated C is hand-written quality.

---

## Phase 9 — Ecosystem & Tooling (Week 35+)

| Task | Status | Details |
|------|--------|---------|
| `9.1` Package manager | ✅ | `bux add`, `bux install`, `bux.lock` — path-based and git-based deps |
| `9.2` Registry protocol | ⏳ | Simple HTTP git-based registry (like Go modules or Cargo) |
| `9.3` Formatter | ⏳ | `bux fmt` — auto-format Bux source |
| `9.4` LSP | ⏳ | Language Server Protocol for autocomplete, hover, go-to-definition |
| `9.5` Tests | ⏳ | `bux test` runner with assertions and golden tests |
| `9.6` Documentation | ⏳ | `bux doc` — generate HTML from `///` doc comments |
| `9.7` Cross-compilation | ⏳ | `--target` flag leveraging C backend portability |
| `9.8` Debugger support | ⏳ | DWARF/PDB debug info generation for gdb/lldb/VSCode |
| `9.9` Profiler integration | ⏳ | `bux build --profile` with basic profiling hooks |

---

## File Structure (v0.3.0 — Current)

```
bux/
├── bux.toml                  # Bootstrap compiler manifest (v0.3.0)
├── README.md
├── PLAN.md                   # This file
├── Makefile                  # build, test, selfhost
├── src/                      # 🎯 CANONICAL: Bux compiler source
│   ├── bux.toml              # Self-host compiler manifest
│   ├── main.bux              # Entry point (renamed → Main.bux at build)
│   ├── lexer.bux             # Tokenizer (UTF-8 state machine, 697 LOC)
│   ├── parser.bux            # Pratt parser (1004 LOC)
│   ├── ast.bux               # AST node types (algebraic enums)
│   ├── sema.bux              # Type checker / semantic analysis (393 LOC)
│   ├── types.bux             # Type factories
│   ├── scope.bux             # Symbol table
│   ├── hir.bux               # High-level IR definitions
│   ├── hir_lower.bux         # AST → HIR lowering (307 LOC)
│   ├── c_backend.bux         # HIR → C code generator (264 LOC)
│   ├── cli.bux               # CLI command dispatch
│   ├── manifest.bux          # bux.toml / TOML parser
│   ├── token.bux             # Token kind definitions
│   └── source_location.bux   # Source location tracking
├── bootstrap/                # 🔧 Nim bootstrap (build scaffold only)
│   ├── main.nim              # Entry point
│   ├── cli.nim               # CLI commands + build driver
│   └── ...                   # (mirrors src/ structure)
├── lib/                      # 📦 Standard library (23 modules)
│   ├── Io.bux                # Print, ReadFile, WriteFile
│   ├── String.bux            # Full string API (len, concat, split, format...)
│   ├── Array.bux             # Generic Array<T>
│   ├── Map.bux               # Generic Map<K,V> + StringMap
│   ├── Set.bux               # Generic Set<T>
│   ├── Math.bux              # Sqrt, Pow, Min, Max, Abs
│   ├── Mem.bux               # Alloc, Realloc, Free
│   ├── Path.bux              # Path_Join, Path_Parent, Path_Ext
│   ├── Fs.bux                # DirExists, Mkdir, ListDir
│   ├── Task.bux              # Lightweight tasks (spawn/await)
│   ├── Channel.bux           # Producer/consumer channels
│   ├── Sync.bux              # Mutex, RwLock
│   ├── Result.bux            # Result<T,E> + Option<T> + ? operator
│   ├── Iter.bux              # Iterator trait
│   ├── Fmt.bux               # String formatting
│   ├── Os.bux                # Args, Env, Exit, Cwd
│   ├── Time.bux              # Time measurement
│   ├── Process.bux           # Subprocess spawning
│   ├── Net.bux               # TCP client/server
│   ├── Crypto.bux            # SHA256, HMAC, Base64
│   ├── Json.bux              # JSON parse/stringify
│   └── Test.bux              # Test framework
├── rt/                       # ⚙️ C runtime
│   ├── runtime.c             # Memory, string, path helpers
│   └── io.c                  # File I/O wrappers
├── tests/                    # 🧪 Unit tests (Nim)
│   ├── lexer_test.nim
│   ├── parser_test.nim
│   ├── sema_test.nim
│   ├── hir_test.nim
│   ├── borrow_test.nim
│   └── testdata/
├── examples/                 # Example programs
├── docs/                     # Documentation
│   ├── LanguageRef.md
│   ├── BuildAndTest.md
│   ├── STRATEGY.md
│   ├── PHASE8_STRATEGY.md
│   └── Packages.md
├── build/                    # Build artifacts (gitignored)
│   └── selfhost/             # Self-host compiler build dir
└── vendor/                   # Vendored dependencies
```

---

## Phase 10 🔄 — Path to v1.0.0 (In Progress)

### 10.0 — v0.3.0 Restructuring ✅ (Completed 2026-06-06)

| Task | Status | Details |
|------|--------|---------|
| Directory restructure | ✅ | `compiler/selfhost/` → `src/`, `compiler/bootstrap/` → `bootstrap/`, `library/std/` → `lib/`, `library/runtime/` → `rt/`, `compiler/tests/` → `tests/` |
| Path updates | ✅ | Updated Makefile, cli.nim, cli.bux, test files, docs |
| Selfhost fix | ✅ | Build via `build/selfhost/` (project wrapper) |
| Push to GitHub | ✅ | `ac969b3` — v0.3.0 restructure |

### 10.1 — Selfhost Loop ✅ (v0.5.0 target)

**Goal:** `buxc2` can compile itself producing a binary-identical `buxc3`.

```
buxc (Nim) → src/*.bux → buxc2 ✅
buxc2       → src/*.bux → buxc3 ✅
buxc2 == buxc3            ✅ (binary-identical)
```

| Task | Status | Details |
|------|--------|---------|
| `10.1.1` Verify buxc2 can build src/ | ✅ | `buxc2 build` works on selfhost project |
| `10.1.2` Deterministic C codegen | ✅ | C output identical on every iteration |
| `10.1.3` Binary-identical loop | ✅ | `make selfhost-loop` passes (C + ELF parity) |
| `10.1.4` Remove hardcoded paths | ✅ | Paths resolved via `bux_getcwd()` / `bux_path_join()` |
| `10.1.5` Selfhost test in CI | ⏳ | Add to `make test` |

### 10.2 — Gradual Ownership ✅ (v0.5.0 target) ⭐ Killer Feature

**Goal:** `@[Checked]` functions get full borrow checking. `@[Release]` disables checks for zero-cost hot paths.

| Task | Status | Details |
|------|--------|---------|
| `10.2.1` `@[Checked]` attribute gate | ✅ | Enable/disable borrow checker per function |
| `10.2.2` `&T` shared reference check | ✅ | No mutation through shared refs |
| `10.2.3` `&mut T` exclusive mutable check | ✅ | No aliasing of mutable refs |
| `10.2.4` Bounds checking on slices | ✅ | `Slice_Get` / `Array_Get` with `bux_bounds_check` |
| `10.2.5` `@[Release]` zero-cost mode | ✅ | Disables borrow + bounds checks, passes `-O3 -flto` |
| `10.2.6` Lifetime elision (simple rules) | ⏳ | 80% of cases without annotations |
| `10.2.7` Explicit lifetimes `'a` | ⏳ | Only for complex cases |

### 10.3 — Compiler Architecture Upgrade (v0.6.0 target)

**Goal:** Proper module structure instead of flat file mirror of Nim bootstrap.

```
src/
├── main.bux
├── frontend/
│   ├── lexer.bux
│   ├── parser.bux
│   └── ast.bux
├── analysis/
│   ├── sema.bux
│   ├── types.bux
│   ├── scope.bux
│   └── borrow.bux       # NEW — borrow checker
├── lowering/
│   ├── hir.bux
│   └── hir_lower.bux
├── backend/
│   └── c_backend.bux
└── driver/
    ├── cli.bux
    ├── manifest.bux
    ├── token.bux
    └── source_location.bux
```

### 10.4 — Stdlib Completion (v0.7.0 target)

| Module | Status | Priority |
|--------|--------|----------|
| `Std::Os` — Args, Env, Exit, Cwd | ⏳ | P0 |
| `Std::Process` — spawn subprocess | ⏳ | P0 |
| `Std::Iter` — map, filter, fold | ⏳ | P1 |
| `Std::Fmt` — string interpolation | ⏳ | P1 |

### 10.5 — Tooling (v0.8.0 target)

| Tool | Status | Priority |
|------|--------|----------|
| `bux test` — test runner | ⏳ | P0 |
| `bux fmt` — code formatter | ⏳ | P1 |
| `bux doc` — doc generator | ⏳ | P2 |

### 10.6 — Native Backend (v0.9.0 target)

| Task | Status |
|------|--------|
| Direct x86-64 codegen (no C) | ⏳ |
| ELF64 output | ⏳ |
| System V AMD64 ABI | ⏳ |

### 10.7 — v1.0.0 Release Criteria

- [ ] Compiler self-hosts binary-identically
- [ ] `@[Checked]` borrow checker works on real code
- [ ] Stdlib complete enough for CLI tools
- [ ] `bux test`, `bux fmt`, `bux doc` exist
- [ ] Documentation + 30+ examples
- [ ] CI/CD pipeline (build + test on push)

---

## Language Design Decisions (Bux Improvements)

### What Bux learns from Rust
| Rust feature | Bux adaptation |
|-------------|----------------|
| Ownership/borrowing | **Opt-in** via `@[Checked]` — not forced on everyone |
| `Result`/`Option` + `?` | Adopted directly |
| Traits | Adopted as "interfaces" with default methods |
| Cargo | `bux.toml` + package manager |
| `rustfmt` | `bux fmt` built-in |
| Pattern matching | Adopted (already in AST) |

### What Bux learns from Nim
| Nim feature | Bux adaptation |
|-------------|----------------|
| Fast compilation | C transpiler backend (leverages C compiler speed) |
| CTFE | `const func` + `comptime` blocks |
| Clean syntax | Less noisy than Rust (no `::` turbofish, simpler generics) |
| Macro system | Declarative macros with pattern matching |
| Pragmatic approach | Gradual safety — start permissive, add checks as needed |

---

## Syntax Preview

```bux
import Std::Io::{PrintLine, Print};
import Std::Result::{Result, Ok, Err};
import Std::Array::Array;

// Struct with generic type parameter
struct Stack<T> {
    items: Array<T>,
    len: uint,
}

// Trait (interface) with default implementation
interface Display {
    func ToString(self: &Self) -> String;
    
    func Display(self: &Self) {
        PrintLine(self.ToString());
    }
}

// Implement trait for struct
extend Stack<T> for Display {
    func ToString(self: &Stack<T>) -> String {
        return Format("Stack(len={})", self.len);
    }
}

// Function with Result return type and ? operator
func Divide(a: int, b: int) -> Result<int, String> {
    if b == 0 {
        return Err("division by zero");
    }
    return Ok(a / b);
}

// Async function
async func FetchData(url: String) -> Result<String, IoError> {
    let response = Http::Get(url).await?;
    return Ok(response.Body);
}

// Compile-time function
const func Fibonacci(n: int) -> int {
    if n <= 1 { return n; }
    return Fibonacci(n - 1) + Fibonacci(n - 2);
}

const FIB_20 = Fibonacci(20);  // Computed at compile time

// Main entry point
func Main() -> int {
    // Error handling with ?
    let result = Divide(10, 2)?;
    PrintLine("10 / 2 = {}", result);
    
    // Pattern matching on algebraic enum
    match result {
        Ok(value) => PrintLine("Got: {}", value),
        Err(msg) => PrintLine("Error: {}", msg),
    }
    
    return 0;
}
```

---

## Milestones Summary

| Milestone | Phase | Status | Success Criteria |
|-----------|-------|--------|------------------|
| **M0** | 0 | ✅ | `bux check` lexes source |
| **M1** | 1 | ✅ | All frontend test files parse |
| **M2** | 2 | ✅ | Type-checker rejects invalid programs |
| **M3** | 3 | ✅ | HIR lowering works for all constructs |
| **M4** | 5A | ✅ | `bux run` produces working binary via C transpiler |
| **M5** | 6 | ✅ | Can write compiler-adjacent tools in Bux (26 examples) |
| **M6** | 7 | ✅ | **Self-hosted**: `buxc2` (Bux) compiles via `buxc` (Nim) — working binary |
| **M7** | 8 | ✅ | Result/Option/`?`/`!` done; **borrow checker working**; **CTFE working** |
| **M8** | 8-9 | ✅ | **Borrow checker**, **CTFE**, **Package manager** working |
| **M9** | 8.5 | ✅ | **Trait bounds** (`<T: Comparable>`) — semantic checking implemented |
| **M10** | 10 | ✅ | **LIR backend** replaces HIR→C; 26/26 examples pass; selfhost builds |
| **M11** | 11 | ✅ | **Selfhost loop**: `buxc2` compiles itself → binary-identical `buxc3` |
| **M12** | 11.3 | ✅ | `@[Checked]` borrow checker works on real code |
| **M13** | 11.4 | ✅ | `@[Release]` zero-cost mode; Rust-style error snippets |
| **M14** | 8.3 | ✅ | **Green threads** — M:N scheduler with channels |
| **M15** | 11.5 | ⏳ | Native x86-64 backend (no C transpiler) |
| **M16** | 11.4 | ⏳ | `bux test`, `bux fmt`, `bux doc` shipped |

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Nim bootstrap too slow | Keep Nim code simple; aim for rewrite in ~3 months |
| C backend limits performance | Maintain parallel native backend; C is only bootstrap |
| Generics get complex | Restrict to monomorphization; no higher-kinded types initially |
| Self-hosting too hard | Ensure stdlib has `Array`, `Map`, `String`, `Result` before starting rewrite |
| Ownership model too complex | Make it opt-in; default is permissive (like Nim) |
| Concurrency runtime overhead | Green threads are optional; core language works without runtime |

---

## Next Immediate Steps (Updated 2026-05-31 — Session #2)

### Completed Today (Session #2 — 14 commits!)
1. ✅ **Struct init** — `TypeName { field: value }` across all 4 phases (parser, sema, hir_lower, c_backend)
2. ✅ **`structInitAllowed`** — Properly disabled in if/while/for/match conditions
3. ✅ **Postfix `!`** (unwrap) + prefix `!` (logical not) — Both parsed correctly
4. ✅ **Extra call args** — Gracefully consumed (parser stores 2, skips rest)
5. ✅ **Infinite-loop guards** — Block parser, match parser, struct init parser
6. ✅ **Null-safe C runtime** — `bux_strcmp`, `bux_strcpy`, `bux_strncmp` handle NULL
7. ✅ **C codegen improvements:**
   - Type aliases (`typedef const char* String; uint8/int64/float64...`)
   - Forward declarations for all functions
   - Runtime declarations (`bux_alloc`, `bux_free`)
   - Struct definitions with forward type declarations
   - Pointer types for let/cast (`String*`)
   - Cast uses actual target type
   - Null literal → `0`
8. ✅ **While/loop** — Full C emission with body
9. ✅ **Array indexing** — `arr[i]` via `hIndexPtr`
10. ✅ **Assignments** — `ekBinary(tkAssign)` → `hAssign`
11. ✅ **Field access** — `obj->field` via `hFieldPtr`
12. ✅ **`sizeof(Type)`** — via `hSizeOf`
13. ✅ **Keyword-as-identifier** — `module`, `type`, `enum` as field/param names
14. ✅ **`buxc2 project` produces working binary** — Simple projects compile and run!

### Current Status: `buxc2 check` 11/14 (79%)

| Passing | Status |
|---------|--------|
| token, source_location, types, scope, hir, sema, manifest, hir_lower, c_backend, cli, Main | ✅ |
| ast, lexer, parser | ❌ (3 remaining) |

### `buxc2 project` — Multi-file build

- ✅ Pipeline works (Scan→Parse→Merge→Sema→HIR→CBackend→CC)
- ✅ Simple projects compile to working ELF binaries
- ⏳ 11-module project: pipeline processes but C compilation has type errors (parameter types)
- ⏳ Full 14-module: ast/lexer/parser crash

### Next Actions (Priority Order)

1. ✅ **Fix LIR backend type inference** — struct temps, undeclared vars, break/continue, duplicate declarations
2. ✅ **All 30 examples passing** — bootstrap and self-host compilers build and run every example
3. ✅ **Selfhost build working** — `make selfhost` produces working `buxc2`
4. ✅ **Selfhost loop verification** — `buxc2` compiles `src/` → `buxc3`; C output and stripped binary identical
5. ✅ **Golden tests for C codegen** — `make test-golden` passes for 8 critical examples
6. ✅ **`bux test` runner** — discovers `tests/*.bux`, builds each as a temp package, and reports PASS/FAIL

---

## Phase 11 — Post-LIR Stabilization & Path to v0.4.0 🔄

### 11.1 — LIR Backend Hardening (v0.3.1)

| Task | Status | Priority | Details |
|------|--------|----------|---------|
| `11.1.1` Golden tests for C codegen | ⏳ | P0 | Expected `.c` output for 5–6 critical examples; diff on regression |
| `11.1.2` LIR debug dump | ⏳ | P1 | `bux build --emit-lir` produces readable LIR |
| `11.1.3` Type info in `LirInstr` | ⏳ | P1 | Add `cType` field to instructions; eliminate inference hacks |
| `11.1.4` Dead code cleanup | ⏳ | P2 | Remove unused `typeFromValue`, `setTempType`, `emit` |

### 11.2 — Selfhost Loop (v0.4.0) ⭐

| Task | Status | Priority | Details |
|------|--------|----------|---------|
| `11.2.1` `buxc2 build` on `src/` | ✅ | P0 | Verify selfhost compiler can build itself |
| `11.2.2` Deterministic C codegen | ✅ | P0 | Remove non-deterministic ordering in `emitModule` |
| `11.2.3` `make selfhost-loop` | ✅ | P0 | Makefile target: buxc2 → buxc3 → binary compare |
| `11.2.4` Cross-module generics in selfhost | ⏳ | P1 | `Map<K,V>` and `Array<T>` from stdlib in selfhost context |

### 11.3 — Gradual Ownership (v0.5.0) ⭐⭐

| Task | Status | Priority | Details |
|------|--------|----------|---------|
| `11.3.1` `&T` / `&mut T` lifetime analysis | ⏳ | P0 | Basic borrow checker integrated in LIR lowering |
| `11.3.2` Bounds checking on slices | ⏳ | P0 | `Slice<T>` index checks `.len` at runtime |
| `11.3.3` Lifetime elision (simple rules) | ⏳ | P1 | 80% of cases without explicit annotations |

### 11.4 — Tooling & Ecosystem (v0.6.0–v0.8.0)

| Task | Status | Priority | Details |
|------|--------|----------|---------|
| `11.4.1` `bux test` runner | ✅ | P0 | Built-in test framework with assertions |
| `11.4.2` `bux fmt` formatter | ⏳ | P1 | Auto-format Bux source |
| `11.4.3` LSP prototype | ⏳ | P2 | Autocomplete, hover types, go-to-definition |
| `11.4.4` `bux doc` generator | ⏳ | P2 | HTML from `///` doc comments |

### 11.5 — Native Backend (v0.9.0)

| Task | Status | Priority | Details |
|------|--------|----------|---------|
| `11.5.1` x86-64 codegen (no C) | ⏳ | P1 | ELF64 output, System V AMD64 ABI |
| `11.5.2` Custom linker / `.bcu` format | ⏳ | P2 | Bespoke object format for faster builds |

---

## Open Design Questions

1. **Syntax for ownership**: Should Bux use `own` keyword or Rust-style move semantics?
2. **Async runtime**: M:N green threads (Go-style) or 1:1 OS threads (Rust-style)?
3. **Macro system**: Declarative-only or also procedural macros?
4. **Package registry**: Centralized (crates.io) or decentralized (Go modules)?
5. **LLVM backend**: Should Bux support LLVM as an optional backend, or stay fully self-contained?

---

## Appendix A: Bux Token Reference

Complete token list from the lexer:

### Literals
`tkIntLiteral`, `tkFloatLiteral`, `tkStringLiteral`, `tkCharLiteral`, `tkBoolLiteral`

### Keywords
- **Control flow:** `if`, `else`, `while`, `do`, `loop`, `for`, `in`, `break`, `continue`, `return`, `match`
- **Declarations:** `func`, `let`, `var`, `const`, `type`, `struct`, `enum`, `union`, `interface`, `extend`, `module`, `import`, `pub`, `extern`
- **Other:** `as`, `is`, `null`, `self`, `super`, `sizeof`

### Operators
- **Arithmetic:** `+`, `-`, `*`, `/`, `%`, `**`, `++`, `--`
- **Bitwise:** `&`, `|`, `^`, `~`, `<<`, `>>`
- **Logical:** `&&`, `||`, `!`
- **Comparison:** `==`, `!=`, `<`, `<=`, `>`, `>=`
- **Assignment:** `=`, `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `|=`, `^=`, `<<=`, `>>=`

### Punctuation
`(`, `)`, `{`, `}`, `[`, `]`, `,`, `;`, `:`, `::`, `.`, `..`, `...`, `..=`, `->`, `=>`, `@`, `#`, `?`

### Compile-time Intrinsics
`#line`, `#column`, `#file`, `#function`, `#date`, `#time`, `#module`

---

## Appendix B: Build & Tooling Commands

```bash
# Build the bootstrap compiler (Nim)
make build

# Run tests
make test

# Create a new Bux project
bux new myproject

# Build a Bux project
bux build

# Run a Bux project
bux run

# Type-check without building
bux check

# Clean build artifacts
bux clean

# Show version
bux version

# Future commands (Phase 8+)
bux fmt          # Format code
bux test         # Run tests
bux doc          # Generate documentation
bux add <pkg>    # Add dependency
bux lsp          # Start language server
```
