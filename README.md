# Bux Programming Language

![Bux Language](bux-lang-01.jpeg)

> **Status:** Self-hosting phase — `buxc2` compiles `.bux` → C → native binary. Bootstrap (`buxc`, Nim) builds the self-hosted compiler.

Bux is a fast, compiled, strongly-typed systems programming language. Features a C backend for native code generation, raw multi-line strings, gradual ownership, async/await, generics, algebraic enums, and a package manager.

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

---

## Features

| Feature | Status |
|---------|--------|
| **Types** | Primitives, pointers, slices, tuples, structs, enums, unions |
| **Generics** | Generic functions (monomorphization) |
| **Algebraic Enums** | Enums with data (`Result`, `Option`) |
| **Pattern Matching** | `match` with guards |
| **Methods** | `extend` blocks for struct methods |
| **Interfaces** | `interface` + `extend` for trait-like behavior |
| **Error Handling** | `Result<T,E>`, `Option<T>`, and the `?` operator |
| **Standard Library** | `Io`, `Array`, `String`, `Map`, `Fs`, `Mem`, `Set`, `Path`, `Math`, `Task`, `Channel` |
| **Backend** | C transpiler (self-hosting + bootstrap) |
| **Strings** | Raw multi-line backtick strings (`...`), C-string interop |
| **Gradual Ownership** | `@[Checked]` + `&T`/`&mut T` borrow checking |
| **Async/Await** | `async func`, `spawn`, `.await` with stackful coroutines |
| **Concurrency** | `Task`/`Channel` (pthread-based), `bux_async_yield`/`spawn` |
| **CTFE** | `const func` — compile-time function execution |
| **Trait Bounds** | `func Max<T: Comparable>(a: T, b: T) -> T` |
| **Package Manager** | `bux add`, `bux install`, `bux.lock`, path + git deps |
| **Tooling** | `bux new`, `bux build`, `bux run`, `bux check` |

---

## Project Structure

```
bux/
├── src/              # Bootstrap compiler (Nim)
├── src_bux/          # Self-hosting compiler source (Bux)
├── _selfhost/        # Self-hosting build artifacts
├── stdlib/           # Standard library (.bux + .c runtime)
│   └── Std/
│       ├── Io.bux, String.bux, Array.bux, Map.bux
│       ├── Fs.bux, Mem.bux, Set.bux
│       ├── Path.bux, Math.bux
│       └── Task.bux, Channel.bux
├── examples/         # Example programs
├── tests/            # Unit tests (Nim)
├── docs/             # Documentation
├── README.md
├── PLAN.md           # Roadmap to self-hosting
└── Makefile
```

---

## Build & Test

```bash
# Build bootstrap compiler (Nim → C)
make build

# Build self-hosted compiler (Bux → C → native)
make selfhost

# Run all tests
make test

# Run example programs
make test-examples

# Clean build artifacts
make clean
```

---

## Documentation

- [`docs/LanguageRef.md`](docs/LanguageRef.md) — Language reference
- [`docs/Stdlib.md`](docs/Stdlib.md) — Standard library documentation
- [`docs/BuildAndTest.md`](docs/BuildAndTest.md) — Build and test guide
- [`PLAN.md`](PLAN.md) — Roadmap to self-hosting

---

## License

MIT
