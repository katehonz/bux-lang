# Bux Programming Language

![Bux Language](bux-lang-01.jpeg)

> **Status:** **v1.0.0** — language freeze. Bootstrap (`buxc`, Nim) and self-hosted (`buxc2`, Bux) both compile `.bux` → C → native binary.
> **Selfhost loop:** deterministic C codegen + ELF verified.
> **Gradual Ownership:** `@[Checked]` borrow checker, `@[Release]` zero-cost mode, `borrow &mut` expressions.
> **Closures:** multi-instance capturing closures via fat function pointers (`BuxFn { code, env }`) in both compilers.
> **Tuples:** `(T, U)` types and `.0`/`.1` field access (bootstrap + selfhost).
> **Green Threads:** M:N scheduler with channels (Go-style goroutines without GC).
> **Examples:** 40+ programs pass (`make test-examples`). Apps: `boko-framework`, `jwt-pitbul`, `nexus`, `simpledb`.
> **Semver:** after 1.0, breaking changes require MAJOR (`docs/SEMVER.md`).

Bux is a fast, compiled, strongly-typed systems programming language. Features a C backend for native code generation, raw multi-line strings, gradual ownership (opt-in borrow checking), multi-instance closures, async/await, generics, algebraic enums, and a package manager.

---

## Quick Start

```bash
# Build the bootstrap compiler (Nim)
make build

# Create a new project
bux new hello
cd hello

# Build and run
bux run

# Build optimized release binary
bux build --release

# Cross-compile for ARM Linux (requires clang)
bux build --target aarch64-linux-gnu
```

---

## Syntax Preview

### Hello World
```bux
import Std::Io::PrintLine;

func Main() -> int {
    PrintLine("Hello, Bux!");
    return 0;
}
```

### Raw Multi-line Strings
```bux
// Backtick strings: no escape processing, multi-line
func Main() -> int {
    PrintLine(`Hello \n World`);     // prints: Hello \n World (literal)
    PrintLine(`Line 1
Line 2
Line 3`);                            // multi-line, newlines preserved
    return 0;
}
```

### Error Handling with `?`
```bux
enum Result {
    Ok(int),
    Err(String)
}

func Divide(a: int, b: int) -> Result {
    if b == 0 {
        return Result_NewErr("division by zero");
    }
    return Result_NewOk(a / b);
}

func Compute() -> Result {
    let x: int = Divide(10, 2)?;  // auto-propagates Err
    let y: int = Divide(x, 5)?;
    return Result_NewOk(y);
}
```

### Structs and Methods
```bux
struct Rectangle {
    width: int;
    height: int;
}

extend Rectangle {
    func Area(self: Rectangle) -> int {
        return self.width * self.height;
    }
}

func Main() -> int {
    let rect: Rectangle = Rectangle { width: 10, height: 5 };
    PrintInt(rect.Area());
    return 0;
}
```

### Generics
```bux
func Max<T>(a: T, b: T) -> T {
    if a > b {
        return a;
    }
    return b;
}

func Main() -> int {
    let m: int = Max<int>(10, 20);
    PrintInt(m);
    return 0;
}
```

### Async/Await
```bux
import Std::Io::{PrintLine, PrintInt};

async func Compute() -> int {
    PrintLine("Compute: step 1");
    bux_async_yield();
    PrintLine("Compute: step 2");
    return 42;
}

func Main() -> int {
    let h1 = spawn Compute();
    let r1: int = h1.await as int;
    PrintInt(r1);
    return 0;
}
```

### Channels (Producer/Consumer)
```bux
import Std::Io::{PrintLine, PrintInt};
import Std::Task::{Task_Wait, TaskHandle};
import Std::Channel::{Channel, Channel_New, Channel_SendInt, Channel_RecvInt, Channel_Close};

func Producer(chPtr: *Channel<int>) {
    var i: int = 1;
    while i <= 5 {
        Channel_SendInt(chPtr, i * 10);
        i = i + 1;
    }
    Channel_Close<int>(chPtr);
}

func Consumer(chPtr: *Channel<int>) {
    var total: int = 0;
    while true {
        let val: int = Channel_RecvInt(chPtr);
        if val == 0 { break; }
        total = total + val;
        PrintInt(val);
        PrintLine("");
    }
    PrintLine("Total:");
    PrintInt(total);
    PrintLine("");
}

func Main() -> int {
    let ch: Channel<int> = Channel_New<int>(3);
    let p: *void = spawn Producer(&ch);
    let c: *void = spawn Consumer(&ch);
    Task_Wait(TaskHandle { handle: p });
    Task_Wait(TaskHandle { handle: c });
    return 0;
}
```

