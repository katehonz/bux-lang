# Self-hosted Sema Error Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the self-hosted Bux compiler (`buxc2`) report all independent semantic errors in a single run instead of stopping after the first one, using a `tyUnknown` error sentinel.

**Architecture:** Work entirely in the self-hosted compiler (`src/sema.bux`, `src/cli.bux`). Semantic errors are recorded via `Sema_EmitError`; error paths return a `tyUnknown` sentinel (through a new `Sema_EmitExprError` helper) so parent expressions and sibling statements keep being checked. Codegen is still skipped whenever `Sema_HasError` is true.

**Tech Stack:** Bux (self-hosted compiler source), Bash test fixtures, `make selfhost` (bootstrap `buxc` compiles `src/*.bux` into `build/selfhost/build/buxc2`).

**Spec:** `docs/superpowers/specs/2026-07-28-selfhost-sema-error-recovery-design.md`

**Repo layout facts the engineer must know:**
- Self-hosted compiler sources: `src/*.bux` (entry: `src/main.bux`; pipeline wired in `src/cli.bux`).
- `make selfhost` copies `src/*.bux` to `build/selfhost/src/`, renames `main.bux` → `Main.bux`, and builds with the bootstrap `./buxc`. Result binary: `build/selfhost/build/buxc2`.
- `buxc2 check <dir>` type-checks a package (needs `BUX_STDLIB=<repo>/lib` exported when run from a foreign directory).
- Type kind constants live in `src/types.bux` (`tyUnknown = 0`, `tyVoid = 1`, `tyBool = 2`, `tyStr = 9`, `tyInt = 14`, `tyFloat64 = 21`, `tyPointer = 22`, `tyNamed = 26`, `tyFunc = 28`).
- `Sema_CheckStmt` / `Sema_CheckExpr` are in `src/sema.bux` (statement checking starts ~line 1425, expression checking ~line 819).
- **Do not use `if` as an expression** in `src/*.bux` — the bootstrap parser rejects it (that is exactly what Task 0 fixes in `hir_lower.bux`). Ternary `cond ? a : b` is ALSO unsupported by the bootstrap parser (postfix `?` is always consumed as the try-operator); use statement form instead.

---

### Task 0: Unblock `make selfhost` (prerequisite)

`make selfhost` currently fails because `src/hir_lower.bux:2726` uses `if` as an expression, which the bootstrap parser does not support. Replace it with the supported ternary form. This task exists only so that every later task is verifiable end-to-end with `buxc2`.

**Files:**
- Modify: `src/hir_lower.bux:2726`

- [ ] **Step 1: Verify the failure first**

Run: `cd /home/ziko/z-git/bux/bux && make selfhost 2>&1 | tail -20`
Expected: FAIL — parse error `expected expression` at `src/hir_lower.bux:2726:50` pointing at the `if`.

- [ ] **Step 2: Replace the if-expression with statement form**

NOTE (corrected during execution): the bootstrap parser supports NEITHER `if`-expressions NOR ternary `cond ? a : b` — the postfix loop in `bootstrap/parser.nim:794-796` consumes any `?` as the try-operator, making the ternary branch unreachable. Use statement form instead.

In `src/hir_lower.bux`, change line 2726 from:

```bux
let operandTypeExpr: *TypeExpr = if operandExpr != null as *Expr { operandExpr.refType } else { null as *TypeExpr };
```

to:

```bux
var operandTypeExpr: *TypeExpr = null as *TypeExpr;
if operandExpr != null as *Expr { operandTypeExpr = operandExpr.refType; }
```

(`operandTypeExpr` is only read afterwards inside the same block, so `var` instead of `let` is semantically safe.)

- [ ] **Step 3: Verify selfhost now builds**

Run: `cd /home/ziko/z-git/bux/bux && make selfhost 2>&1 | tail -5`
Expected: `=== Self-hosted compiler built successfully ===` and the binary exists:

Run: `test -x build/selfhost/build/buxc2 && echo buxc2-ok`
Expected: `buxc2-ok`

- [ ] **Step 4: Commit**

```bash
git add src/hir_lower.bux
git commit -m "fix: rewrite if-expression as statements in hir_lower (unblocks make selfhost)"
```

---

### Task 1: Add `Sema_EmitExprError` sentinel helper

Introduce one explicit helper for the "record an error, mark the expression with a `?` type, return `tyUnknown`" pattern, and convert the two existing expression error sites that already return `tyUnknown` (undeclared identifier, `self` outside method) to use it. This locks in the convention the rest of the plan relies on.

