# Self-hosted compiler: semantic error recovery

**Date:** 2026-07-28
**Scope:** Self-hosted Bux compiler only (`src/sema.bux`, `src/cli.bux`)
**Status:** Approved design

## Goal

When the self-hosted compiler performs semantic analysis, it must report **all independent semantic errors** in a single run instead of stopping after the first one. Users should see every type mismatch, undeclared identifier, return-type error, etc., before the compiler exits with failure.

## Current state

- `src/sema.bux` already collects diagnostics in `Sema.diags` via `Sema_EmitError` and sets `Sema.hasError`.
- `Sema_Analyze` walks every top-level declaration, so errors in different functions are all collected.
- However, inside a single function, several `Sema_EmitError` call sites are followed by an early `return` (or by returning `tyUnknown` in a way that aborts the parent expression). This truncates checking of the remaining statements/sub-expressions and hides errors.
- `src/cli.bux` correctly prints all collected semantic diagnostics and skips HIR lowering / C codegen when `Sema_HasError` is true.

## Decision

Implement **expression-level recovery with an error sentinel** (`tyUnknown`):

- Every error path in `Sema_CheckExpr` must return `tyUnknown` and must not abort the parent check.
- Every error path in `Sema_CheckStmt` must record the diagnostic and then continue with the next statement (no early `return` that skips the rest of the block/function).
- `tyUnknown` is already treated as numeric-compatible in `Sema_IsNumeric`; audit the other predicates and error sites so `tyUnknown` suppresses cascading errors rather than causing them.

## Non-goals

- No changes to the bootstrap Nim compiler (`bootstrap/*.nim`).
- No parser recovery in this work item; parser errors still stop the pipeline before semantic analysis.
- No "best-effort codegen": if semantic errors exist, HIR lowering and C generation are still skipped.

## Architecture

### Sema context

`Sema` keeps its existing diagnostic storage:

```bux
struct Sema {
    // ... existing fields ...
    diagCount: int;
    diags: *SemaDiag;
    hasError: bool;
}
```

`Sema_EmitError` remains the low-level reporter.

### Error sentinel helper

Add a small helper for expression-level errors:

```bux
func Sema_EmitExprError(sema: *Sema, expr: *Expr, msg: String) -> int {
    Sema_EmitError(sema, expr.line, expr.column, msg);
    let te: *TypeExpr = bux_alloc(sizeof(TypeExpr)) as *TypeExpr;
    te.kind = tekNamed;
    te.typeName = "?";
    expr.refType = te;
    return tyUnknown;
}
```

Callers use it like:

```bux
return Sema_EmitExprError(sema, expr, "undeclared identifier 'foo'");
```

This makes the "record error + return sentinel" pattern explicit and harder to get wrong.

### Statement-level recovery

Audit `Sema_CheckStmt`:

- After any `Sema_EmitError` inside a statement handler, the handler must fall through to the normal `return` at the end of that branch so that the caller (`Sema_CheckBlock` / `Sema_Analyze`) continues with the next statement.
- Example: `if` condition not `bool` must still check `then`/`else` blocks before returning.

### Expression-level recovery

Audit `Sema_CheckExpr`:

- Binary/unary/call/index expressions: always check both/all children before deciding whether the parent expression has a valid type.
- When a child returns `tyUnknown`, the parent must return `tyUnknown` (or the already-known result type for comparisons) without emitting a second, derived error.
- `Sema_IsNumeric` already returns `true` for `tyUnknown`; keep that behavior. Check `Sema_IsBool` and any custom predicates that might emit follow-up errors on `tyUnknown`.

### CLI behavior

`src/cli.bux` keeps the current flow:

1. `Sema_Analyze(mod)`
2. If `Sema_HasError(sema)` → print every `sema.diags[i]` with `Diagnostic_Print` and return failure (`""` / exit code 1).
3. Only if no errors → `HirLower_LowerModule` → `CBackend_Generate`.

This guarantees that code generation never runs on an AST with semantic errors.

## Data flow

```text
Source
  → Lexer
  → Parser
  → Macro expand
  → Sema_Analyze
      ├─ Sema_CollectGlobals
      └─ for each func: Sema_CheckStmt / Sema_CheckExpr
            ├─ error → Sema_EmitError / Sema_EmitExprError → tyUnknown → continue
            └─ ok    → normal type
  → if hasError: print all diags, exit 1
  → else: HirLower → CBackend → cc
```

## Error handling rules

1. **Never panic/abort** for user-source errors.
2. **Never skip** checking the rest of a block because one statement failed.
3. **Never emit a cascading error** on an expression whose type is already `tyUnknown`.
4. **Do not generate code** when `hasError` is true.

## Testing

Create `_test_error_recovery/`:

- `src/Main.bux` contains multiple independent semantic errors, e.g.:

```bux
import Std::Io::{PrintLine, PrintInt};

func Main() -> int {
    let x: int = "hello";
    let y: bool = 42;
    PrintInt(x + y);
    PrintLine(undefined_variable);
    return 0;
}
```

Expected `buxc2 check` (self-hosted) output: all semantic errors listed in one run.

### Known blocker

`make selfhost` currently fails because the bootstrap parser rejects `if` used as an expression in `src/hir_lower.bux:2726`. The changes in this design are in `src/sema.bux` and `src/cli.bux`, so they can be syntax-checked with the bootstrap parser, but the new recovery behavior cannot be exercised end-to-end until that parser gap is fixed.

## Risks

- Changing `Sema_CheckStmt`/`Sema_CheckExpr` control flow may accidentally alter valid-code behavior; keep the diff minimal and only move/eliminate early `return`s that follow error emission.
- `tyUnknown` suppression logic relies on existing predicates; missing one predicate may produce noisy cascading diagnostics.
- Self-hosted compiler cannot be built right now, so runtime verification of `buxc2` diagnostics is blocked.