### Hash Map
```bux
import Std::Map::{Map, Map_New, Map_Set, Map_Get};

func Main() -> int {
    let m: Map = Map_New(16);
    Map_Set(&m, "answer", 42);
    PrintInt(Map_Get(&m, "answer"));
    return 0;
}
```

### Multi-instance closures
```bux
func MakeAdder(base: int) -> func(int) -> int {
    return |a: int| -> int { return a + base; };
}

func Main() -> int {
    let a10 = MakeAdder(10);
    let a20 = MakeAdder(20);
    // Independent capture environments
    PrintInt(a10(1));  // 11
    PrintInt(a20(1));  // 21
    return 0;
}
```

### Iter map / filter / fold
```bux
import Std::Iter::{Array_Iter, Iter_MapInt, Iter_FilterInt, Iter_FoldInt};

func Main() -> int {
    var nums: Array<int> = Array_New<int>(4);
    Array_Push<int>(&nums, 1);
    Array_Push<int>(&nums, 2);
    Array_Push<int>(&nums, 3);
    let it = Array_Iter<int>(&nums);
    let doubled = Iter_MapInt(&it, |x: int| -> int { return x * 2; });
    return 0;
}
```

---

## Features

| Feature | Status |
|---------|--------|
| **Types** | Primitives, pointers, slices, tuples `(T,U)` + `.0`/`.1`, structs, enums, unions |
| **Generics** | Generic functions (monomorphization) |
| **Algebraic Enums** | Enums with data (`Result`, `Option`) |
| **Pattern Matching** | `match` with guards |
| **Methods** | `extend` blocks for struct methods |
| **Interfaces** | `interface` + `extend` for trait-like behavior |
| **Error Handling** | `Result`/`Option`, `?`, `Expect`/`UnwrapOr`/`Or` helpers |
| **Closures** | Capture-less + capturing; **multi-instance** fat pointers (`BuxFn`) |
| **Function pointers** | `func(T) -> R` as fat values; named funcs via adapters |
| **Standard Library** | `Io`, `Array`, `String`, `Map`, `Set`, `Iter` (map/filter/fold), `Fs`, `Mem`, `Path`, `Math`, `Task`, `Channel`, `Sync`, `Os`, `Time`, `Process`, `Test`, … |
| **Backend** | LIR → C transpiler (clean 3-address code, then gcc/clang) |
| **Strings** | Raw multi-line backticks, `f"..."` interp (bootstrap), `ReplaceAll` / `IsBlank` / `Repeat` |
| **Gradual Ownership** | `@[Checked]` + `@[Release]` + `@[Shared]` + `borrow &mut` / `borrow &` |
| **Drop / RAII** | Auto-drop (`@[Drop]` / `extend … for Drop`); **field-move skips Drop** (no double-free) |
| **Green Threads** | M:N scheduler (ucontext + SIGVTALRM), work-stealing queues |
| **Async/Await** | `async func`, `spawn`, `.await` with stackful coroutines |
| **Concurrency** | `Task`/`Channel`/`Sync` (pthread-based), `bux_async_yield`/`spawn` |
| **CTFE** | `const func` — compile-time function execution |
| **Trait Bounds** | `func Max<T: Comparable>(a: T, b: T) -> T` |
| **Package Manager** | `bux add`, `bux install`, `bux.lock`, path + git deps |
| **Cross-Compilation** | `--target <triple>` via clang (e.g. `aarch64-linux-gnu`) |
| **Diagnostics** | Rust-style snippets, multi-char underlines, `= help:` hints |
| **Tooling** | `bux new/build/run/test/check/fmt/doc`, LSP 0.4.0 (locals + inferred lets) |

---

## Project Structure