**Files:**
- Modify: `src/sema.bux` (after line 94; and lines ~852, ~880)

- [ ] **Step 1: Write the failing test fixture**

Create `_test_error_recovery/` (fixture content is finalized in Task 4; for now create a minimal package):

```bash
mkdir -p _test_error_recovery/src
cat > _test_error_recovery/bux.toml <<'EOF'
[Package]
Name    = "error_recovery"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
EOF
cat > _test_error_recovery/src/Main.bux <<'EOF'
import Std::Io::{PrintLine};

func Main() -> int {
    PrintLine(undefined_variable);
    return 0;
}
EOF
```

Run: `cd /home/ziko/z-git/bux/bux/_test_error_recovery && BUX_STDLIB=/home/ziko/z-git/bux/bux/lib ../build/selfhost/build/buxc2 check src/Main.bux 2>&1; echo "exit=$?"`
Expected: exit=1 and the output contains `undeclared identifier 'undefined_variable'`. (This passes today; the fixture proves the sentinel path keeps working after the refactor.)

NOTE (corrected during execution): the self-hosted `check` command takes a FILE path, not a directory (`Cli_Check` reads the file directly), and single-file check mode does NOT resolve `import`s — so `PrintLine` would also appear as undeclared. The final fixture (Task 3) therefore avoids imports entirely.

- [ ] **Step 2: Add the helper to `src/sema.bux`**

Immediately after `Sema_EmitError` (after line 94), insert:

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

- [ ] **Step 3: Convert the undeclared-identifier site**

In `Sema_CheckExpr` (`ekIdent` branch, ~line 849-854), change:

```bux
            let sym: Symbol = Scope_Lookup(sema.scope, expr.strValue);
            if sym.kind == 0 && !String_Eq(sym.name, expr.strValue) {
                let errMsg: String = String_Concat("undeclared identifier '", expr.strValue);
                let errMsg2: String = String_Concat(errMsg, "'");
                Sema_EmitError(sema, expr.line, expr.column, errMsg2);
                return tyUnknown;
            }
```

to:

```bux
            let sym: Symbol = Scope_Lookup(sema.scope, expr.strValue);
            if sym.kind == 0 && !String_Eq(sym.name, expr.strValue) {
                let errMsg: String = String_Concat("undeclared identifier '", expr.strValue);
                let errMsg2: String = String_Concat(errMsg, "'");
                return Sema_EmitExprError(sema, expr, errMsg2);
            }
```

- [ ] **Step 4: Convert the `self` site**

In the `ekSelf` branch (~line 877-882), change:

```bux
            if sym.kind == 0 && !String_Eq(sym.name, "self") {
                Sema_EmitError(sema, expr.line, expr.column, "self outside method");
                return tyUnknown;
            }
```

to:

```bux
            if sym.kind == 0 && !String_Eq(sym.name, "self") {
                return Sema_EmitExprError(sema, expr, "self outside method");
            }
```

- [ ] **Step 5: Rebuild selfhost and re-run the fixture**

Run: `cd /home/ziko/z-git/bux/bux && make selfhost 2>&1 | tail -3`
Expected: `=== Self-hosted compiler built successfully ===`

Run: `cd /home/ziko/z-git/bux/bux/_test_error_recovery && BUX_STDLIB=/home/ziko/z-git/bux/bux/lib ../build/selfhost/build/buxc2 check src/Main.bux 2>&1; echo "exit=$?"`
Expected: exit=1 and output still contains `undeclared identifier 'undefined_variable'`.

- [ ] **Step 6: Commit**

```bash
git add src/sema.bux
git add -f _test_error_recovery/
git commit -m "feat(selfhost-sema): add Sema_EmitExprError sentinel helper"
```

NOTE: `_test_*/` is gitignored, but tracked fixtures exist (e.g. `_test_error_snippet/`), so `git add -f` is the established way to commit a new fixture.

---

### Task 2: Arithmetic errors return the sentinel (no cascading diagnostics)

Today a failed arithmetic expression emits an error but then returns `tyInt`/`tyFloat64`, which lets follow-on code treat the bad expression as a valid number and produce derived errors. Return `tyUnknown` via the helper instead.

**Files:**
- Modify: `src/sema.bux` (`ekBinary` arithmetic tail, ~lines 961-965)

