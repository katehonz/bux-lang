# Source Location Error Fixes — Design Document

> **Date:** 2026-06-10
> **Status:** Approved
> **Scope:** Parser severity filtering + source maps for merged builds

---

## 1. Parser Diagnostics with Severity

### Problem
Parser is fault-tolerant and generates diagnostics for recoverable errors (e.g., `expected '}'`, `skipping unknown declaration`). The stdlib triggers many of these, but compilation succeeds because the parser recovers.

### Solution
Add `severity` to `ParserDiag`:
```bux
struct ParserDiag {
    line: uint32;
    column: uint32;
    message: String;
    severity: int;  /* 0=error (fatal), 1=warning (recoverable) */
}
```

- `parserExpect()`, `parserEmitDiag()` set severity to `1` (warning/recoverable)
- Only when the parser is completely stuck → severity `0` (fatal)
- In `Parser_Parse`, print ONLY diags with `severity == 0`, OR if `mod.itemCount == 0`

---

## 2. Source Maps for `bux build`

### Problem
`Cli_BuildProject` creates a merged module in memory. Sema errors show `<merged>` as the path because no physical file exists.

### Solution
Before `Sema_Analyze(merged)`, generate the merged source text from all declarations and write it to `build/merged.bux`. Pass this path to `Diagnostic_Print`.

**Result:**
```
error: undeclared identifier 'undefined_variable'
  --> build/merged.bux:507:18
   |
507 |     let x: int = undefined_variable;
   |                  ^
```

The user can open `build/merged.bux` to see the full context.

---

## Files to Modify

| File | Change |
|------|--------|
| `src/parser.bux` | Add `severity` to `ParserDiag`. Set severity in `parserExpect`/`parserEmitDiag`. Print only fatal errors in `Parser_Parse`. |
| `src/cli.bux` | Generate merged source text before `Sema_Analyze`. Write to `build/merged.bux`. Pass path to `Diagnostic_Print`. |
