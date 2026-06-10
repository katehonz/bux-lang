# Drop Trait / Destructors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the `ctx.checkedFunc` gate so that `@[Drop]` types are automatically cleaned up in ALL functions, not just `@[Checked]` ones.

**Architecture:** A one-line change in `src/hir_lower.bux` removes the checked-function gate from auto-drop generation. The existing C backend already handles defer emission and moved-variable skipping correctly.

**Tech Stack:** Bux selfhost compiler, C backend, make

---

## File Structure

| File | Responsibility |
|------|---------------|
| `src/hir_lower.bux` | Contains the auto-drop logic gated by `ctx.checkedFunc` at line 1120 |
| `_test_drop_user/src/Main.bux` | Existing test with `@[Checked]` — will be updated to verify universal drop |
| `_test_drop_move/src/Main.bux` | Existing test verifying moved vars are skipped — must still pass |
| `docs/superpowers/specs/2026-06-10-drop-trait-design.md` | Design document (already written) |

---

## Task 1: Remove checkedFunc Gate from Auto-Drop

**Files:**
- Modify: `src/hir_lower.bux:1120`

**Context:** The current code at line 1120 reads:
```bux
if ctx.checkedFunc && !String_Eq(alloca.typeName, "") {
```

This gate restricts auto-drop to `@[Checked]` functions only.

- [ ] **Step 1: Remove the `ctx.checkedFunc &&` condition**

Replace line 1120:
```bux
        // Auto-Drop for heap-allocated stdlib types in @[Checked] functions
        var deferNode: *HirNode = null as *HirNode;
        if ctx.checkedFunc && !String_Eq(alloca.typeName, "") {
```

With:
```bux
        // Auto-Drop for @[Drop] types and heap-allocated stdlib types
        var deferNode: *HirNode = null as *HirNode;
        if !String_Eq(alloca.typeName, "") {
```

- [ ] **Step 2: Verify the selfhost compiler builds**

Run:
```bash
cd /home/ziko/z-git/bux/bux && make selfhost-loop
```

Expected: C output is IDENTICAL on both iterations.

- [ ] **Step 3: Commit**

```bash
git add src/hir_lower.bux
git commit -m "feat(drop): remove checkedFunc gate from auto-drop"
```

---

## Task 2: Update `_test_drop_user` to Verify Universal Drop

**Files:**
- Modify: `_test_drop_user/src/Main.bux`

**Context:** The existing test uses `@[Checked]` on the function. We remove it to prove drop works in unchecked functions too.

- [ ] **Step 1: Remove `@[Checked]` from the test function**

Current content of `_test_drop_user/src/Main.bux`:
```bux
@[Drop]
struct Buffer {
    ptr: *int
}

func Buffer_Drop(self: *Buffer) {
    bux_free(self.ptr as *void);
}

@[Checked]
func main() -> int {
    let buf: Buffer = Buffer { ptr: bux_alloc(10 as uint * sizeof(int)) as *int };

    // Buffer should be auto-dropped here via Buffer_Drop(&buf)
    return 0;
}
```

Replace with:
```bux
@[Drop]
struct Buffer {
    ptr: *int
}

func Buffer_Drop(self: *Buffer) {
    bux_free(self.ptr as *void);
}

func main() -> int {
    let buf: Buffer = Buffer { ptr: bux_alloc(10 as uint * sizeof(int)) as *int };

    // Buffer should be auto-dropped here via Buffer_Drop(&buf)
    return 0;
}
```

- [ ] **Step 2: Build and run the test**

Run:
```bash
cd /home/ziko/z-git/bux/bux/_test_drop_user && /home/ziko/z-git/bux/bux/build/buxc build && ./build/test_drop_user
```

Expected: Build succeeds, runs without crash (no double-free, no leak).

- [ ] **Step 3: Commit**

```bash
git add _test_drop_user/src/Main.bux
git commit -m "test(drop): verify auto-drop works without @[Checked]"
```

---

## Task 3: Verify `_test_drop_move` Still Works

**Files:**
- No changes — verification only

**Context:** Moved variables must NOT be double-freed. The existing C backend logic (`CBE_IsMoved`) handles this.

- [ ] **Step 1: Build and run the move test**

Run:
```bash
cd /home/ziko/z-git/bux/bux/_test_drop_move && /home/ziko/z-git/bux/bux/build/buxc build && ./build/test_drop_move
```

Expected: Build succeeds, runs without crash. Only `y` is dropped; `x` is skipped because it was moved.

- [ ] **Step 2: Commit (if any fixes needed)**

If the test fails, debug and fix. Otherwise no commit needed.

---

## Task 4: Selfhost Bootstrap Loop Verification

**Files:**
- No changes — verification only

- [ ] **Step 1: Run selfhost loop**

Run:
```bash
cd /home/ziko/z-git/bux/bux && make selfhost-loop
```

Expected: Completes without errors, C output IDENTICAL on both iterations.

- [ ] **Step 2: If loop fails, debug**

Common issues:
- C output differs → check if removing `ctx.checkedFunc` affects codegen of the compiler itself. The compiler's own source does not use `@[Drop]` heavily, so this is unlikely.
- Bootstrap compiler fails → syntax error in new Bux code (unlikely for a 1-line change).

- [ ] **Step 3: Commit fixes if needed**

```bash
git add -A && git commit -m "fix: ensure selfhost loop compatibility after auto-drop change"
```

---

## Task 5: Push to Git

- [ ] **Step 1: Push**

```bash
git push origin main
```

---

## Spec Coverage Check

| Spec Section | Implementing Task |
|-------------|-------------------|
| Remove `ctx.checkedFunc` gate | Task 1 |
| Universal drop in unchecked functions | Task 2 (test verifies) |
| Move semantics preserved | Task 3 |
| Selfhost loop compatibility | Task 4 |

## Placeholder Scan

- No TBD, TODO, or "implement later" strings.
- All code is complete and copy-paste ready.
- All file paths are exact.
- All commands have expected output.
