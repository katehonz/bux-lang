# Bux Package Manager

> **Status:** Implemented (Phase 9.1)

---

## Manifest (`bux.toml`)

Every Bux package has a `bux.toml` at the project root.

```toml
[Package]
Name    = "MyApp"
Version = "0.1.0"
Type    = "bin"          # bin | lib | shared | static
Authors = ["Your Name <you@example.com>"]
License = "MIT"

[Build]
Output = "Bin"

[Dependencies]
Std  = "1.0"
Json = { Version = "2.1", Source = "https://github.com/bux-lang/json" }
Utils = { Path = "../Utils" }
```

### Dependency Forms

| Form | Example | Description |
|------|---------|-------------|
| Version string | `Std = "1.0"` | Registry dependency |
| Wildcard | `Std = "*"` | Latest version |
| Inline table (git) | `{ Version = "1.4", Source = "https://..." }` | Git URL + version |
| Inline table (path) | `{ Path = "../Lib" }` | Local path dependency |

---

## CLI Commands

### `bux add <name> [version]`

Add a dependency to `bux.toml`.

```bash
# Add registry dependency
bux add json "2.1"

# Add path-based dependency
bux add utils --path "../utils"

# Add git dependency
bux add network --git "https://github.com/bux-lang/network"
```

### `bux install`

Resolve dependencies and generate `bux.lock`.

```bash
bux install
```

What it does:
1. Reads `[Dependencies]` from `bux.toml`
2. Resolves path-based deps (verifies directory exists)
3. Clones/pulls git-based deps to `~/.bux/packages/<name>/`
4. Generates `bux.lock` with exact versions and sources

### `bux build` / `bux run`

Automatically reads `bux.lock` and merges dependency source files into the build.

```bash
bux build   # Compile with all dependencies
bux run     # Build and run
```

---

## Lockfile (`bux.lock`)

Auto-generated. **Do not edit manually.**

```toml
[[Package]]
Name = "json"
Version = "2.1.3"
Source = "https://github.com/bux-lang/json"
Checksum = "8dcb2a7f..."

[[Package]]
Name = "utils"
Version = "0.1.0"
Source = "/home/user/projects/utils"
```

The lockfile ensures **reproducible builds** — every developer gets the exact same dependency versions.

---

## Dependency Resolution Rules

1. **Path-based** deps are resolved relative to the manifest directory
2. **Git-based** deps are cloned to `~/.bux/packages/<name>/`
3. **Version-based** deps (without Source) require a registry (future feature)
4. Dependencies are loaded from `<dep>/src/*.bux` at build time
5. Later declarations shadow earlier ones (project > deps > stdlib)

---

## Example: Creating a Library

```bash
bux new mylib
cd mylib
# Edit src/Main.bux → module MyLib { pub func Add(...) }
bux build       # Builds as library (Type = "lib")
```

## Example: Using a Library

```bash
bux new myapp
cd myapp
bux add mylib --path "../mylib"
bux install
# Edit src/Main.bux → import MyLib::Add;
bux run
```
