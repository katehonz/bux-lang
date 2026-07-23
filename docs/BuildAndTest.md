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

> **Note:** Crypto + TLS require OpenSSL (`-lssl -lcrypto`). The build system links both automatically on the full (POSIX) runtime.

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

### Cross-Compilation, static, and thin runtime (Linux-first)

Bux targets **Linux** (primary), **cloud/containers**, and **embedded/cross**. Windows is not a product focus.

```bash
# Thin runtime (no pthread / OpenSSL / sockets) — good for CLI & embed
BUX_RUNTIME=minimal ./buxc build

# Fully-static binary (implies minimal runtime; container / distroless friendly)
./buxc --static --release build
# same: BUX_STATIC=1 ./buxc --release build

# Cross-compile for ARM64 Linux (prefers aarch64-linux-gnu-gcc, else clang -target)
./buxc --static --release --target aarch64-linux-gnu build

# Override C compiler
BUX_CC=aarch64-linux-gnu-gcc ./buxc --static --target aarch64-linux-gnu build

# musl fully-static (Alpine-friendly; needs musl-tools or zig)
BUX_CC=musl-gcc BUX_RUNTIME=minimal ./buxc --static --release build
# or: BUX_CC='zig cc -target x86_64-linux-musl' …  (use a wrapper script)
make test-musl-static   # SKIP if no musl-gcc/zig
```

| Switch / env | Effect |
|--------------|--------|
| `BUX_RUNTIME=full` | `rt/runtime.c` — POSIX + OpenSSL (default on Unix) |
| `BUX_RUNTIME=minimal` / `thin` / `embed` | `rt/runtime_minimal.c` — thin single-threaded |
| `BUX_RUNTIME=win` | `rt/runtime_win.c` — historical MinGW smoke only |
| `--static` / `BUX_STATIC=1` | `-static` link; defaults to minimal runtime |
| `--target <triple>` | Cross compile; defaults to minimal runtime |
| `BUX_CC` | Force C compiler binary |
| `BUX_CFLAGS` | Extra flags appended to the C line |

```bash
# Smoke all of the above (+ CTFE CRC example)
make test-linux-targets

# Build static hello for Docker scratch/distroless
./tools/build_static_hello.sh
docker build -f examples/docker/Dockerfile.static \
  --build-arg BIN=build/hello_static -t bux-hello-static .
```

> **Note:** Full runtime + fully-static OpenSSL is intentionally not the default (painful). Use minimal for static containers; keep full runtime for servers that need net/crypto (`nexus`).

---

## Running Tests

### Example suite
```bash
make test-examples   # all examples/ programs (40+)
make test-errors     # golden Rust-style diagnostic output
make test-stdlib     # stdlib golden packages
make test-registry   # package registry (local + HTTP index)
make test-apps       # showcase apps build + simpledb/jwt CLI smoke (in `make test`)
make test-dwarf      # #line maps + .debug_info + --release (in `make test`)
make test-linux-targets  # minimal runtime + static + aarch64 cross + CTFE CRC
make test-registry   # package registry local + HTTP (in `make test`)
make test-selfhost-smoke  # buxc2: move_field + multi-file #line (in `make test`)
make test-lsp        # hover + references/rename + call hierarchy
make bench           # micro-benchmarks (Bux + C/Nim/Zig twins)
make bench-nexus     # wrk throughput vs apps/nexus /api/health
```

### Debug builds (E.4)

```bash
./buxc build              # -O0 -g, #line → .bux (gdb-friendly; bootstrap)
./buxc build --release    # -O2 -DNDEBUG, no #line / -g
# Selfhost (buxc2): default -O0 -g; multi-file #line from Decl.sourceFile
# (stdlib + each src/*.bux get their own path — no env needed)
export BUX_NO_LINE=1                 # disable selfhost #line maps
export BUX_DEBUG_FILE=/abs/path.bux  # optional: force all #line to one path
export BUX_CFLAGS="-fno-omit-frame-pointer"
gdb --args ./build/myapp
#   (gdb) break Main
#   (gdb) list            # Bux source via #line (correct file per function)
```


### Compiler Tests
```bash
make test
```

This runs:
- Example suite (`test-examples`)
- Error diagnostic goldens (`test-errors`)
- Lexer unit tests
- Parser unit tests
- Semantic analysis unit tests
- HIR lowering unit tests
- Integration tests (`buxc new`, `buxc --version`)
- Golden C-codegen tests (8 examples)

### Project Tests (`bux test`)
```bash
./buxc test                    # run all tests/*.bux in the current package
./buxc test --filter first     # only tests whose name contains "first"
./buxc test --filter=first _test_runner
```

Discovers `tests/*.bux`, builds each as a temp package, and runs it. Prints a
summary table and exits:
- `0` — all selected tests passed
- `1` — at least one failure, or no tests matched the filter

