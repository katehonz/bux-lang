# Fix `for ... in` Iterator Lowering in Bootstrap

> **Date:** 2026-06-14  
> **Status:** Approved  
> **Scope:** Bootstrap compiler (`bootstrap/hir_lower.nim`) — `for <var> in <collection>` loops

## 1. Problem Statement

The `for ... in` collection iterator is already parsed and sema-accepted, but the HIR→C lowering produces broken code for concrete generic collections such as `Array<int>` or `Channel<int>`.

Five integration tests fail because of this:

- `_test_forin_stdlib`: C compilation error `‘x’ undeclared` inside `Main`.
- `_test_forin_channel`: C compilation error `‘msg’ undeclared` inside `Main`.
- `_test_generic_trait`: sema error `cannot assign float32 to int at 12:9` — the loop variable `x` is typed as `float32` instead of `int`.
- `_test_import`: sema error `cannot assign float32 to int at 15:9` — same issue.
- `_test_mono`: sema error `cannot assign float32 to int at 38:9` — same issue.

Two independent bugs are at play:

1. **Missing C declaration:** the loop variable is not emitted as a local variable in the generated C function.
2. **Wrong loop-variable type:** generic `Iter_Next_T` returns an unsubstituted type parameter `T`, which sema treats as `float32` by default.

## 2. Goals

1. Make `_test_forin_stdlib` pass.
2. Make `_test_forin_channel` pass.
3. Make `_test_generic_trait`, `_test_import`, and `_test_mono` pass (or at least no longer fail with the `float32` loop-variable error).
4. Keep the fix minimal and confined to the bootstrap compiler.
5. Ensure `make test` and `make selfhost-loop` continue to pass.

## 3. Non-Goals

1. Rewriting the `apps/` example applications (excluded per user request).
2. Adding new language features such as `break`/`continue` in loops or iterator traits.
3. Changing the selfhost compiler (`src/*.bux`) unless required for selfhost-loop parity.
4. Fixing the unrelated `_test_slice` C typedef bug (tracked separately).
5. Implementing full Destructors / Drop trait (next roadmap milestone after stabilization).

## 4. Background: How `for ... in` Is Lowered

The parser produces `stmtForIn(ident, expr, body)`.

Sema checks the collection expression and infers the loop-variable type from it.

HIR lowering currently desugars the loop to a placeholder infinite `hLoop` that ignores the iterator expression and never declares the loop variable.

The intended lowering depends on the collection type:

- **Array / Iter collections** (from `lib/Iter.bux`):
  ```bux
  let __iter = Array_Iter_T(&collection);
  while (Iter_HasNext_T(&__iter)) {
      let x = Iter_Next_T(&__iter);
      // body
  }
  ```
- **Channel collections** (from `lib/Channel.bux`):
  ```bux
  var x: T;
  while (true) {
      if (!Channel_Recv_Ok_T(&ch, &x)) { break; }
      // body
  }
  ```

## 5. Investigation Plan

1. Read `_test_forin_stdlib/src/Main.bux`, `_test_forin_channel/src/Main.bux`, `_test_generic_trait/src/Main.bux`.
2. Locate `stmtForIn` handling in `bootstrap/hir_lower.nim`.
3. Verify how the iterator variable is introduced into HIR/C:
   - Is it registered in `ctx.varTypes` / `ctx.varTypeExprs`?
   - Is a `hirLet` emitted before the loop body?
4. Verify how `Array_Iter_Next_T` is monomorphized:
   - Does the call get the `_int` suffix?
   - Does the returned `T` get substituted with `int`?
5. Identify the minimal edit that fixes both symptoms.

## 6. Hypothesis

### 6.1 Missing Declaration

The lowering creates the loop body with references to the loop variable, but the declaration site is omitted or not added to the function's local-variable list. As a result, the C backend never emits `int x;`, causing the `undeclared identifier` error.

### 6.2 Wrong Type

When the collection is `Array<int>`, the lowering calls `Array_Iter_Next` (without `_int`) or calls a monomorphized `Array_Iter_Next_int` but assigns its result to a variable whose type was resolved from the generic signature (`T`). Because sema does not substitute `T` for the loop variable, the variable defaults to `float32`.