```
bux/
├── src/              # 🎯 Self-hosting compiler source (Bux)
│   ├── main.bux      # Entry point
│   ├── lexer.bux     # Tokenizer
│   ├── parser.bux    # Pratt parser
│   ├── ast.bux       # AST node types
│   ├── sema.bux      # Type checker
│   ├── hir_lower.bux # AST → HIR lowering
│   ├── c_backend.bux # HIR → C code generator
│   └── cli.bux       # CLI driver
├── bootstrap/        # 🔧 Bootstrap compiler (Nim)
│   ├── main.nim      # Entry point
│   ├── cli.nim       # CLI commands + build driver
│   └── ...           # (mirrors src/ structure)
├── lib/              # 📦 Standard library (23 modules)
│   ├── Io.bux        # Print, ReadFile, WriteFile
│   ├── String.bux    # Full string API
│   ├── Array.bux     # Generic Array<T>
│   ├── Map.bux       # Generic Map<K,V> + StringMap
│   ├── Set.bux       # Generic Set<T>
│   ├── Task.bux      # Green threads (spawn/await)
│   ├── Channel.bux   # Producer/consumer channels
│   ├── Drop.bux      # Drop trait interface
│   └── ...           # Math, Fs, Path, Sync, Result, ...
├── rt/               # ⚙️ C runtime
│   ├── runtime.c     # Memory, scheduler, channels
│   └── io.c          # File I/O wrappers
├── tests/            # 🧪 Unit tests (Nim)
├── examples/         # Example programs
├── apps/             # Real-world applications
├── docs/             # Documentation
├── README.md
├── PLAN.md           # Roadmap to v1.0.0
└── Makefile
```

---

## Documentation

| Doc | Description |
|-----|-------------|
| [`docs/LanguageRef.md`](docs/LanguageRef.md) | Language reference |
| [`docs/Stdlib.md`](docs/Stdlib.md) | Standard library API |
| [`docs/BuildAndTest.md`](docs/BuildAndTest.md) | Build, test, and tooling |
| [`docs/QUALITY_PLAN.md`](docs/QUALITY_PLAN.md) | Roadmap toward a “good” v1.0 |
| [`docs/Packages.md`](docs/Packages.md) | Package manager + registry |
| [`docs/SEMVER.md`](docs/SEMVER.md) | Versioning policy |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | Feature status (constructs) |
| [`PLAN.md`](PLAN.md) | Long-form phase plan |

---

## Build & Test

```bash
# Build bootstrap compiler (Nim → C)
make build

# Run all example programs
make test-examples

# Golden diagnostic tests (Rust-style error format)
make test-errors

# Full unit + example suite (local; CI splits the same coverage across jobs)
make test
# Individual suites (also used by .github/workflows/ci.yml in parallel):
#   make test-unit / test-examples / test-errors / test-stdlib /
#   test-registry / test-dwarf / test-apps / test-selfhost-smoke

# Full-tree format check (lib/ examples/ src/ tests/ apps/)
make fmt-check
# Reformat those trees
make fmt

# Stdlib behavioral goldens (Array / String / collections)
make test-stdlib

# Generate stdlib API docs from /// comments
make docs

# Build self-hosted compiler (Bux → C → native)
make selfhost

# Package tests (filter + summary table)
./buxc test --filter first _test_runner

# Format / CI format check
./buxc fmt path/to/file.bux
./buxc fmt --check path/

# API docs
./buxc doc --out docs/api/stdlib.md lib/

# Package registry
./buxc search greet
make test-registry          # add greet → install → build temp app

# Selfhost determinism (optional CI job; not in default `make test`)
make selfhost-loop
# Full fixed-point: buxc2 → buxc3 → buxc4 (gen2 vs gen3 C+ELF identical)
# BUX_SELFHOST_FIXED_POINT=1 make selfhost-loop

# Clean build artifacts
make clean
```

> **Windows users:** Use the `buxs/` directory as your project root to avoid path conflicts.

---

## Applications

The `apps/` directory contains real-world Bux applications that serve as integration tests for the compiler:

| App | Description | Lines |
|-----|-------------|-------|
| **boko-framework** | Async web framework (like FastAPI), multi-threaded HTTP server | ~660 |
| **jwt-pitbul** | JWT CLI tool — sign, verify, decode (HS256/384/512, RS256/384/512, ES256/384, EdDSA) | ~326 |
| **nexus** | High-performance HTTP/1.1, HTTP/2 & WebSocket server | ~550 |

The bootstrap compiler successfully parses and type-checks all three applications without hanging or crashing.

---

## Documentation

- [`docs/LanguageRef.md`](docs/LanguageRef.md) — Language reference
- [`docs/Stdlib.md`](docs/Stdlib.md) — Standard library documentation
- [`docs/BuildAndTest.md`](docs/BuildAndTest.md) — Build and test guide
- [`PLAN.md`](PLAN.md) — Roadmap to self-hosting

---

## License

MIT