Use `Std::Test` module for assertions inside test code.

### Continuous integration
```bash
make test                          # full sequential suite (local)
```
| Workflow | When | What runs |
|----------|------|-----------|
| **`.github/workflows/ci.yml`** | every PR + push to `main` | **split jobs** (see below) + macOS smoke |
| **`.github/workflows/selfhost-loop.yml`** | weekly / manual / path-filtered main | `make selfhost-loop` |

**`ci.yml` layout (faster PR feedback):**

| Job | OS | Targets |
|-----|-----|---------|
| `build` | ubuntu | `make build` → upload `buxc` artifact |
| `unit` | ubuntu | `fmt-check` + `test-unit` (reuse artifact) |
| `examples` | ubuntu | `test-examples` (full list) |
| `goldens` | ubuntu | `test-errors` + `test-stdlib` + `test-registry` + `test-dwarf` + `test-drop-move` + `test-linux-targets` |
| `apps` | ubuntu | `test-apps` |
| `selfhost` | ubuntu | `test-selfhost-smoke` |
| `macos` | macos-14 | rebuild + `test-unit` + `test-examples-smoke` (subset) |
| `windows` | windows-latest | `buxc.exe` + Nim unit tests + CLI + **MinGW `hello`** |
| `ci-gate` | ubuntu | fails if any required job failed (branch protection) |

**CI speed helpers:**
- Pin Nim **2.0.8**; cache `.nim_runtime` (big win on macOS — Nim is built from source there;
  Windows uses a prebuilt Nim zip)
- Project-local `nimcache/` via `NIMFLAGS=--nimcache:nimcache`, cached per job by source hash
- macOS skips full EXAMPLES (Linux already runs them) and skips `fmt-check` (Linux unit job)
- **Windows** runs `tools/smoke_windows_hello.sh` with **MinGW gcc** + `rt/runtime_win.c`
  (no pthread/OpenSSL/ucontext). Full POSIX runtime (`rt/runtime.c`) remains Unix-only.
  Locally on Linux/macOS: `BUX_RUNTIME=win ./tools/smoke_windows_hello.sh`.

Parallel Linux jobs set `BUX_SKIP_BUILD=1` after downloading the `buxc` artifact.
Locally, `make test` still runs the full suite sequentially and builds once.
`make test-examples-smoke` runs the macOS-sized subset locally.

`make test` includes examples, goldens, registry, apps, DWARF, unit tests, and selfhost smoke
(not the slow gen2↔gen3 fixed-point).

### Selfhost loop (optional CI)
```bash
make selfhost-loop                 # bootstrap builds src/ twice; C+ELF match
BUX_SELFHOST_FIXED_POINT=1 make selfhost-loop   # buxc2→buxc3→buxc4 fixed-point
```
Fixed-point compares **gen2 vs gen3** (same selfhost C backend), not bootstrap
vs selfhost. Not part of default `make test`.

### Format (`bux fmt`)
```bash
./buxc fmt examples/hello.bux  # reformat one file
./buxc fmt lib/                # reformat a directory tree
make fmt                       # reformat lib/ examples/ src/ tests/ apps/
./buxc fmt --check path/       # exit 1 if any file would change
make fmt-check                 # CI: full-tree clean + dirty smoke
```

Indentation is 4 spaces by brace depth. The formatter is idempotent (safe to re-run).
`make fmt-check` enforces a clean tree under `lib/`, `examples/`, `src/`, `tests/`, and `apps/`.

### Stdlib golden tests
```bash
make test-stdlib
# or: tests/stdlib_golden/run.sh ./buxc
```

Behavioral packages under `tests/stdlib_golden/` (`array`, `string`, `collections`)
assert core Array/String/Map/Set/Result/Option APIs and match expected `PASS` lines.

### API docs (`bux doc`)
```bash
./buxc doc lib/                      # Markdown to stdout
./buxc doc --out docs/api/stdlib.md lib/
make docs                            # writes docs/api/stdlib.md
```

Scans `///` line comments (and bootstrap also accepts adjacent `/* */`) immediately
before `func` / `struct` / `enum` / `interface` / `module` declarations.

### Language Server (`bux-lsp` 0.4.0)
```bash
make lsp                             # → tools/bux-lsp
nim r --path:bootstrap tools/test_lsp_locals.nim
./tools/smoke_lsp_hover.sh
```

Features: diagnostics (`buxc check`), hover, go-to-def, outline, completion.
**Locals are position-sensitive** (nested scopes / shadowing). **Inferred `let` types**
appear on hover (`let x: int · inferred`).

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
│   ├── runtime.c          # full POSIX + OpenSSL (Unix default)
│   ├── runtime_minimal.c  # thin: no pthread/net/crypto (static/embed)
│   ├── runtime_win.c      # MinGW historical (BUX_RUNTIME=win)
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
