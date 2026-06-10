# Drop Trait / Destructors Design Document

> **Date:** 2026-06-10  
> **Status:** Approved  
> **Scope:** Selfhost compiler (`src/*.bux`)

## 1. Problem Statement

The `@[Drop]` attribute and auto-drop mechanism already exist in the selfhost compiler, but they are **restricted to `@[Checked]` functions only**. This means regular (unchecked) code does not receive automatic cleanup for resource-holding types. The programmer must manually call `TypeName_Drop()` or use `defer`.

This is inconsistent with the goal of making Bux "safe by choice" — if a type declares it needs cleanup (`@[Drop]`), that cleanup should happen regardless of whether the function is checked.

## 2. Goals

1. **Universal auto-drop**: `@[Drop]` types are automatically cleaned up when they go out of scope in **all** functions, not just `@[Checked]` ones.
2. **Preserve move semantics**: Variables that have been moved are NOT double-freed (existing `CBE_IsMoved` logic stays).
3. **No breaking changes**: Existing code continues to work; we only *add* cleanup where it was previously skipped.
4. **Selfhost loop compatibility**: The compiler must still bootstrap deterministically after these changes.

## 3. Non-Goals

1. **`own T` type**: Adding `own T` to the selfhost type system is a separate, larger feature. This design works with the existing value-semantics + `@[Drop]` model.
2. **Scoped defers on break/continue**: The selfhost C backend currently does not emit defers on `break`/`continue` (unlike bootstrap). Fixing this is tracked separately.
3. **Drop trait interface dispatch**: Auto-drop uses static lookup of `TypeName_Drop`, not interface vtables. This is intentional — zero runtime cost.

## 4. Architecture

### 4.1 Before (Current)

```bux
// hir_lower.bux:1118-1139
if ctx.checkedFunc && !String_Eq(alloca.typeName, "") {
    // build auto-drop defer
}
```

Only checked functions get auto-drop.

### 4.2 After (Proposed)

```bux
// hir_lower.bux:1118-1139
if !String_Eq(alloca.typeName, "") {
    // build auto-drop defer
}
```

All functions get auto-drop for `@[Drop]` types.

### 4.3 How It Works

1. **Parser**: `@[Drop]` attribute on struct → `decl.isDrop = 1`
2. **HIR Lowering** (`hir_lower.bux`):
   - When lowering a `let` binding, after the `hStore`/ `hAlloca`:
   - Call `Lcx_BuildAutoDropFree(ctx, typeName)` to find the drop function name
   - If found, wrap it in `hDefer` and append to statement chain
   - **Remove** the `ctx.checkedFunc` gate
3. **C Backend** (`c_backend.bux`):
   - `CBE_EmitDefers` already handles:
     - LIFO order
     - Skip moved variables (`CBE_IsMoved`)
   - No changes needed in C backend

## 5. Affected Files

| File | Change |
|------|--------|
| `src/hir_lower.bux` | Remove `ctx.checkedFunc &&` condition on line 1120 |
| `_test_drop_user/src/Main.bux` | Remove `@[Checked]` from test to verify universal drop |
| `_test_drop_trait/src/Main.bux` | Fix syntax (already broken — `module Main;` + indexing) |

## 6. Testing Plan

### 6.1 Existing Tests

| Test | Expected |
|------|----------|
| `_test_drop_user` | Should pass WITHOUT `@[Checked]` |
| `_test_drop_move` | Should still skip drop for moved vars |
| `selfhost-loop` | C output must remain identical |

### 6.2 New Test (Optional)

Create `_test_drop_universal/src/Main.bux`:
```bux
@[Drop]
struct Resource {
    id: int
}

var dropCount: int = 0;

func Resource_Drop(self: *Resource) {
    dropCount = dropCount + 1;
}

func Main() -> int {
    // NOT @[Checked]
    let r: Resource = Resource { id: 1 };
    // r should be auto-dropped here
    return dropCount;  // expect 1
}
```

## 7. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Existing unchecked code now gets implicit drops | This is the intended behavior. Types with `@[Drop]` explicitly opt-in. |
| Performance impact from extra defer calls | Minimal — defers are inlined as direct C calls. No runtime overhead. |
| Selfhost loop breaks | Test `make selfhost-loop` before committing. |

## 8. Future Work

1. **`own T` in selfhost**: Add `own T` type expression + move-on-pass semantics (like bootstrap).
2. **Scoped defers on break/continue**: Match bootstrap behavior.
3. **Drop trait interface check**: Verify at compile time that `@[Drop]` types actually implement `Drop` interface (has `TypeName_Drop` method).

## 9. Placeholder Scan

- No TBD/TODO placeholders.
- All file paths are exact.
- All code is copy-paste ready.
