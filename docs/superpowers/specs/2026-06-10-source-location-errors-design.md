# Bux Source Location Tracking in Error Messages — Design Document

> **Date:** 2026-06-10
> **Status:** Design Approved
> **Scope:** MVP Rust-style error messages with code snippets for parser and sema diagnostics

---

## 1. Overview

The Bux self-hosted compiler already tracks source locations (lexer tokens have line/column, AST nodes have line/column, parser and sema have diagnostic structs with line/column). However, the CLI prints errors as plain strings or raw `line X col Y` text, without code snippets or consistent formatting.

This feature unifies and improves error display to match the Rust-style format:
```
error: type mismatch
  --> src/Main.bux:42:15
   |
42 | let x: int = "hello";
   |              ^
```

### Goals
- Unified Rust-style error formatting for all parser and sema diagnostics
- Code snippets showing the exact line with an underline
- Consistent severity prefixes (`error:`, `warning:`, `note:`)

### Non-Goals (for MVP)
- Source maps (mapping merged-source line numbers back to original files)
- Multi-line error spans
- Multi-character underlines (`^^^^` for entire tokens)
- Colorized output
- Error codes (e.g., `E0001`)
- HIR lower / C backend diagnostics (these phases do not currently emit errors)

---

## 2. Architecture

```
┌─────────────────────────────────────────┐
│  Parser/Sema Diagnostics                │
│  ParserDiag { line, col, message }      │
│  SemaDiag   { line, col, message }      │
└─────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────┐
│  Unified Diagnostic Formatter           │
│  (inline in cli.bux or lib/Diagnostic)  │
│  • Reads source line from file          │
│  • Formats snippet with underline       │
│  • Prints Rust-style error block        │
└─────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────┐
│  CLI Output                             │
│  error: type mismatch                   │
│    --> src/Main.bux:42:15               │
│     |                                   │
│  42 | let x: int = "hello";             │
│     |              ^                    │
└─────────────────────────────────────────┘
```

### Components

1. **Source Line Loader** — reads a specific line from a source file
2. **Snippet Renderer** — formats `line_num | code` + underline
3. **Diagnostic Printer** — assembles the full Rust-style error block

**Note:** Bux compiles a merged source file (all `.bux` files merged before compilation). For MVP, snippets show lines from the merged source. Source map tracking (which original file a line came from) is future work.

---

## 3. Data Structures

```bux
struct Diagnostic {
    message: String;
    line: uint32;       /* 1-based */
    column: uint32;     /* 1-based */
    severity: int;      /* 0=error, 1=warning, 2=note */
}
```

**Severity values:**
- `0` — `error:`
- `1` — `warning:`
- `2` — `note:`

For MVP, parser and sema diagnostics are always severity `0` (error). Warning/note severity is reserved for future use.

---

## 4. API Design

```bux
/* Print a single diagnostic in Rust-style format */
func Diagnostic_Print(diag: *Diagnostic, sourcePath: String);

/* Helper: read line N from a file (1-based) */
func Diagnostic_GetLine(path: String, lineNum: uint32) -> String;
```

### Output Format

```
error: <message>
  --> <path>:<line>:<col>
   |
<ln> | <source_line>
   | <spaces>^
```

Where:
- `<ln>` is the line number, right-aligned
- `<spaces>` is `column - 1` spaces to position the `^`
- If `source_line` is empty (file not found), only the header is printed

---

## 5. Snippet Rendering Algorithm

### `Diagnostic_GetLine(path, lineNum)`

1. Open the file at `path`
2. Read character by character, counting newlines
3. When reaching line `lineNum`, accumulate characters until `\n` or EOF
4. Return the accumulated string (without trailing `\n`)
5. If file cannot be opened or `lineNum` exceeds file length, return `""`

### `Diagnostic_Print(diag, sourcePath)`

```
Print severity prefix + message
Print "  --> " + sourcePath + ":" + line + ":" + column + "\n"
Print "   |\n"
Print line number + " | " + source line + "\n"
Print "   | " + (column-1 spaces) + "^\n"
```

**Underline:** Single `^` at the column position. Multi-character spans are future work.

---

## 6. Integration Points

### Parser Diagnostics

**Current code** (`src/cli.bux`, lexer error printing):
```bux
PrintLine(lex.diags[i].message);
```

**New code:**
```bux
let diag: Diagnostic = Diagnostic {
    message: lex.diags[i].message,
    line: lex.diags[i].line,
    column: lex.diags[i].column,
    severity: 0,
};
Diagnostic_Print(&diag, sourcePath);
```

### Sema Diagnostics

**Current code** (`src/cli.bux`, `Cli_Compile` path):
```bux
PrintLine(sema.diags[i].message);
```

**Current code** (`src/cli.bux`, `Cli_BuildProject` path):
```bux
Print("  line "); PrintInt(sema.diags[i].line as int64);
Print(" col ");  PrintInt(sema.diags[i].column as int64);
Print(": ");     PrintLine(sema.diags[i].message);
```

**New code (both paths):**
```bux
let diag: Diagnostic = Diagnostic {
    message: sema.diags[i].message,
    line: sema.diags[i].line,
    column: sema.diags[i].column,
    severity: 0,
};
Diagnostic_Print(&diag, sourcePath);
```

### Unified Helper

Add to `src/cli.bux`:
```bux
func Cli_ReportSemaErrors(sema: *Sema, sourcePath: String) {
    let i: int = 0;
    while i < Sema_DiagCount(sema) {
        let d: SemaDiag = sema.diags[i];
        let diag: Diagnostic = Diagnostic {
            message: d.message, line: d.line,
            column: d.column, severity: 0,
        };
        Diagnostic_Print(&diag, sourcePath);
        i = i + 1;
    }
}
```

---

## 7. Files to Modify

| File | Change |
|------|--------|
| `src/cli.bux` | Replace all manual error printing with `Diagnostic_Print`. Add `Diagnostic` struct and helper functions. |

**No changes needed to:**
- `src/lexer.bux` — already emits `LexerDiag` with line/col
- `src/parser.bux` — already emits `ParserDiag` with line/col
- `src/sema.bux` — already emits `SemaDiag` with line/col via `Sema_EmitError`
- `src/ast.bux` — already stores line/col on every node
- `src/hir.bux` — already stores line/col on HIR nodes

---

## 8. Testing Strategy

1. **Type error test:** Create a `.bux` file with `let x: int = "hello";` → build → verify Rust-style output with snippet
2. **Syntax error test:** Create a `.bux` file with missing `}` → build → verify parser error shows snippet
3. **Selfhost loop:** Verify compiler C output remains identical (CLI changes do not affect codegen)

---

## 9. Future Work

- **Source maps:** Track which original file each merged line came from, so errors show original paths
- **Multi-character underlines:** Underline entire token/span, not just a single `^`
- **Colorized output:** ANSI color codes for error/warning/note
- **Error codes:** Assign stable codes like `E0001` for each error type
- **Notes and help text:** Attach explanatory notes to errors (Rust's `help:` and `note:` blocks)
