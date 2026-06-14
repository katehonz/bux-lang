# Fix Drop/Operator `[]` Generic Type Bug in Bootstrap

> **Date:** 2026-06-14  
> **Status:** Approved  
> **Scope:** Bootstrap compiler (`bootstrap/*.nim`) — specifically `_test_drop_trait` and `_test_checked_index`

## 1. Problem Statement

The bootstrap compiler already supports `@[Drop]` types, auto-drop, and generic operator overloading (`operator []`), but the interaction between these features produces wrong types or spurious type errors.

Two integration tests currently fail:

- `_test_drop_trait`: `expected int, got float32 at 9:13` when reading `arr[0]` from an `Array<int>`.
- `_test_checked_index`: `cannot assign int to Array at 11:5` when using the checked index operator on `Array<T>`.

Both failures suggest that generic type substitution (`T -> int`) is not applied correctly to the return type of `operator []` when the operator is invoked from generated auto-drop or checked-index code paths.

## 2. Goals

1. Make `_test_drop_trait` pass.
2. Make `_test_checked_index` pass.
3. Keep the fix minimal and confined to the bootstrap compiler.
4. Ensure `make test`, `make selfhost`, and `make selfhost-loop` continue to pass.

## 3. Non-Goals

1. Rewriting the `apps/` example applications (excluded per user request).
2. Adding new language features; this is a bug-fix task only.
3. Changing the selfhost compiler (`src/*.bux`) unless the same bug exists there and is required for selfhost-loop.
4. Fixing unrelated `for ... in` or `Slice<T>` failures (tracked separately).

## 4. Investigation Plan

1. Reproduce both failures with `build/buxc run` in each `_test_*` directory.
2. Read the source of `_test_drop_trait/src/Main.bux` and `_test_checked_index/src/Main.bux`.
3. Trace how the bootstrap compiler resolves `operator []` for `Array<T>`:
   - Parser/AST representation of the call.
   - Semantic analysis (`sema.nim`) overload resolution and generic substitution.
   - HIR lowering (`hir_lower.nim`) of operator calls and auto-drop.
   - LIR lowering/C backend (`lir_lower.nim`, `lir_c_backend.nim`) type emission.
4. Identify the exact location where the return type of the selected operator overload retains an unsubstituted generic parameter.

## 5. Hypothesis

When `@[Drop]` causes the compiler to synthesize an `Array_Drop` call (or when `@[Checked]` synthesizes a bounds-checked `operator []` call), the generic substitution context is not threaded into the operator overload resolution. As a result, `T` remains as the generic parameter instead of being replaced by `int`, leading to:

- A fallback/primitive type mismatch (`float32` appears when no substitution occurs).
- A type assignment error because the returned value is treated as `Array` instead of `int`.

## 6. Proposed Fix

Investigation showed the root cause spans both semantic analysis and HIR lowering:

1. **Sema (`bootstrap/sema.nim`)**:
   - Preserve generic type arguments on `tkNamed` in `resolveType`.
   - Resolve explicit generic-call return types with the concrete type arguments substituted.
   - Substitute method type parameters when looking up `operator_index_get`, including through pointer receivers.
   - Skip strict argument-type checks for generic function calls; these are deferred to inference/monomorphization.

2. **HIR lowering (`bootstrap/hir_lower.nim`)**:
   - Build a local type-parameter substitution map when generating generic struct instances inside `substituteType`.
   - Register parameter types in `varTypeExprs` after clearing the per-function table so pointer parameters are visible when lowering operator calls.

The fix should be the smallest change that makes the two tests pass without breaking other tests.

## 7. Affected Files

| File | Expected Change |
|------|-----------------|
| `bootstrap/sema.nim` | Preserve type args, substitute in operator/index lookup, defer generic call arg checks. |
| `bootstrap/hir_lower.nim` | Fix generic struct monomorphization and parameter visibility. |
| `_test_drop_trait/src/Main.bux` | No changes. |
| `_test_checked_index/src/Main.bux` | No changes. |

## 8. Testing Plan

### 8.1 Target Tests

```bash
cd _test_drop_trait && ../../build/buxc run && cd ..
cd _test_checked_index && ../../build/buxc run && cd ..
```

Expected: both exit 0.

### 8.2 Regression Tests

```bash
make test
make selfhost
make selfhost-loop
```

Expected: all pass / no changes in selfhost-loop output.

### 8.3 Optional Cross-Check

Run remaining `_test_*` packages to confirm no new failures:

```bash
for d in _test_*; do
  echo "=== $d ==="
  (cd "$d" && ../../build/buxc run) || true
done
```

## 9. Success Criteria

- `_test_drop_trait` reports PASS.
- `_test_checked_index` reports PASS.
- `make test` reports no new failures.
- `make selfhost-loop` remains deterministic (identical C + stripped ELF).

## 10. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Fix touches generic resolution and breaks other tests | Run full test suite and selfhost-loop before committing. |
| Same bug exists in selfhost compiler | Selfhost-loop will catch type/output differences; fix selfhost only if required. |
| Root cause is deeper than operator substitution | Time-box investigation; if not resolved in a reasonable number of iterations, escalate to user with findings. |

## 11. Relation to Other Work

- `docs/superpowers/specs/2026-06-10-drop-trait-design.md` covers universal auto-drop in the **selfhost** compiler. This document covers the **bootstrap** compiler's Drop/operator interaction bug and is independent of the selfhost work.