- [ ] **Step 1: Extend the fixture with a cascade probe**

Replace `_test_error_recovery/src/Main.bux` with (no imports — single-file check mode does not resolve them):

```bux
func Main() -> int {
    let bad: int = "a" + 1;
    let z: int = undefined_variable;
    return 0;
}
```

Run: `cd /home/ziko/z-git/bux/bux/_test_error_recovery && BUX_STDLIB=/home/ziko/z-git/bux/bux/lib ../build/selfhost/build/buxc2 check src/Main.bux 2>&1; echo "exit=$?"`
Expected BEFORE the fix: exit=1, output contains `arithmetic requires numeric operands` and `undeclared identifier 'undefined_variable'`. (If extra derived errors about `bad` appear, this task removes them in Task 3 interplay; the key assertion is that both independent errors appear in ONE run.)

- [ ] **Step 2: Return the sentinel from the arithmetic error path**

In `Sema_CheckExpr`, `ekBinary` branch, change:

```bux
            if !Sema_IsNumeric(left) || !Sema_IsNumeric(right) {
                Sema_EmitError(sema, expr.line, expr.column, "arithmetic requires numeric operands");
            }
            if left == tyFloat64 || right == tyFloat64 { return tyFloat64; }
            return tyInt;
```

to:

```bux
            if !Sema_IsNumeric(left) || !Sema_IsNumeric(right) {
                return Sema_EmitExprError(sema, expr, "arithmetic requires numeric operands");
            }
            if left == tyFloat64 || right == tyFloat64 { return tyFloat64; }
            return tyInt;
```

Note: `Sema_IsNumeric` returns `true` for `tyUnknown` (see `src/sema.bux:181`), so an already-broken operand does not re-trigger this error. That is the intended cascade suppression.

- [ ] **Step 3: Rebuild and verify both independent errors appear in one run**

Run: `cd /home/ziko/z-git/bux/bux && make selfhost 2>&1 | tail -3`
Expected: `=== Self-hosted compiler built successfully ===`

Run: `cd /home/ziko/z-git/bux/bux/_test_error_recovery && BUX_STDLIB=/home/ziko/z-git/bux/bux/lib ../build/selfhost/build/buxc2 check src/Main.bux 2>&1 | tee /tmp/err_recovery.out; echo "exit=$?"`

Run: `grep -c "arithmetic requires numeric operands" /tmp/err_recovery.out && grep -c "undeclared identifier" /tmp/err_recovery.out`
Expected: `1` and `1` (each error reported exactly once, in the same run).

- [ ] **Step 4: Commit**

```bash
git add src/sema.bux
git add -f _test_error_recovery/
git commit -m "feat(selfhost-sema): arithmetic errors return tyUnknown sentinel"
```

---

### Task 3: Add annotation-vs-initializer assignment checking

The self-hosted sema currently never checks `let x: T = init` for type agreement (the bootstrap compiler reports `cannot assign String to int`; `buxc2` silently accepts it and lets the C compiler fail later). Add the check in `Sema_CheckStmt` (`skLet`), emitting the same message shape as the bootstrap compiler, and keep registering the variable so checking continues.

**Files:**
- Modify: `src/sema.bux` (new strict-numeric predicate after `Sema_IsBool` ~line 190; `skLet` branch ~lines 1443-1462)

- [ ] **Step 1: Extend the fixture with two assignment errors**

Replace `_test_error_recovery/src/Main.bux` with:

```bux
func Main() -> int {
    let x: int = "hello";
    let y: bool = 42;
    let z: int = undefined_variable;
    return 0;
}
```

Run: `cd /home/ziko/z-git/bux/bux/_test_error_recovery && BUX_STDLIB=/home/ziko/z-git/bux/bux/lib ../build/selfhost/build/buxc2 check src/Main.bux 2>&1; echo "exit=$?"`
Expected BEFORE the fix: exit=1, output contains `undeclared identifier 'undefined_variable'` but NO `cannot assign` lines (this is the failing assertion the task fixes).

- [ ] **Step 2: Add a strict numeric predicate**

`Sema_IsNumeric` (`src/sema.bux:181`) deliberately treats `tyNamed`/`tyTypeParam` as numeric (operator overloading). Assignment checking must not. After `Sema_IsBool` (~line 190), insert:

