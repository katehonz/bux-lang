# Drop Interface Auto-Drop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the selfhost compiler emit automatic destructor calls for types that implement `Drop` via `extend Type for Drop`, not only for types marked with `@[Drop]`.

**Architecture:** Extend `Lcx_BuildAutoDropFree` in `src/hir_lower.bux` to detect a `TypeName_Drop` function symbol registered by sema for interface-based implementations. Reuse the existing generic monomorphization and C-backend defer paths.

**Tech Stack:** Bux selfhost compiler (Bux language), Nim bootstrap compiler, C backend, GNU make.

---

## File map

| File | Responsibility |
|------|----------------|
| `src/hir_lower.bux` | Detects `TypeName_Drop` methods and wires them into auto-drop defers. |
| `_test_interface_drop/src/Main.bux` | Existing integration test that should now emit `Buffer_Drop(&buf)`. |
| `_test_drop_user/src/Main.bux` | Existing test using `@[Drop]`; must keep working. |
| `_test_drop_move/src/Main.bux` | Existing test verifying moved vars are not double-dropped; must keep working. |
| `_test_drop_trait/src/Main.bux` | Existing test for `Array<int>` auto-drop; must keep working. |

---

### Task 1: Verify the current failure

**Files:**
- Read: `src/hir_lower.bux:2745-2760`
- Read: `_test_interface_drop/build/main.c` (after build)

- [ ] **Step 1: Build the bootstrap compiler**

```bash
cd /home/ziko/z-git/bux/bux
make build
```

Expected: `buxc` is created at project root, build succeeds.

- [ ] **Step 2: Compile `_test_interface_drop` and inspect generated C**

```bash
cd /home/ziko/z-git/bux/bux/_test_interface_drop
../buxc run 2>&1 | tail -5
grep -n "Buffer_Drop" build/main.c
```

Expected: `Buffer_Drop` function is declared/defined, but `main()` does **not** call it before `return 0`. This confirms the bug.

- [ ] **Step 3: Commit the baseline observation (optional)**

No file changes yet; skip commit or note the finding in a scratch file.

---

### Task 2: Extend `Lcx_BuildAutoDropFree` to detect interface Drop

**Files:**
- Modify: `src/hir_lower.bux:2745-2760`

- [ ] **Step 1: Read the exact current code**

```bash
cd /home/ziko/z-git/bux/bux
sed -n '2740,2765p' src/hir_lower.bux
```

Current code (approximate):

```bux
    // User-defined types with @[Drop]: look for TypeName_Drop function
    if typeSym.kind == skType && typeSym.decl != null as *Decl && typeSym.decl.isDrop != 0 {
        let dropName: String = String_Concat(typeName, "_Drop");
        // Ensure inner free is also monomorphized since Drop calls Free
        if String_StartsWith(dropName, "Array_Drop_") {
            let elemType: String = Lcx_GetMangledSuffix(dropName, "Array_Drop_");
            let genDrop: *Decl = Lcx_FindGenericFunc(ctx, "Array_Drop");
            if genDrop != null as *Decl {
                Lcx_GenerateFuncInstance(ctx, genDrop, elemType, "", 1);
            }
        }
        return dropName;
    }
```

- [ ] **Step 2: Modify the check to include interface-based Drop**

Replace the block with:

```bux
    // User-defined types with @[Drop] OR with an explicit TypeName_Drop method
    if typeSym.kind == skType && typeSym.decl != null as *Decl {
        let dropName: String = String_Concat(typeName, "_Drop");
        let hasAttr: bool = typeSym.decl.isDrop != 0;
        let dropSym: Symbol = Scope_Lookup(ctx.scope, dropName);
        let hasMethod: bool = dropSym.kind == skFunc;

        if hasAttr || hasMethod {
            // Ensure inner free is also monomorphized since Drop calls Free
            if String_StartsWith(dropName, "Array_Drop_") {
                let elemType: String = Lcx_GetMangledSuffix(dropName, "Array_Drop_");
                let genDrop: *Decl = Lcx_FindGenericFunc(ctx, "Array_Drop");
                if genDrop != null as *Decl {
                    Lcx_GenerateFuncInstance(ctx, genDrop, elemType, "", 1);
                }
            }
            return dropName;
        }
    }
```

