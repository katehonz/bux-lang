# Bux Language Server (`bux-lsp`)

> **Status:** **v0.18.0** — stdio JSON-RPC 2.0 language server  
> **Binary:** `tools/bux-lsp` (`make lsp`)  
> **Editors:** VS Code extension in [`vscode/`](../vscode/README.md); any LSP client via stdio

Bux already ships a real Language Server Protocol implementation. It is **not**
syntax-only: hover and outline use bootstrap semantic analysis when available,
**error underlines (red squiggles)** come from **in-process** lex / parse / type-check
of the **live editor buffer** on every open, edit, and save, and **Format Document**
uses the same indentation engine as `bux fmt`.

---

## Quick start

```bash
# From the repository root
make lsp                 # build → tools/bux-lsp
make vscode              # optional: compile VS Code client
make test-lsp            # unit + smoke tests
```

Point your editor at the binary:

| Client | How |
|--------|-----|
| **VS Code** | Open the repo (or install `vscode/`). Extension auto-finds `tools/bux-lsp`. Setting: `bux.lsp.path` |
| **Neovim** | `vim.lsp.start({ cmd = { "path/to/tools/bux-lsp" }, … })` |
| **Helix / Zed / Emacs** | Configure language server command = `bux-lsp` (stdio) |
| **Any LSP client** | Spawn `bux-lsp` with no args; speak LSP over stdin/stdout |

Protocol framing: standard `Content-Length` headers + JSON-RPC 2.0 body.

---

## Capabilities (v0.18)

| Method | Support | Notes |
|--------|---------|--------|
| `initialize` / `shutdown` / `exit` | ✅ | `serverInfo`: `bux-lsp` 0.18.0 |
| `textDocument/didOpen` / `didChange` / `didSave` | ✅ | Full text sync (`textDocumentSync: 1`) |
| `textDocument/publishDiagnostics` | ✅ | **Live underlines** on open/change/save (in-process); optional `buxc` merge on open/save |
| `textDocument/formatting` | ✅ | Full document — same rules as `bux fmt` (4-space brace indent) |
| `textDocument/rangeFormatting` | ✅ | Applies full-file format (indent depends on whole brace structure) |
| `textDocument/completion` | ✅ | Trigger: `.` `:` |
| `textDocument/hover` | ✅ | Sema types for globals/stdlib; **scoped locals** + inferred `let` |
| `textDocument/definition` | ✅ | Go to definition |
| `textDocument/references` | ✅ | Find all references |
| `textDocument/rename` + `prepareRename` | ✅ | Locals, globals, fields, variants, methods, import path segments |
| `textDocument/documentSymbol` | ✅ | Outline |
| `workspace/symbol` | ✅ | Fuzzy-ish workspace search |
| `textDocument/implementation` | ✅ | Interface → implementing types/methods |
| Call hierarchy | ✅ | prepare / incoming / outgoing (funcs + methods + interface dispatch) |
| Type hierarchy | ✅ | prepare / supertypes / subtypes (`extend T for I`) |

### Version history (high level)

| Ver | Highlights |
|-----|------------|
| 0.2–0.3 | Diagnostics, hover, go-to-def, outline, real sema enrich |
| 0.4 | Position-sensitive locals, inferred `let` types |
| 0.5 | References + rename |
| 0.6 | `workspace/symbol` |
| 0.7–0.10 | Deep rename (fields/variants/methods/paths) |
| 0.8–0.11 | Call hierarchy (methods, interface dispatch) |
| 0.12–0.14 | Module-path rename, `implementation`, workspace import index |
| 0.15–0.16 | Type hierarchy + workspace type-impl index |
| 0.17 | **Live buffer diagnostics** (lex/parse/sema) on every edit — red squiggles without `buxc` on PATH |

---

## VS Code

See **[vscode/README.md](../vscode/README.md)** for install, commands, and settings.

```bash
make vscode
# Status bar: "Bux" — click to restart server
# Commands: Bux: Restart / Stop / Show Output
```

Settings:

- `bux.lsp.enabled` (default `true`)
- `bux.lsp.path` (default `"bux-lsp"`; also searches `tools/bux-lsp`)
- `bux-lsp.trace.server` — `off` | `messages` | `verbose`

---

## Manual smoke (no editor)

```bash
# After make lsp
printf 'Content-Length: 85\r\n\r\n{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' \
  | ./tools/bux-lsp
# Expect a JSON result with "capabilities" and serverInfo version 0.17.0
```

### Error underlines (what students usually want)

Open a `.bux` file with the LSP running. A type error such as:

```bux
func Main() -> int {
    let x: int = "boom";  // red underline under "boom"
    return 0;
}
```

is reported via `textDocument/publishDiagnostics` as soon as the file is opened or
you type (didChange). No save required. Source field: `"bux"` (in-process) or
`"buxc"` (optional CLI merge on open/save).

Automated coverage:

```bash
make test-lsp
# tools/smoke_lsp_diagnostics.sh   ← error underlines
# tools/test_lsp_locals.nim
# tools/smoke_lsp_hover.sh
# tools/smoke_lsp_rename*.sh
# tools/smoke_lsp_*hierarchy*.sh
# …
```

---

## Format Document / format-on-save

`textDocument/formatting` re-indents the buffer with **4 spaces × brace depth**
(identical to `bux fmt` / `bootstrap/fmt.nim`). Idempotent: a clean file yields
an empty edit list.

**VS Code:** the extension defaults `editor.formatOnSave` for `[bux]`. Disable
with `"editor.formatOnSave": false` in workspace settings if you prefer manual
only. Command palette: **Format Document**.

```bash
make test-lsp                 # includes tools/smoke_lsp_formatting.sh
```

## Limitations / not yet

Honest gaps (so Reddit / issue trackers stay accurate):

- **No semantic tokens** provider (TextMate grammar handles highlighting in VS Code)
- **No code actions / lightbulbs** (quick-fixes)
- **No inlay hints**
- **rangeFormatting** reformats the whole file (partial selection cannot get correct indent without full brace context)
- Completion is useful but not a full IDE IntelliSense engine
- Single-process stdio only (no TCP/socket mode)

PRs welcome: `tools/lsp_server.nim`, tests under `tools/smoke_lsp_*.sh` and `make test-lsp`.

---

## Related

| Doc / path | Role |
|------------|------|
| [`tools/lsp_server.nim`](../tools/lsp_server.nim) | Server implementation |
| [`vscode/`](../vscode/) | Official VS Code client |
| [`BuildAndTest.md`](BuildAndTest.md) | Build / test matrix |
| [`Makefile`](../Makefile) targets `lsp`, `test-lsp`, `vscode` |
