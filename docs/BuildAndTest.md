# Build and Test Guide

This guide covers building the Bux bootstrap compiler, creating projects, and running tests.

---

## Prerequisites

- **Nim** (1.6+) — for building the bootstrap compiler
- **C compiler** (`gcc`, `clang`, or `cc`) — for the C backend
- **Make**

On Debian/Ubuntu:
```bash
sudo apt-get install nim gcc make libssl-dev
```

On macOS:
```bash
brew install nim gcc make openssl
```

> **Note:** The `Std::Crypto` module requires OpenSSL (`-lcrypto`). The build system links it automatically.

---

## Building the Compiler

```bash
# Release build
make build

# Development build (no optimizations, faster compile)
make dev
```

The output is a single binary: `buxc` (bootstrap compiler in Nim).

The self-hosted compiler `buxc2` is built from `src/*.bux` sources via:
```bash
make selfhost
```
This compiles `buxc2` using the bootstrap compiler. The self-hosted compiler generates C code and invokes `cc` to produce native binaries.

---

## Creating a Project

```bash
# Create a new package in a new directory
./buxc new myproject
cd myproject

# Or initialize in the current directory
mkdir myproject && cd myproject
./buxc init
```

This generates:
```
myproject/
├── bux.toml
└── src/
    └── Main.bux
```

### bux.toml

```toml
[Package]
Name    = "myproject"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
```

---

## Building and Running

```bash
# Type-check without building
./buxc check
./buxc check ./myproject

# Build
./buxc build
./buxc build ./myproject

# Build and run
./buxc run
./buxc run ./myproject

# Run tests (builds and runs the binary, reports pass/fail)
./buxc test
./buxc test ./myproject

# Format code
./buxc fmt src/Main.bux       # single file
./buxc fmt src/               # all .bux files in directory

# Clean build artifacts
./buxc clean
```

Build output goes to `build/` by default.

### Cross-Compilation

Use `--target <triple>` to cross-compile for a different platform. Bux generates C code and uses `clang` with the `-target` flag for cross-compilation.

```bash
# Cross-compile for ARM Linux
./buxc build --target aarch64-linux-gnu

# Cross-compile for x86_64 Linux (explicit)
./buxc build --target x86_64-linux-gnu

# Cross-compile and run project build
./buxc project --target x86_64-linux-gnu
./buxc run --target aarch64-linux-gnu
```

> **Note:** `clang` must be installed for cross-compilation. Without `--target`, Bux uses the system `cc` compiler.

---

## Running Tests

### Compiler Tests
```bash
make test
```

This runs:
- Lexer unit tests
- Parser unit tests
- Semantic analysis unit tests
- HIR lowering unit tests
- Integration tests (`buxc new`, `buxc --version`)
- Golden C-codegen tests (8 examples)

### Project Tests (`bux test`)
```bash
./buxc test
```

Builds the project and runs the resulting binary. Reports:
- `Tests passed` on exit code 0
- `Tests failed (exit code N)` on non-zero exit

Use `Std::Test` module for assertions inside test code.

### Example Programs
```bash
make test-examples
```

Compiles and runs all programs in `examples/`.

### Individual Example
```bash
mkdir -p examples_pkg/hello/src
cp examples/hello.bux examples_pkg/hello/src/Main.bux
# Create bux.toml manually or use `buxc new`
cd examples_pkg/hello && ../../buxc run
```

---

## Project Layout

```
bux/
├── src/              # Self-hosted compiler source (Bux)
│   ├── Main.bux      # Entry point
│   ├── Cli.bux       # CLI commands (build, run, test, fmt, new, init)
│   ├── Lexer.bux     # Tokenizer
│   ├── Parser.bux    # Parser
│   ├── Ast.bux       # AST definitions
│   ├── Sema.bux      # Semantic analysis (borrow checker)
│   ├── Types.bux     # Type system
│   ├── Scope.bux     # Symbol table
│   ├── Hir.bux       # High-level IR
│   ├── HirLower.bux  # AST → HIR lowering
│   ├── CBackend.bux  # HIR → C code generation
│   ├── Manifest.bux  # bux.toml parser
│   ├── Fmt.bux       # Code formatter
│   └── Token.bux     # Token definitions
├── bootstrap/        # Bootstrap compiler (Nim) — compiles src/ → buxc
│   ├── main.nim
│   ├── cli.nim
│   └── ...
├── lib/              # Standard library (Bux)
│   ├── Io.bux
│   ├── Array.bux
│   ├── String.bux
│   ├── Map.bux
│   ├── Fs.bux
│   ├── Mem.bux
│   ├── Set.bux
│   ├── Path.bux
│   ├── Math.bux
│   ├── Task.bux
│   └── Channel.bux
├── rt/               # C runtime
│   ├── runtime.c
│   └── io.c
├── examples/         # Example programs
├── tests/            # Unit tests (Nim)
├── docs/             # Documentation
└── Makefile
```

---

## Debugging

### Verbose Output
```bash
./buxc build -v
```

### Inspecting Generated C (bootstrap)
```bash
./buxc build
cat build/main.c
```

### Inspecting Generated C (self-hosted)
```bash
cd src && ../buxc build
cat build/main.c
```

### Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `stdlib directory not found` | `buxc` can't find `lib/` | Run from project root or set correct path |
| `duplicate symbol 'bux_alloc'` | Multiple stdlib modules declare same extern | Only declare in one module |
| `C compilation failed` | Generated C has errors | Check `build/main.c` for issues |

---

## Adding a New Example

1. Create `examples/myexample.bux`
2. Add `myexample` to `EXAMPLES` in `Makefile`
3. Run `make test-examples`

---

## Development Workflow

```bash
# After making changes to the compiler:
make build
make test

# If tests pass, run examples:
make test-examples
```
