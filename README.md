# Bux Programming Language

> **Status:** Bootstrap phase — compiler written in Nim, targeting self-hosting.

Bux is a fast, compiled, strongly-typed systems programming language inspired by [Rux](https://rux-lang.dev/). The long-term goal is a self-hosted compiler with a minimal runtime, native x86-64 backend, and modern tooling.

## Quick Start

```bash
# Build the bootstrap compiler (Nim)
make build

# Create a new project
bux new hello

# Build and run
bux run
```

## Syntax Preview

```bux
import Std::Io::PrintLine;

func Main() -> int {
    let message: *char8 = c8"Hello, Bux!";
    PrintLine(message);
    return 0;
}
```

## Roadmap

See [`PLAN.md`](PLAN.md) for the full roadmap to self-hosting.

## License

MIT