The fix is likely to:

- Explicitly declare the loop variable with the concrete element type derived from the collection type.
- Ensure `Array_Iter` / `Array_Iter_HasNext` / `Array_Iter_Next` are monomorphized with the collection's type arguments.

## 7. Proposed Fix

The fix spans sema and HIR lowering:

1. **Sema fixes**:
   - In `skFor`, derive the loop-variable type from the collection's element type (`Array<T>` / `Channel<T>` inner type).
   - In `ekField` for structs, build a type-parameter substitution map from the object's concrete type args and apply it to the field type, so `arr.data` on `Array<int>` resolves to `*int`.
   - Fix `typeToTypeExpr` to preserve generic type arguments on named types.

2. **HIR lowering**:
   - Replace the placeholder `skFor` collection branch with real lowering that selects by collection type.
   - **Array / Iter collections**:
     - Extract element type from `Array<T>` or `Iter<T>`.
     - Generate or reuse `Iter_T` struct instance.
     - Generate function instances `Array_Iter_T`, `Iter_HasNext_T`, `Iter_Next_T`.
     - If the collection expression is not a simple identifier, spill it to a temporary `Array_T` variable first.
     - Emit `alloca __iter`, store `Array_Iter_T(&collection)`, then `while (Iter_HasNext_T(&__iter)) { let x = Iter_Next_T(&__iter); body }`.
     - Register `x` in `ctx.varTypeExprs` before lowering the body.
   - **Channel collections**:
     - Extract element type from `Channel<T>`.
     - Generate function instance `Channel_Recv_Ok_T`.
     - Emit `alloca x`, then `while (true) { if (!Channel_Recv_Ok_T(&ch, &x)) break; body }`.

## 8. Affected Files

| File | Expected Change |
|------|-----------------|
| `bootstrap/sema.nim` | Derive loop var type; substitute struct type params on field access; preserve type args in `typeToTypeExpr`. |
| `bootstrap/hir_lower.nim` | Replace placeholder collection `skFor` lowering with Array/Iter and Channel lowerings. |
| `_test_forin_stdlib/src/Main.bux` | No changes. |
| `_test_forin_channel/src/Main.bux` | No changes. |
| `_test_generic_trait/src/Main.bux` | No changes. |
| `_test_import/src/Main.bux` | No changes. |
| `_test_mono/src/Main.bux` | No changes. |

## 9. Testing Plan

### 9.1 Target Tests

```bash
cd _test_forin_stdlib && /home/ziko/z-git/bux/bux/buxc run
cd _test_forin_channel && /home/ziko/z-git/bux/bux/buxc run
cd _test_generic_trait && /home/ziko/z-git/bux/bux/buxc run
cd _test_import && /home/ziko/z-git/bux/bux/buxc run
cd _test_mono && /home/ziko/z-git/bux/bux/buxc run
```

Expected: all exit 0.

### 9.2 Regression Tests

```bash
cd /home/ziko/z-git/bux/bux
make test
make selfhost-loop
```

Expected: all pass / no changes in selfhost-loop output.

## 10. Success Criteria

- `_test_forin_stdlib` reports PASS.
- `_test_forin_channel` reports PASS.
- `_test_generic_trait`, `_test_import`, `_test_mono` no longer fail with the `float32` loop-variable error.
- `make test` reports no new failures.
- `make selfhost-loop` remains deterministic.

## 11. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Fix changes loop lowering and breaks range-based `for i in 0..10` | Keep range-based path separate; only touch `stmtForIn` collection path. |
| Same bug exists in selfhost compiler | Selfhost-loop will catch output differences; fix selfhost only if required. |
| Root cause is deeper than loop lowering | Time-box investigation; report findings if not resolved quickly. |

## 12. Relation to Other Work

- Previous commit `06db492` fixed generic `operator []` resolution. This work continues generic-type propagation into iterator loops.
- `_test_slice` has a separate C typedef bug and is out of scope for this task.
