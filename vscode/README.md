# Bux Language Support for VS Code

Syntax highlighting, snippets, editor defaults, and **Language Server Protocol** integration for the [Bux](https://github.com/katehonz/bux) programming language.

## Features

| Area | What you get |
|------|----------------|
| **Syntax** | Keywords, types, `f"..."` interpolation, raw `` `...` `` strings, C-strings, macros (`macro!` / `name!()`), attributes (`@[Checked]`), numbers (hex/bin/oct + suffixes), lifetimes |
| **Snippets** | `main`, `func`, `struct`, `enum`, `match`, `interface`, `extend`, `macro`, `checked`, … |
| **LSP** | **Live error underlines** (red squiggles on edit), completion, hover, go-to-definition, references, rename, document/workspace symbols, call hierarchy, type hierarchy, go-to-implementation |
| **Editor** | Bracket colorization, smart indent / on-enter, fold regions (`// region`) |
| **Build** | `buxc` problem matcher for Tasks |

## Requirements

1. **VS Code** ≥ 1.85  
2. **`bux-lsp`** binary (from this repo):

```bash
# from the Bux repository root
make lsp
# → tools/bux-lsp
```

The extension auto-discovers the server in this order:

1. Setting `bux.lsp.path` (absolute, relative, or command name)
2. `tools/bux-lsp` under any workspace folder (and parent folders for monorepos)
3. `bux-lsp` on your `PATH`

## Install (development)

```bash
cd vscode
npm install
npm run compile

# Launch Extension Development Host: F5 in VS Code,
# or install the folder as an extension:
code --install-extension .
# or package:
npx @vscode/vsce package
code --install-extension bux-lang-0.2.0.vsix
```

Symlink into your extensions dir (Linux):

```bash
ln -sfn "$(pwd)/vscode" ~/.vscode/extensions/bux-lang.bux-lang-0.2.0
```

## Commands

| Command | Description |
|---------|-------------|
| **Bux: Restart Language Server** | Stop and start `bux-lsp` |
| **Bux: Stop Language Server** | Disconnect the client |
| **Bux: Show Output Channel** | Open the Bux log |

Status bar item **Bux** (left): click to restart. Red = missing binary / start failure.

## Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `bux.lsp.enabled` | `true` | Master switch for the language server |
| `bux.lsp.path` | `"bux-lsp"` | Path or command for the server binary |
| `bux-lsp.trace.server` | `off` | LSP wire trace (`off` / `messages` / `verbose`) |

## LSP capabilities (bux-lsp)

Provided by `tools/lsp_server.nim` (see `make lsp` / `make test-lsp`):

- `textDocument/completion`, `hover`, `definition`, `references`, `rename`
- `documentSymbol`, `workspace/symbol`
- Call hierarchy, type hierarchy, `implementation`
- Diagnostics on open/save (via analyzer / `buxc`)

## Troubleshooting

1. Status bar shows **error** → run `make lsp` and ensure `tools/bux-lsp` exists and is executable.  
2. **Bux: Show Output Channel** for client logs.  
3. Set `"bux-lsp.trace.server": "verbose"` for JSON-RPC traffic.  
4. Confirm language mode is **Bux** for `.bux` files (status bar language indicator).

## License

MIT — same as the Bux project.