```bux
    func Sema_IsStrictNumeric(kind: int) -> bool {
        if kind == tyInt8 || kind == tyInt16 || kind == tyInt32 || kind == tyInt64 || kind == tyInt { return true; }
        if kind == tyUInt8 || kind == tyUInt16 || kind == tyUInt32 || kind == tyUInt64 || kind == tyUInt { return true; }
        if kind == tyFloat32 || kind == tyFloat64 { return true; }
        return false;
    }
```

- [ ] **Step 3: Add a display-name helper for diagnostics**

After `Sema_IsStrictNumeric`, insert:

```bux
    func Sema_TypeNameForDiag(te: *TypeExpr, kind: int) -> String {
        if te != null as *TypeExpr {
            if te.kind == tekPointer && te.pointerPointee != null as *TypeExpr {
                return String_Concat(te.pointerPointee.typeName, "*");
            }
            if !String_Eq(te.typeName, "") { return te.typeName; }
        }
        if kind == tyBool { return "bool"; }
        if kind == tyStr { return "String"; }
        if kind == tyInt { return "int"; }
        if kind == tyInt64 { return "int64"; }
        if kind == tyUInt { return "uint"; }
        if kind == tyFloat64 { return "float64"; }
        if kind == tyPointer { return "*void"; }
        return "?";
    }
```

- [ ] **Step 4: Emit the assignment error in `skLet`**

In `Sema_CheckStmt`, `skLet` branch, insert the check AFTER the annotation/inference block (after the `} else if stmt.child1 != null as *Expr && stmt.child1.refType != null as *TypeExpr {` block closes, i.e. right before `sym.isMutable = stmt.boolValue;` ~line 1462):

```bux
            // Assignment check: annotation vs initializer (skip when either side is unknown)
            if stmt.refStmtType != null as *TypeExpr && initType != tyUnknown {
                let annotKind: int = Sema_ResolveType(sema, stmt.refStmtType);
                if annotKind != tyUnknown {
                    var mismatch: bool = false;
                    if initType == tyNamed && annotKind == tyNamed {
                        // Both named: kinds are equal, compare type names (when available).
                        if stmt.child1 != null as *Expr && stmt.child1.refType != null as *TypeExpr {
                            if !String_Eq(stmt.child1.refType.typeName, "") &&
                            !String_Eq(stmt.child1.refType.typeName, stmt.refStmtType.typeName) {
                                mismatch = true;
                            }
                        }
                    } else if initType != annotKind {
                        let numericOk: bool = Sema_IsStrictNumeric(initType) && Sema_IsStrictNumeric(annotKind);
                        let initIsPtr: bool = initType == tyPointer || initType == tyStr;
                        let annotIsPtr: bool = annotKind == tyPointer || annotKind == tyStr;
                        let ptrOk: bool = initIsPtr && annotIsPtr;
                        if !numericOk && !ptrOk {
                            mismatch = true;
                        }
                    }
                    if mismatch {
                        let gotName: String = Sema_TypeNameForDiag(stmt.child1.refType, initType);
                        let wantName: String = Sema_TypeNameForDiag(stmt.refStmtType, annotKind);
                        let msg: String = String_Concat("cannot assign ",
                            String_Concat(gotName, String_Concat(" to ", wantName)));
                        Sema_EmitError(sema, stmt.line, stmt.column, msg);
                    }
                }
            }
```

Important: the variable is still registered with the annotation type on the next lines (`sym.typeKind = Sema_ResolveType(...)` already ran), so subsequent uses of `x` type-check as the annotated type and do not cascade.

Known limitation (documented, not fixed here): struct-literal initializers (`ekStructInit`) do not set `expr.refType`, so two different named struct types are only compared by kind; name comparison only applies when `child1.refType` is available.

- [ ] **Step 5: Rebuild and verify all three independent errors appear in one run**

Run: `cd /home/ziko/z-git/bux/bux && make selfhost 2>&1 | tail -3`
Expected: `=== Self-hosted compiler built successfully ===`

Run: `cd /home/ziko/z-git/bux/bux/_test_error_recovery && BUX_STDLIB=/home/ziko/z-git/bux/bux/lib ../build/selfhost/build/buxc2 check src/Main.bux 2>&1 | tee /tmp/err_recovery.out; echo "exit=$?"`

Run: `grep -c "cannot assign String to int" /tmp/err_recovery.out; grep -c "cannot assign int to bool" /tmp/err_recovery.out; grep -c "undeclared identifier 'undefined_variable'" /tmp/err_recovery.out`
Expected: `1`, `1`, `1` — three independent errors in a single run.

