# Bux Programming Language

> **Status:** Bootstrap phase — compiler written in Nim, targeting self-hosting.

Bux is a fast, compiled, strongly-typed systems programming language inspired by [Rux](https://rux-lang.dev/). The long-term goal is a self-hosted compiler with a minimal runtime, native x86-64 backend, and modern tooling.

Bux improves on Rux with a richer standard library (`Map`, `String`), modern error handling (`Result`, `Option`, and the `?` operator), and a portable C transpiler backend that runs on Linux, macOS, and Windows.

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
| **Standard Library** | `Io`, `Array`, `String`, `Map` |
| **Backend** | C transpiler (bootstrap) |
| **Gradual Ownership** | `@[Checked]` + `&T`/`&mut T` borrow checking |
| **CTFE** | `const func` — compile-time function execution |
| **Trait Bounds** | `func Max<T: Comparable>(a: T, b: T) -> T` |
| **Package Manager** | `bux add`, `bux install`, `bux.lock`, path + git deps |
| **Tooling** | `bux new`, `bux build`, `bux run`, `bux check` |

---

## Project Structure

```
bux/
├── src/              # Bootstrap compiler (Nim)
├── stdlib/           # Standard library (.bux + .c runtime)
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
# Build compiler
make build

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
