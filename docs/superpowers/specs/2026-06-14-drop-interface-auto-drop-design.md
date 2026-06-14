# Drop Interface Auto-Drop Design Document

> **Date:** 2026-06-14  
> **Status:** Approved  
> **Scope:** Selfhost compiler (`src/*.bux`)

## 1. Problem Statement

Bux already has two ways to declare that a type needs automatic cleanup:

1. **`@[Drop]` attribute** on a struct — triggers auto-drop lookup of `TypeName_Drop`.
2. **`extend Type for Drop { ... }`** — implements the `Drop` interface from `lib/Drop.bux`.

The parser and sema already support both forms, but the HIR lowering step only recognizes the `@[Drop]` attribute. As a result, a type that implements `Drop` via the interface is **not** automatically cleaned up when its variables go out of scope.

Example (`_test_interface_drop/src/Main.bux`):

```bux
import Drop

struct Buffer {
    ptr: *int
}

extend Buffer for Drop {
    func Drop(self: *Buffer) {
        bux_free(self.ptr as *void);
    }
}

func main() -> int {
    let buf: Buffer = Buffer { ptr: bux_alloc(10 as uint * sizeof(int)) as *int };
    return 0;  // Buffer_Drop(&buf) should be emitted here, but currently is not
}
```

## 2. Goals

1. **Universal Drop recognition**: Auto-drop fires for any type that implements `Drop`, whether via `@[Drop]` or via `extend ... for Drop`.
2. **No syntax changes**: The existing `interface Drop` and `extend ... for Drop` syntax remains unchanged.
3. **Preserve move semantics**: Variables that have been moved are still skipped by the existing `CBE_IsMoved` logic.
4. **Selfhost loop compatibility**: The compiler must still bootstrap deterministically.

## 3. Non-Goals

1. **`own T` type**: Adding `own T` to selfhost is a separate, larger feature.
2. **Scoped defers on break/continue**: Tracked separately.
3. **Interface vtable dispatch for auto-drop**: Auto-drop remains static lookup of `TypeName_Drop`; no runtime interface cost.

## 4. Architecture

### 4.1 Before (Current)

In `src/hir_lower.bux`, `Lcx_BuildAutoDropFree` only returns a drop function name when `decl.isDrop != 0`:

```bux
// User-defined types with @[Drop]: look for TypeName_Drop function
if typeSym.kind == skType && typeSym.decl != null as *Decl && typeSym.decl.isDrop != 0 {
    let dropName: String = String_Concat(typeName, "_Drop");
    // ... generic monomorphization ...
    return dropName;
}
```

### 4.2 After (Proposed)

Extend the user-type branch to also detect interface-based implementations:

```bux
// User-defined types with @[Drop] OR with an explicit TypeName_Drop method
if typeSym.kind == skType && typeSym.decl != null as *Decl {
    let dropName: String = String_Concat(typeName, "_Drop");
    let hasAttr: bool = typeSym.decl.isDrop != 0;
    let dropSym: Symbol = Scope_Lookup(ctx.scope, dropName);
    let hasMethod: bool = dropSym.kind == skFunc;

    if hasAttr || hasMethod {
        // ... generic monomorphization ...
        return dropName;
    }
}
```

Sema already registers methods from `extend ... for Drop` as `TypeName_Drop` function symbols in `ctx.scope` (see `src/sema.bux:1197-1207`). Therefore, looking up the method by name is sufficient to detect an interface-based Drop implementation.

### 4.3 Generic Types

For generic `extend Box<T> for Drop { func Drop(self: *Box<T>) { ... } }`, the symbol registered is `Box_Drop` (generic). The existing `Lcx_FindGenericFunc` / `Lcx_GenerateFuncInstance` path in `Lcx_BuildAutoDropFree` handles monomorphization when the concrete type is a mangled generic instance (e.g., `Box_int`). The proposed change reuses that path unchanged.

## 5. Affected Files

| File | Change |
|------|--------|
| `src/hir_lower.bux` | Extend `Lcx_BuildAutoDropFree` to detect `TypeName_Drop` method symbols even without `@[Drop]` attribute. |
| `_test_interface_drop/src/Main.bux` | Verify that `Buffer_Drop(&buf)` is emitted. |

## 6. Testing Plan

### 6.1 Existing Tests

| Test | Expected |
|------|----------|
| `_test_drop_user` | Still passes; `@[Drop]` path unchanged. |
| `_test_drop_move` | Still skips drop for moved vars. |
| `_test_drop_trait` | Still passes; Array auto-drop unchanged. |
| `make selfhost-loop` | C output remains identical. |

### 6.2 Target Test

`_test_interface_drop/src/Main.bux` should compile and the generated `build/main.c` should contain a call to `Buffer_Drop(&buf)` before `return 0`.

## 7. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Any method named `Drop` triggers auto-drop | Acceptable because `Drop` is a privileged interface name. If stricter checking is needed later, sema can record explicit `extend ... for Drop` implementations in a dedicated table. |
| Generic monomorphization missed | Reuse existing generic Drop instance generation path already used for `@[Drop]` types. |
| Selfhost loop breaks | Run `make selfhost-loop` before committing. |

## 8. Future Work

1. **`own T` in selfhost**: Add `own T` type expression + move-on-pass semantics.
2. **Scoped defers on break/continue**: Match bootstrap behavior.
3. **Explicit interface-implementation table**: If the simple method-name lookup becomes too permissive, record `extend ... for Drop` facts in sema and expose them to HIR lowering.

## 9. Placeholder Scan

- No TBD/TODO placeholders.
- All file paths are exact.
- Code snippets match the current selfhost source.