Also verify valid code still passes (no false positives). Use an import-free file (check mode does not resolve imports):

```bash
mkdir -p /tmp/hello_ok/src
cat > /tmp/hello_ok/src/Main.bux <<'EOF'
func Main() -> int {
    let x: int = 5;
    let y: bool = true;
    let s: String = "ok";
    return 0;
}
EOF
BUX_STDLIB=/home/ziko/z-git/bux/bux/lib /home/ziko/z-git/bux/bux/build/selfhost/build/buxc2 check /tmp/hello_ok/src/Main.bux 2>&1; echo "exit=$?"
```

Expected: `exit=0` (no errors for valid code).

- [ ] **Step 6: Commit**

```bash
git add src/sema.bux
git add -f _test_error_recovery/
git commit -m "feat(selfhost-sema): check annotation vs initializer type in let/var"
```

---

### Task 4: Regression runner for multi-error recovery

Lock the behavior in with a runnable script so regressions are caught by one command.

**Files:**
- Create: `_test_error_recovery/run.sh`
- Modify: `Makefile` (add `test-error-recovery` target)

- [ ] **Step 1: Write the runner script**

Create `_test_error_recovery/run.sh`:

```bash
#!/usr/bin/env bash
# Regression: buxc2 must report ALL independent semantic errors in one run.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BUXC2="$ROOT/build/selfhost/build/buxc2"
export BUX_STDLIB="$ROOT/lib"

if [[ ! -x "$BUXC2" ]]; then
  echo "=== building selfhost (buxc2) ==="
  (cd "$ROOT" && make selfhost)
fi
if [[ ! -x "$BUXC2" ]]; then
  echo "error: buxc2 not found at $BUXC2" >&2
  exit 1
fi

out="$(cd "$HERE" && "$BUXC2" check src/Main.bux 2>&1 || true)"
echo "$out"

grep -q "cannot assign String to int" <<<"$out"
grep -q "cannot assign int to bool" <<<"$out"
grep -q "undeclared identifier 'undefined_variable'" <<<"$out"

echo "PASS: all independent semantic errors reported in one run"
```

Run: `chmod +x _test_error_recovery/run.sh`

- [ ] **Step 2: Run it — must pass**

Run: `cd /home/ziko/z-git/bux/bux && ./_test_error_recovery/run.sh`
Expected: ends with `PASS: all independent semantic errors reported in one run`

- [ ] **Step 3: Add the Makefile target**

In `Makefile`, add after the `test-errors` target block (after line 141):

```make
test-error-recovery: ensure-buxc selfhost
	@echo "=== Selfhost multi-error recovery test ==="
	@chmod +x _test_error_recovery/run.sh
	@_test_error_recovery/run.sh
```

- [ ] **Step 4: Run the target**

Run: `cd /home/ziko/z-git/bux/bux && make test-error-recovery`
Expected: `PASS: all independent semantic errors reported in one run`

- [ ] **Step 5: Negative check — valid code still compiles through buxc2**

Run: `BUX_STDLIB=/home/ziko/z-git/bux/bux/lib /home/ziko/z-git/bux/bux/build/selfhost/build/buxc2 check /tmp/hello_ok/src/Main.bux && echo "exit=$?"`
Expected: `exit=0`

- [ ] **Step 6: Commit**

```bash
git add Makefile
git add -f _test_error_recovery/
git commit -m "test: selfhost multi-error recovery regression fixture"
```

---

## Self-review notes

- Spec coverage: sentinel helper (Task 1), cascade suppression (Task 2), statement-level continuation with new assignment diagnostics (Task 3), CLI keeps skipping codegen on `hasError` (existing behavior, asserted by fixtures exiting 1 before codegen), regression test (Task 4). The `Sema_CheckStmt` early-return audit found no statement-level early returns that skip sibling statements, so no Task is needed for that; the `Sema_CheckReturnLifetime` internal `return`s only exit that helper and are correct.
- Type consistency: `Sema_EmitExprError(sema: *Sema, expr: *Expr, msg: String) -> int`, `Sema_IsStrictNumeric(kind: int) -> bool`, `Sema_TypeNameForDiag(te: *TypeExpr, kind: int) -> String` are used with the same signatures in every task.
- Known blockers/limitations: struct-literal `refType` is not set, so named-vs-named assignment checking is best-effort; bootstrap compiler behavior is unchanged.