This preserves the `@[Drop]` path and adds the interface path.

- [ ] **Step 3: Rebuild the bootstrap compiler**

```bash
cd /home/ziko/z-git/bux/bux
make build
```

Expected: build succeeds.

- [ ] **Step 4: Verify `_test_interface_drop` now emits the drop call**

```bash
cd /home/ziko/z-git/bux/bux/_test_interface_drop
rm -rf build
../buxc run 2>&1 | tail -5
grep -n "Buffer_Drop" build/main.c
```

Expected: `main()` now contains `Buffer_Drop(&buf);` before `return 0;`.

- [ ] **Step 5: Commit the implementation**

```bash
cd /home/ziko/z-git/bux/bux
git add src/hir_lower.bux
git commit -m "feat(selfhost): auto-drop for interface-based Drop implementations"
```

---

### Task 3: Regression-test existing Drop tests

**Files:**
- Test: `_test_drop_user/src/Main.bux`
- Test: `_test_drop_move/src/Main.bux`
- Test: `_test_drop_trait/src/Main.bux`

- [ ] **Step 1: Compile `_test_drop_user`**

```bash
cd /home/ziko/z-git/bux/bux/_test_drop_user
rm -rf build
../buxc run 2>&1 | tail -5
```

Expected: builds and runs without error.

- [ ] **Step 2: Compile `_test_drop_move`**

```bash
cd /home/ziko/z-git/bux/bux/_test_drop_move
rm -rf build
../buxc run 2>&1 | tail -5
```

Expected: builds and runs without double-free / crash.

- [ ] **Step 3: Compile `_test_drop_trait`**

```bash
cd /home/ziko/z-git/bux/bux/_test_drop_trait
rm -rf build
../buxc run 2>&1 | tail -5
```

Expected: prints `30` and exits cleanly.

- [ ] **Step 4: Commit if all pass**

If any fail, debug before committing. If all pass:

```bash
cd /home/ziko/z-git/bux/bux
git add -A
git commit -m "test: verify existing Drop tests still pass"
```

---

### Task 4: Selfhost-loop determinism check

**Files:**
- All `src/*.bux`

- [ ] **Step 1: Run the selfhost loop**

```bash
cd /home/ziko/z-git/bux/bux
make selfhost-loop
```

Expected output:

```
Selfhost loop passed: C output is identical.
```

- [ ] **Step 2: If it fails, diff the C outputs**

```bash
diff -u build/selfhost-loop-a/build/main.c build/selfhost-loop-b/build/main.c | head -80
```

Investigate any difference. Likely causes:
- Variable naming drift — not expected from this change.
- New monomorphization triggered by the change — acceptable only if deterministic.

- [ ] **Step 3: Commit after passing**

```bash
cd /home/ziko/z-git/bux/bux
git add -A
git commit -m "ci: selfhost-loop passes with Drop interface auto-drop"
```

---

## Spec coverage check

| Spec requirement | Implementing task |
|------------------|-------------------|
| Universal Drop recognition | Task 2 |
| No syntax changes | No task needed |
| Preserve move semantics | Task 2 reuses existing path; Task 3 verifies `_test_drop_move` |
| Selfhost loop compatibility | Task 4 |

## Placeholder scan

- No TBD/TODO/"implement later" markers.
- Each step includes exact file paths and commands.
- Code blocks contain the actual change.

## Type consistency check

- `Scope_Lookup` returns `Symbol` — used correctly.
- `Symbol.kind == skFunc` matches existing patterns in the codebase.
- `typeSym.decl.isDrop != 0` preserved from original code.
