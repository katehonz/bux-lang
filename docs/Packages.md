# Bux Package Manager

> **Status:** Path + git + **local/file registry** (E.1). HTTP registry index URL optional later.

See also: [SEMVER.md](SEMVER.md) for version policy.

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
greet = { Path = "/abs/path/to/greet" }
Json  = { Version = "2.1", Source = "https://github.com/bux-lang/json" }
Utils = { Path = "../Utils" }
# Registry name-only (resolved by `bux add` / `bux install`):
# greet = "0.1.1"
```

### Dependency Forms

| Form | Example | Description |
|------|---------|-------------|
| Version string | `greet = "0.1.1"` | Registry dependency |
| Wildcard | `greet = "*"` | Latest registry version |
| Inline table (git) | `{ Version = "1.4", Source = "https://..." }` | Git URL + version |
| Inline table (path) | `{ Path = "../Lib" }` | Local path dependency |

---

## Package registry (E.1)

### Index file

Default locations (first hit wins):

1. `$BUX_REGISTRY` — path to a `registry.toml`
2. `~/.bux/registry.toml`
3. `config/registry.toml` next to the Bux repo / compiler

Format:

```toml
[[package]]
name = "greet"
version = "0.1.1"
source = "file:../registry/packages/greet"   # relative to the index file
description = "Hello helpers"

[[package]]
name = "net"
version = "1.0.0"
source = "https://github.com/example/bux-net.git"
description = "TCP helpers"
```

`file:` / `path:` sources are resolved relative to the registry file.
Git URLs are cloned into `~/.bux/packages/<name>/` on install.

### CLI

```bash
# Search the index
bux search
bux search greet

# Add by registry name (writes Path or git Source into bux.toml)
bux add greet
bux add greet 0.1.1

# Explicit sources still work
bux add utils --path "../utils"
bux add network --git "https://github.com/bux-lang/network"

# Resolve + write bux.lock
bux install
```

Demo package in this monorepo: `registry/packages/greet` (registered in
`config/registry.toml`). Smoke test: `tools/smoke_registry.sh`.

---

## CLI Commands

### `bux add <name> [version]`

Add a dependency to `bux.toml` (registry / `--path` / `--git`).

### `bux search [query]`

List packages in the active registry (filter by name/description).

### `bux install`

Resolve dependencies and generate `bux.lock`.

What it does:
1. Reads `[Dependencies]` from `bux.toml`
2. Resolves path-based deps (verifies directory exists)
3. Clones git-based deps to `~/.bux/packages/<name>/`
4. Resolves bare version names via the registry index
5. Generates `bux.lock` with exact versions and sources

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
Name = "greet"
Version = "0.1.1"
Source = "/home/user/z-git/bux/bux/registry/packages/greet"

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
3. **Version-based** deps look up `config/registry.toml` (or `$BUX_REGISTRY`)
4. Dependencies are loaded from `<dep>/src/*.bux` at build time
5. Later declarations shadow earlier ones (project > deps > stdlib)

---

## Example: Creating a Library

```bash
bux new mylib
cd mylib
# Edit src/*.bux → module MyLib { func Add(...) }
# Set Type = "lib" in bux.toml
# Register in your registry.toml with source = "file:..."
bux build
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
