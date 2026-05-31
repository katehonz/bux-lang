# Bux Programming Language — Roadmap to Self-Hosting

> **Reference:** [Rux Language](https://rux-lang.dev/) | [Rux Source](../_rux/)
> **Bootstrap Implementation:** Nim
> **Target:** Bux compiler written in Bux (self-hosting)

---

## Overview

Bux is a fast, compiled, strongly-typed, multi-paradigm systems programming language inspired by Rux, Rust, and Nim. The strategy is **bootstrap via Nim** — we build the first Bux compiler in Nim, then progressively rewrite it in Bux until it compiles itself.

**Core philosophy:** Systems-level control with modern ergonomics. No hidden costs, no hidden allocations, no hidden control flow.

---

## Language Design Goals (Bux vs Rust vs Nim vs Rux)

| Dimension | Bux Target | Rust | Nim | Rux v0.2.0 |
|-----------|-----------|------|-----|------------|
| **Memory safety** | Gradual ownership (opt-in borrow checking) | Strict borrow checker | GC / manual | Raw pointers only |
| **Error handling** | `Result<T,E>` + `?` propagation | `Result<T,E>` + `?` | Exceptions | Basic Result, no `?` |
| **Concurrency** | Lightweight tasks + channels + `async`/`await` | `async`/`await` + threads | Async/await + threads | None |
| **Metaprogramming** | Compile-time function execution (CTFE) + macros | Proc/decl macros | Static generics + macros | None |
| **Generics** | Monomorphization + trait bounds | Monomorphization + trait bounds | Static generics | Limited |
| **Backend** | C transpiler (bootstrap) → native x86-64 + LLVM | LLVM | C/JS/JS backend | Custom native only |
| **Compile speed** | Fast (Nim-like goal: <1s for medium projects) | Slow (LLVM) | Fast | Fast (custom backend) |
| **FFI** | Seamless C interop (zero-cost) | Good | Good (native) | Basic extern |
| **Stdlib** | Batteries-included (collections, IO, net, sync) | Rich | Rich | Minimal |
| **Tooling** | Built-in formatter, LSP, test runner, debugger | External tools | External tools | Minimal |

---

## Phase 0 — Bootstrap Foundation ✅ (Complete)

**Goal:** Working Nim project that can lex, parse, and dump a Bux AST.

| Task | Status | Details |
|------|--------|---------|
| `0.1` Project skeleton | ✅ | `buxc` CLI in Nim, `bux.toml` manifest parser |
| `0.2` Token model | ✅ | All Rux tokens (`TokenKind`, `SourceLocation`, literal suffixes) |
| `0.3` Lexer | ✅ | UTF-8 source, identifiers, numbers (dec/hex/bin/oct), strings (`c8""`, `c16""`, `c32""`), chars, operators, nested `/* */`, `//` comments, intrinsics (`#line`, `#file`, etc.) |
| `0.4` CLI commands | ✅ | `bux new`, `bux init`, `bux build`, `bux run`, `bux check` |
| `0.5` Test harness | ✅ | Golden-file tests for lexer output (`.tokens`) |

**Deliverable:** `echo 'let x = 42' | bux check` prints token stream.

---

## Phase 1 — Frontend: Parser & AST ✅ (Complete)

**Goal:** Parse every construct present in Rux v0.2.0 into a Nim AST.

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

**Deliverable:** All `_rux/Tests/**/*.rux` files parse without error and produce `.ast` dumps.

---

## Phase 2 — Semantic Analysis ✅ (Complete)

**Goal:** Type-check the AST and produce a typed symbol table.

| Task | Status | Details |
|------|--------|---------|
| `2.1` Type model | ✅ | `TypeRef` with primitives, pointers, slices, tuples, named types, type parameters, functions |
| `2.2` Scopes | ✅ | Module scope, block scope, namespace resolution for `Std::Io::PrintLine` |
| `2.3` First pass | ✅ | Collect global symbols (functions, structs, enums, unions, interfaces, consts, type aliases, imports) |
| `2.4` Type checking | ✅ | Expression typing, operator overload resolution per Rux rules, assignment compatibility |
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
| `5B.1` Assembly emitter | NASM-syntax text output (like Rux `Asm`) |
| `5B.2` Register allocation | Naive stack-spill allocator first; later linear-scan |
| `5B.3` ABI lowering | System V AMD64 ABI (Linux/macOS) and Win64 ABI (Windows) |
| `5B.4` Object format | Emit ELF64 (Linux), Mach-O (macOS), PE/COFF (Windows) — or use `nasm` + system linker |
| `5B.5` Custom linker (optional) | `.bcu` (Bux Compiled Unit) format + bespoke linker à la Rux `.rcu` |

**Deliverable:** `bux build --backend=native` produces working Linux x86-64 binary.

---

## Phase 6 — Standard Library 🔄 (In Progress)

**Goal:** Enough stdlib to write the compiler in Bux.

| Module | Status | Requirements |
|--------|--------|-------------|
| `Std::Io` | ✅ | `Print`, `PrintLine`, `PrintInt`, `ReadLine` (wrap C stdio) |
| `Std::Memory` | ✅ | `bux_alloc`, `bux_realloc`, `bux_free` (wrap `malloc`/`free`) |
| `Std::String` | ✅ | `String_Len`, `String_Eq`, `String_Concat`, `String_Copy`, `String_StartsWith`; C wrappers in `runtime.c` |
| `Std::Array` | ✅ | Fully generic `Array<T>` with `Array_New<T>`, `Array_Push<T>`, `Array_Get<T>`, `Array_Len<T>`, `Array_Free<T>`; uses `sizeof(T)` |
| `Std::Map` | ✅ | Linear-probing hash map `String`→`int` with `Map_New`, `Map_Set`, `Map_Get`, `Map_Has`, `Map_Len`, `Map_Free` |
| `Std::Math` | ⏳ | `Sqrt`, `Pow`, `Min`, `Max`, `Abs` |
| `Std::Os` | ⏳ | `Args`, `Env`, `Exit`, `Cwd` |
| `Std::Path` | ⏳ | Path joining, extension splitting |
| `Std::Process` | ⏳ | Spawn subprocess, read stdout/stderr |
| **`Std::Result`** | ✅ | Algebraic enums `Result<T,E>` and `Option<T>` with `NewOk`/`NewErr`/`NewSome`/`NewNone`; `?` try operator desugared in HIR |
| **`Std::Iter`** | ⏳ | Iterator trait with `map`, `filter`, `fold`, `collect` |
| **`Std::Fmt`** | ⏳ | String formatting: `"Hello, {}!"` interpolation |

**Deliverable:** Can write a non-trivial CLI tool entirely in Bux. ✅ `try_operator`, `result_option`, `map`, `strings` examples working.

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

## Phase 8 — Advanced Language Features (Week 27-34)

**Goal:** Features that make Bux better than Rux and competitive with Rust/Nim.

### 8.1 — Error Handling (Result/Option + `?` operator) ✅

| Task | Status | Details |
|------|--------|---------|
| `8.1.1` Result type | ✅ | `Result<T, E>` with `Ok(T)` and `Err(E)` constructors |
| `8.1.2` Option type | ✅ | `Option<T>` with `Some(T)` and `None` constructors |
| `8.1.3` `?` operator | ✅ | `expr?` desugars to: if `Err`/`None`, early-return from function |
| `8.1.4` `!` suffix | ⏳ | `expr!` unwraps or panics (for prototyping) |

```bux
func ReadFile(path: String) -> Result<String, IoError> {
    let file = Open(path)?;        // early-returns Err if open fails
    let content = file.ReadAll()?; // early-returns Err if read fails
    return Ok(content);
}
```

### 8.2 — Ownership & Borrowing (Gradual Safety)

| Task | Details |
|------|---------|
| `8.2.1` `own` keyword | Explicit ownership transfer: `let x = own value` |
| `8.2.2` `borrow` / `&` | Borrow references with lifetime tracking |
| `8.2.3` `mut` references | `&mut T` for mutable borrows (exclusive) |
| `8.2.4` Lifetime elision | Simple rules for common cases; explicit `'a` for complex |
| `8.2.5` Opt-in checker | `@[Checked]` attribute enables borrow checking; default is permissive |

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

### 8.4 — Compile-Time Function Execution (CTFE)

| Task | Details |
|------|---------|
| `8.4.1` `const` functions | `const func` evaluable at compile time |
| `8.4.2` Compile-time blocks | `comptime { ... }` for arbitrary compile-time code |
| `8.4.3` Static assertions | `static_assert(cond, msg)` for compile-time checks |
| `8.4.4` Generated code | `#emit` for compile-time code generation |

```bux
const func Factorial(n: int) -> int {
    if n <= 1 { return 1; }
    return n * Factorial(n - 1);
}

const TABLE_SIZE = Factorial(10);  // Computed at compile time
```

### 8.5 — Trait System (Interfaces++)

| Task | Details |
|------|---------|
| `8.5.1` Traits | Like Rust traits or Go interfaces, but with default implementations |
| `8.5.2` Associated types | `type Output` inside trait definitions |
| `8.5.3` Trait bounds | `func Sort<T: Comparable>(arr: &mut Array<T>)` |
| `8.5.4` Trait objects | `&dyn Trait` for dynamic dispatch (fat pointer) |
| `8.5.5` Blanket impls | `impl<T: Display> Printable for T` |

### 8.6 — Metaprogramming

| Task | Details |
|------|---------|
| `8.6.1` Declarative macros | `macro! Name { ... }` pattern-matching macros |
| `8.6.2` Procedural macros | `#[derive(Clone)]`, `#[derive(Debug)]` |
| `8.6.3` Reflection | Compile-time type introspection for serialization |

---

## Phase 9 — Ecosystem & Tooling (Week 35+)

| Task | Details |
|------|---------|
| `9.1` Package manager | `bux add`, `bux remove`, `bux update`, `bux install` with lockfile |
| `9.2` Registry protocol | Simple HTTP git-based registry (like Go modules or Cargo) |
| `9.3` Formatter | `bux fmt` — auto-format Bux source |
| `9.4` LSP | Language Server Protocol for autocomplete, hover, go-to-definition |
| `9.5` Tests | `bux test` runner with assertions and golden tests |
| `9.6` Documentation | `bux doc` — generate HTML from `///` doc comments |
| `9.7` Cross-compilation | `--target` flag leveraging C backend portability |
| `9.8` Debugger support | DWARF/PDB debug info generation for gdb/lldb/VSCode |
| `9.9` Profiler integration | `bux build --profile` with basic profiling hooks |

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
│   │   ├── Process.bux
│   │   ├── Result.bux        # Result<T,E> and Option<T>
│   │   ├── Iter.bux          # Iterator trait and combinators
│   │   ├── Fmt.bux           # String formatting
│   │   ├── Task.bux          # Lightweight concurrency
│   │   ├── Channel.bux       # Message passing
│   │   └── Sync.bux          # Mutex, RwLock, atomic
│   └── Runtime.c             # C runtime shim
├── tests/
│   ├── Lexer/
│   ├── Parser/
│   ├── Sema/
│   ├── Codegen/
│   └── Integration/
└── docs/
    ├── LanguageRef.md
    ├── Ownership.md
    └── Concurrency.md
```

---

## Language Design Decisions (Bux Improvements)

### What Bux inherits from Rux
| Feature | Rux | Bux |
|---------|-----|-----|
| Syntax | C-like with modern touches | Same base, extended |
| Module system | `import Std::Io::PrintLine` | Same path syntax |
| String literals | `c8""`, `c16""`, `c32""` + `""` | Same |
| Build manifest | `Rux.toml` | `bux.toml` (compatible format) |
| Backend philosophy | Self-contained (no LLVM required) | C transpiler first → native + optional LLVM |

### What Bux improves over Rux
| Gap in Rux | Bux Solution |
|-----------|-------------|
| No memory safety | Gradual ownership model (opt-in borrow checking) |
| No error handling sugar | `Result<T,E>` + `?` operator |
| No concurrency | Green threads + channels + `async`/`await` |
| No metaprogramming | CTFE + declarative macros + derive macros |
| Minimal stdlib | Batteries-included (collections, IO, net, sync, fmt) |
| Custom backend only | C transpiler (portable) + native + LLVM option |
| No debug symbols | DWARF/PDB generation for debugger integration |
| Windows-only output | Cross-platform from day one (Linux, macOS, Windows) |

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

| Milestone | Phase | Success Criteria |
|-----------|-------|------------------|
| **M0** | 0 ✅ | `bux check` lexes source |
| **M1** | 1 ✅ | All Rux test files parse |
| **M2** | 2 ✅ | Type-checker rejects invalid programs |
| **M3** | 3 ✅ | HIR lowering works for all constructs |
| **M4** | 5A ✅ | `bux run` produces working binary via C transpiler |
| **M5** | 6 ✅ | Can write compiler-adjacent tools in Bux |
| **M6** | 7 | **Self-hosted**: Bux compiler builds itself |
| **M7** | 8 | Result/Option, ownership, concurrency shipped |
| **M8** | 9 | Package manager + LSP + formatter shipped |

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

## Next Immediate Steps

1. **Inferred generic function calls** — `UseBox(&b)` instead of `UseBox<int>(&b)`
2. **`extend Box<T>` syntax** — Parser support for generic impl blocks
3. **Std::String improvements** — String builder, slicing, interpolation
4. **Std::Map generic** — `Map<K,V>` with generic keys and values
5. **Self-hosting preparation** — Audit Nim compiler code for Bux-rewrite feasibility

---

## Open Design Questions

1. **Syntax for ownership**: Should Bux use `own` keyword or Rust-style move semantics?
2. **Async runtime**: M:N green threads (Go-style) or 1:1 OS threads (Rust-style)?
3. **Macro system**: Declarative-only or also procedural macros?
4. **Package registry**: Centralized (crates.io) or decentralized (Go modules)?
5. **LLVM backend**: Should Bux support LLVM as an optional backend, or stay fully self-contained?

---

## Appendix A: Rux Language Reference (for Bux parity)

Based on [Rux Documentation](https://rux-lang.dev/docs/), these are the features Bux must support for Rux parity:

### A.1 Types

| Category | Rux Types | Bux Status |
|----------|-----------|------------|
| **Signed integers** | `int8`, `int16`, `int32`, `int64`, `int` (platform) | ✅ Implemented |
| **Unsigned integers** | `uint8`, `uint16`, `uint32`, `uint64`, `uint` (platform) | ✅ Implemented |
| **Floating-point** | `float32`, `float64` | ✅ Implemented |
| **Boolean** | `bool`, `bool8`, `bool16`, `bool32` | ✅ Implemented |
| **Character** | `char8`, `char16`, `char32` | ✅ Implemented |
| **String** | `String` (UTF-8), `c8""`, `c16""`, `c32""` literals | ✅ Implemented |
| **Pointer** | `*T` (raw pointer) | ✅ Implemented |
| **Slice** | `T[]` (unsized), `T[N]` (fixed-size) | ✅ Implemented |
| **Tuple** | `(T1, T2, ...)` | ✅ Implemented |
| **Function** | `func(T1, T2) -> R` | ✅ Implemented |
| **Option** | `Option<T>` = `Some(T)` \| `None` | ✅ Implemented |
| **Result** | `Result<T, E>` = `Ok(T)` \| `Err(E)` | ✅ Implemented |

### A.2 Declarations

| Construct | Rux Syntax | Bux Status |
|-----------|------------|------------|
| **Immutable variable** | `let x: int = 42;` | ✅ Implemented |
| **Mutable variable** | `var x: int = 42;` | ✅ Implemented |
| **Constant** | `const Max: uint32 = 100;` | ✅ Implemented |
| **Function** | `func Add(a: int, b: int) -> int { ... }` | ✅ Implemented |
| **Generic function** | `func Min<T>(x: T, y: T) -> T { ... }` | ✅ Implemented |
| **Variadic function** | `func Sum(values: int32...)` | ⏳ Phase 1 |
| **Struct** | `struct Point { x: float64; y: float64; }` | ✅ Implemented |
| **Enum** | `enum Color { Red, Green, Blue }` | ✅ Implemented |
| **Data-carrying enum** | `enum Shape { Circle(float64), Rect(float64, float64) }` | ✅ Implemented |
| **Union (untagged)** | `union Bits { asByte: uint8; asInt: int32; }` | ✅ Implemented |
| **Interface (trait)** | `interface Display { func ToString() -> String; }` | ✅ Implemented |
| **Impl (extend)** | `extend Circle: Display { ... }` | ✅ Implemented |
| **Module** | `module Math;` | ✅ Implemented |
| **Type alias** | `type Int = int32;` | ✅ Implemented |
| **Extern function** | `extern func printf(fmt: *char8, ...);` | ✅ Implemented |

### A.3 Statements & Control Flow

| Construct | Rux Syntax | Bux Status |
|-----------|------------|------------|
| **If/else** | `if cond { ... } else { ... }` | ✅ Implemented |
| **While loop** | `while cond { ... }` | ✅ Implemented |
| **Do-while** | `do { ... } while cond;` | ✅ Implemented |
| **Infinite loop** | `loop { ... }` | ✅ Implemented |
| **For-in loop** | `for item in collection { ... }` | ✅ Implemented |
| **Range (exclusive)** | `0..10` (0 to 9) | ✅ Implemented |
| **Range (inclusive)** | `0..=10` (0 to 10) | ✅ Implemented |
| **Match expression** | `match val { pat => expr, ... }` | ✅ Implemented |
| **Break** | `break;` or `break label;` | ✅ Implemented |
| **Continue** | `continue;` or `continue label;` | ✅ Implemented |
| **Return** | `return expr;` | ✅ Implemented |
| **Labeled loops** | `outer: loop { ... break outer; }` | ✅ Implemented |

### A.4 Pattern Matching

| Pattern | Rux Syntax | Bux Status |
|---------|------------|------------|
| **Wildcard** | `_` | ✅ Implemented |
| **Literal** | `42`, `"hello"`, `true` | ✅ Implemented |
| **Identifier** | `name` (binds value) | ✅ Implemented |
| **Range** | `1..9`, `1..=9` | ✅ Implemented |
| **Enum destructuring** | `Shape::Circle(r)` | ✅ Implemented |
| **Struct destructuring** | `Point { x: 0, y: 0 }` | ✅ Implemented |
| **Tuple** | `(a, b, c)` | ✅ Implemented |
| **Guard** | `t if t < 0` | ✅ Implemented |

### A.5 Expressions & Operators

| Category | Rux Operators | Bux Status |
|----------|---------------|------------|
| **Arithmetic** | `+`, `-`, `*`, `/`, `%`, `**` | ✅ Implemented |
| **Comparison** | `==`, `!=`, `<`, `<=`, `>`, `>=` | ✅ Implemented |
| **Logical** | `&&`, `\|\|`, `!` | ✅ Implemented |
| **Bitwise** | `&`, `\|`, `^`, `~`, `<<`, `>>` | ✅ Implemented |
| **Assignment** | `=`, `+=`, `-=`, `*=`, `/=`, etc. | ✅ Implemented |
| **Increment/Decrement** | `++`, `--` | ✅ Implemented |
| **Cast** | `expr as Type` | ✅ Implemented |
| **Type test** | `expr is Type` | ✅ Implemented |
| **Ternary** | `cond ? then : else` | ✅ Implemented |
| **Path** | `Module::Name` | ✅ Implemented |
| **Field access** | `obj.field` | ✅ Implemented |
| **Index** | `arr[idx]` | ✅ Implemented |
| **Call** | `func(args...)` | ✅ Implemented |
| **Spread** | `func(slice...)` | ✅ Implemented |
| **Range expr** | `0..5`, `0..=5` | ✅ Implemented |
| **Struct init** | `Point { x: 1.0, y: 2.0 }` | ✅ Implemented |
| **Slice init** | `[1, 2, 3]` | ✅ Implemented |
| **Tuple init** | `(a, b, c)` | ✅ Implemented |
| **Sizeof** | `sizeof(Type)` | ✅ Implemented |
| **Dereference** | `*ptr` | ✅ Implemented |
| **Address-of** | `&var` | ✅ Implemented |

### A.6 Modules & Imports

| Feature | Rux Syntax | Bux Status |
|---------|------------|------------|
| **Single import** | `import Math::Sqrt;` | ✅ Implemented |
| **Multiple imports** | `import Http::{ Request, Response };` | ✅ Implemented |
| **Wildcard import** | `import Std::Io::*;` | ⏳ Phase 1 |
| **Public visibility** | `pub struct Foo { ... }` | ✅ Implemented |
| **Private (default)** | Items private to module by default | ✅ Implemented |

### A.7 Functions

| Feature | Rux Syntax | Bux Status |
|---------|------------|------------|
| **Basic function** | `func Name(params) -> RetType { body }` | ✅ Implemented |
| **Parameters** | `name: type` | ✅ Implemented |
| **Return type** | `-> type` | ✅ Implemented |
| **Multiple returns** | `-> (type1, type2)` via tuple | ⏳ Phase 1 |
| **Variadic** | `values: type...` | ⏳ Phase 1 |
| **Generics** | `func Name<T>(...)` | ✅ Implemented |
| **Assembler** | `asm func Name() { ... }` | ⏳ Phase 8 |
| **Entry point** | `func Main() -> int` | ✅ Implemented |

### A.8 Features Bux Adds Beyond Rux

| Feature | Bux Syntax | Rux Equivalent |
|---------|------------|----------------|
| **Error propagation** | `expr?` | ❌ Not in Rux |
| **Unwrap/panic** | `expr!` | ❌ Not in Rux |
| **Ownership (opt-in)** | `@[Checked]` attribute | ❌ Not in Rux |
| **Borrow checking** | `&T`, `&mut T` with lifetimes | ❌ Not in Rux |
| **Async/await** | `async func`, `.await` | ❌ Not in Rux |
| **Channels** | `Channel<T>` | ❌ Not in Rux |
| **CTFE** | `const func` | Partial (const only) |
| **String interpolation** | `"Hello, {name}!"` | ❌ Not in Rux |
| **Iterators** | `for x in iter.map(...)` | ❌ Not in Rux |
| **Derive macros** | `#[derive(Clone, Debug)]` | ❌ Not in Rux |
| **Declarative macros** | `macro! Name { ... }` | ❌ Not in Rux |

---

## Appendix B: Bux Token Reference

Complete token list from the lexer (matches Rux token set):

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

## Appendix C: Build & Tooling Commands

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
