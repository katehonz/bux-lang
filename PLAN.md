# Bux Programming Language — Roadmap to Self-Hosting

> **Reference:** [Rux Language](https://rux-lang.dev/) | [Rux Source](../_rux/)  
> **Bootstrap Implementation:** Nim  
> **Target:** Bux compiler written in Bux (self-hosting)

---

## Overview

Bux is a fast, compiled, strongly-typed, multi-paradigm systems programming language inspired by Rux. The strategy is **bootstrap via Nim** — we build the first Bux compiler in Nim, then progressively rewrite it in Bux until it compiles itself.

---

## Phase 0 — Bootstrap Foundation (Week 1-2)

**Goal:** Working Nim project that can lex, parse, and dump a Bux AST.

| Task | Details |
|------|---------|
| `0.1` Project skeleton | `buxc` CLI in Nim, `bux.toml` manifest parser |
| `0.2` Token model | All Rux tokens (`TokenKind`, `SourceLocation`, literal suffixes) |
| `0.3` Lexer | UTF-8 source, identifiers, numbers (dec/hex/bin/oct), strings (`c8""`, `c16""`, `c32""`), chars, operators, nested `/* */`, `//` comments, intrinsics (`#line`, `#file`, etc.) |
| `0.4` CLI commands | `bux new`, `bux init`, `bux build`, `bux run`, `bux check` |
| `0.5` Test harness | Golden-file tests for lexer output (`.tokens`) |

**Deliverable:** `echo 'let x = 42' | bux check` prints token stream.

---

## Phase 1 — Frontend: Parser & AST (Week 3-4)

**Goal:** Parse every construct present in Rux v0.2.0 into a Nim AST.

| Task | Details |
|------|---------|
| `1.1` AST nodes | All `Expr`, `Stmt`, `Decl`, `Pattern`, `TypeExpr`, `Block` variants (see `_rux/Include/Rux/Ast.h`) |
| `1.2` Pratt parser | Full precedence climbing for all binary/unary/postfix operators including `**` (right-assoc) and range `..` / `..=` |
| `1.3` Declarations | `func`, `struct`, `enum`, `union`, `interface`, `extend`/`impl`, `module`, `const`, `type`, `extern`, `import`/`use` |
| `1.4` Statements | `let`/`var`, `if`/`else if`/`else`, `while`, `do while`, `loop`, `for in`, `match`, `return`, `break`/`continue` (with labels) |
| `1.5` Expressions | Literals, identifiers, paths (`a::b`), calls, index, field access, struct init, slice init `[a,b]`, tuple `(a,b)`, cast `as`, test `is`, ternary `? :`, block-expr `{ ... }` |
| `1.6` Patterns | Wildcard `_`, literal, ident, range, enum destructuring, struct destructuring, tuple, guarded `if` |
| `1.7` Attributes | `@[Import(lib: "...")]`, calling-convention, platform-conditional imports |
| `1.8` Error recovery | Synchronize on declaration/statement boundaries; emit multiple diagnostics |

**Deliverable:** All `_rux/Tests/**/*.rux` files parse without error and produce `.ast` dumps.

---

## Phase 2 — Semantic Analysis (Week 5-7)

**Goal:** Type-check the AST and produce a typed symbol table.

| Task | Details |
|------|---------|
| `2.1` Type model | `TypeRef` with primitives, pointers, slices, tuples, named types, type parameters, functions (see `_rux/Include/Rux/Type.h`) |
| `2.2` Scopes | Module scope, block scope, namespace resolution for `Std::Io::PrintLine` |
| `2.3` First pass | Collect global symbols (functions, structs, enums, unions, interfaces, consts, type aliases, imports) |
| `2.4` Type checking | Expression typing, operator overload resolution per Rux rules, assignment compatibility |
| `2.5` Name resolution | Resolve identifiers, paths, `self`, `super`; report undeclared / ambiguous names |
| `2.6` Interface conformance | Check that `extend T for I` provides all required methods; build vtable map |
| `2.7` Generics (basic) | Monomorphization of generic structs and functions at call sites |
| `2.8` Diagnostics | Multi-file error messages with source locations |

**Deliverable:** `bux check` rejects ill-typed programs and passes `Tests/Echo`, `Tests/Io`, `Tests/Pow` type-checking.

---

## Phase 3 — High-Level IR (HIR) (Week 8)

**Goal:** Lower AST to a simplified, fully-typed HIR.

| Task | Details |
|------|---------|
| `3.1` HIR nodes | Desugared equivalents of AST nodes (see `_rux/Include/Rux/Hir.h`) |
| `3.2` Lowering | Desugar `for` → `while`+iterator, `match` → decision tree, method calls to explicit receiver calls |
| `3.3` Constant folding | Evaluate `const` and simple compile-time expressions |
| `3.4` Interface lowering | Convert interface values to fat pointers `{data_ptr, vtable_ptr}`; generate vtable labels |

**Deliverable:** HIR dump matches Rux HIR semantics for sample programs.

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

### 5A — C Transpiler (Primary bootstrap path)

| Task | Details |
|------|---------|
| `5A.1` C emitter | Walk LIR and emit C11 code |
| `5A.2` Types to C | Bux primitives → C primitives; structs → C structs; enums → C enums + tagged unions; slices → `{T* data; size_t len;}` |
| `5A.3` Functions to C | Bux functions → C functions with `static` / `extern`; name mangling for overloads/generics |
| `5A.4` FFI | `extern` / `@[Import]` → `#include` + function declarations; link with system `cc` |
| `5A.5` Runtime shim | Small C runtime providing `bux_alloc`, `bux_print`, panic/abort for div-by-zero, etc. |
| `5A.6` Build integration | `bux build` invokes `cc` / `clang` / `gcc` automatically |

**Deliverable:** `bux run` on `Tests/Io/Main.bux` prints "Hello from a Bux binary!".

### 5B — Native x86-64 Backend (Secondary, for self-hosting speed)

| Task | Details |
|------|---------|
| `5B.1` Assembly emitter | NASM-syntax text output (like Rux `Asm`) |
| `5B.2` Register allocation | Naive stack-spill allocator first; later linear-scan |
| `5B.3` ABI lowering | System V AMD64 ABI (Linux/macOS) and Win64 ABI (Windows) |
| `5B.4` Object format | Emit ELF64 (Linux), Mach-O (macOS), PE/COFF (Windows) — or use `nasm` + system linker |
| `5B.5` Custom linker (optional) | `.bcu` (Bux Compiled Unit) format + bespoke linker à la Rux `.rcu` |

**Deliverable:** `bux build --backend=native` produces working Linux x86-64 binary.

---

## Phase 6 — Standard Library (Week 15-18)

**Goal:** Enough stdlib to write the compiler in Bux.

| Module | Requirements |
|--------|-------------|
| `Std::Io` | `Print`, `PrintLine`, `ReadLine`, file read/write (wrap C stdio initially) |
| `Std::Memory` | `Alloc`, `Free`, `Realloc` (wrap `malloc`/`free`) |
| `Std::String` | Basic string builder, concatenation, slicing |
| `Std::Array` | Dynamic array (`Vec<T>` equivalent): `push`, `pop`, `get`, `len`, `capacity` |
| `Std::Map` | Hash map with string keys (needed for symbol tables) |
| `Std::Math` | `Sqrt`, `Pow`, `Min`, `Max`, `Abs` |
| `Std::Os` | `Args`, `Env`, `Exit`, `Cwd` |
| `Std::Path` | Path joining, extension splitting |
| `Std::Process` | Spawn subprocess, read stdout/stderr |

**Deliverable:** Can write a non-trivial CLI tool (e.g., a file copier or a basic grep) entirely in Bux.

---

## Phase 7 — Self-Hosting: The Great Rewrite (Week 19-26)

**Goal:** Bux compiler compiles itself. This is the **main milestone**.

| Task | Details |
|------|---------|
| `7.1` Port lexer | Rewrite `lexer.nim` → `Lexer.bux` |
| `7.2` Port parser | Rewrite `parser.nim` → `Parser.bux` |
| `7.3` Port sema | Rewrite `sema.nim` → `Sema.bux` |
| `7.4` Port HIR | Rewrite `hir.nim` → `Hir.bux` |
| `7.5` Port LIR | Rewrite `lir.nim` → `Lir.bux` |
| `7.6` Port C backend | Rewrite `c_backend.nim` → `CBackend.bux` |
| `7.7` Port CLI | Rewrite `main.nim` → `Main.bux` |
| `7.8` Dogfooding | Use `buxc` (Nim) to build `buxc2` (Bux). Then use `buxc2` to build `buxc3`. Compare bit-for-bit. |
| `7.9` Fix bootstrap loop | Once `buxc2 == buxc3`, we are self-hosted. Freeze Nim version as reference. |

**Deliverable:** `make selfhost` succeeds; Bux compiler is written entirely in Bux.

---

## Phase 8 — Ecosystem & Tooling (Week 27+)

| Task | Details |
|------|---------|
| `8.1` Package manager | `bux add`, `bux remove`, `bux update`, `bux install` with lockfile |
| `8.2` Registry protocol | Simple HTTP git-based registry (like Go modules or Cargo) |
| `8.3` Formatter | `bux fmt` — auto-format Bux source |
| `8.4` LSP | Language Server Protocol for autocomplete, hover, go-to-definition |
| `8.5` Tests | `bux test` runner with assertions and golden tests |
| `8.6` Documentation | `bux doc` — generate HTML from `///` doc comments |
| `8.7` Cross-compilation | `--target` flag leveraging C backend portability |

---

## File Structure (Target)

```
bux/
├── bux.toml                  # Compiler package manifest
├── README.md
├── PLAN.md
├── Makefile                  # build, test, selfhost
├── src/
│   ├── Main.bux              # CLI entry point
│   ├── Lexer.bux
│   ├── Parser.bux
│   ├── Ast.bux
│   ├── Sema.bux
│   ├── Type.bux
│   ├── Hir.bux
│   ├── Lir.bux
│   ├── CBackend.bux          # C transpiler (primary backend)
│   ├── X64Backend.bux        # Native x86-64 backend (optional)
│   ├── Linker.bux            # Custom linker / build driver
│   ├── Manifest.bux          # bux.toml parser
│   └── Package.bux           # Package resolution
├── stdlib/
│   ├── Std/
│   │   ├── Io.bux
│   │   ├── Memory.bux
│   │   ├── String.bux
│   │   ├── Array.bux
│   │   ├── Map.bux
│   │   ├── Math.bux
│   │   ├── Os.bux
│   │   ├── Path.bux
│   │   └── Process.bux
│   └── Runtime.c             # C runtime shim
├── tests/
│   ├── Lexer/
│   ├── Parser/
│   ├── Sema/
│   ├── Codegen/
│   └── Integration/
└── docs/
    └── LanguageRef.md
```

---

## Language Design Decisions (Bux vs Rux)

| Feature | Bux Decision | Rationale |
|---------|-------------|-----------|
| **Backend (bootstrap)** | C transpiler first | Fastest path to working compiler; leverages existing C toolchains |
| **Backend (final)** | Native x86-64 + optional LLVM | Match Rux ambition; self-hosting needs speed |
| **Memory safety** | Raw pointers + optional borrow checker (Phase 9) | Match Rux current model; gradual safety |
| **Generics** | Monomorphization only | Simpler than Rust-style trait objects; enough for self-hosting |
| **Error handling** | Explicit `Result<T, E>` + `?` operator (later) | Start with C-style returns; add sugar after self-hosting |
| **String literals** | `c8""`, `c16""`, `c32""` + `""` defaulting to `c8` | Same as Rux |
| **Build system** | `bux.toml` (same as `Rux.toml`) | Compatible manifest format |
| **Module system** | `import Std::Io::PrintLine` | Same as Rux path syntax |

---

## Milestones Summary

| Milestone | Phase | Success Criteria |
|-----------|-------|------------------|
| **M0** | 0 | `bux check` lexes source |
| **M1** | 1 | All Rux test files parse |
| **M2** | 2 | Type-checker rejects invalid programs |
| **M3** | 3+4 | LIR emits for all constructs |
| **M4** | 5A | `bux run` produces working binary via C |
| **M5** | 6 | Can write compiler-adjacent tools in Bux |
| **M6** | 7 | **Self-hosted**: Bux compiler builds itself |
| **M7** | 8 | Package manager + LSP + formatter shipped |

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Nim bootstrap too slow | Keep Nim code simple; aim for rewrite in ~3 months |
| C backend limits performance | Maintain parallel native backend; C is only bootstrap |
| Generics get complex | Restrict to monomorphization; no higher-kinded types |
| Self-hosting too hard | Ensure stdlib has `Array`, `Map`, `String` before starting rewrite |

---

## Next Immediate Step

Create the Nim bootstrap skeleton and implement the **Lexer** (`0.1`–`0.3`).
