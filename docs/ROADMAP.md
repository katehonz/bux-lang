# Bux Language Roadmap — New Constructs

> **Updated:** 2026-06-08 | **Status:** In Progress

This document tracks planned language constructs beyond Phase 8 strategy.

---

## P0 — Critical (Unlocks Major Use Cases)

### 1. `defer` Statement
**Why:** No GC + no destructors = manual `Free` everywhere. `defer` is the pragmatic fix.

**Syntax:**
```bux
func ReadFile(path: String) -> String {
    let fd: int = Open(path);
    defer Close(fd);           // runs on any exit from scope
    defer PrintLine("done");   // LIFO order
    let data: String = ReadAll(fd);
    return data;               // both defers run before return
}
```

**Implementation Steps:**
1. Add `tkDefer` token (or reuse `tkDefer` if exists)
2. Add `DeferStmt` AST node (`child: *Stmt`)
3. Parser: parse `defer <expr>;` or `defer { <block> }`
4. C backend: collect all `defer`s per block, emit cleanup code before every exit point (return, break, continue)
5. Handle LIFO ordering for multiple defers in same scope

**Complexity:** Low — localized to parser + C backend. No type system changes.

---

### 2. Closures / Anonymous Functions
**Why:** Callbacks, iterators, functional APIs. Currently only named functions exist.

**Syntax:**
```bux
let add: func(int, int) -> int = |a, b| { return a + b; };
let nums: Array<int> = Array_New<int>();
Array_Filter(nums, |x| { return x > 10; });
```

**Implementation Steps:**
1. New AST node: `ClosureExpr` with `params`, `body`, `captures`
2. Parser: parse `|param1, param2| -> Type { body }`
3. Type system: closure type as `func(Args) -> Ret` + implicit capture struct
4. C backend: generate struct with captured vars + function pointer
5. Lifetime: ensure captures outlive closure usage

**Complexity:** High — touches parser, sema, type system, C backend.

---

### 3. `for x in collection` Iterator Loops
**Why:** Currently only `for i in 0..10` works. No way to iterate arrays/channels/maps.

**Syntax:**
```bux
for item in arr {
    PrintLine(item);
}
for msg in channel {
    Process(msg);
}
```

**Implementation Steps:**
1. Parser: extend `for` to accept `for <ident> in <expr> { ... }`
2. Desugar to while loop using `Iter_HasNext` / `Iter_Next` or trait-based iterator
3. C backend: generate standard while loop with iterator state

**Complexity:** Medium — needs either trait system enhancement or hardcoded desugaring.

---

## P1 — High Impact

### 4. Operator Overloading
**Why:** Can't write `arr[i]`, `a + b`, `s1 == s2` for user types.

**Syntax:**
```bux
extend Array<T> {
    func operator[](self: Array<T>, idx: uint) -> T { ... }
    func operator+(self: Array<T>, other: Array<T>) -> Array<T> { ... }
}
```

**Implementation Steps:**
1. Parser: allow `operator[]`, `operator+`, etc. as function names
2. Sema: resolve operator calls to user-defined functions when available
3. C backend: emit regular function call

**Complexity:** Medium — mainly sema + parser changes.

---

### 5. Destructors / `Drop` Trait
**Why:** `own T` exists but nothing cleans up automatically. Complements `defer`.

**Syntax:**
```bux
extend Array<T> {
    func Drop(self: own Array<T>) {
        Array_Free(self);
    }
}
```

**Implementation Steps:**
1. Define `Drop` interface in stdlib
2. C backend: emit `Drop(value)` before variable goes out of scope
3. Respect move semantics — don't drop moved values

**Complexity:** High — needs ownership tracking + move semantics.

---

### 6. String Interpolation
**Why:** `Fmt_Fmt1("hello {0}", name)` is verbose.

**Syntax:**
```bux
let name: String = "Bux";
let msg: String = "Hello, {name}!";
let num: int = 42;
let msg2: String = "Count: {num}";
```

**Implementation Steps:**
1. Lexer: detect `{` inside string literals, parse interpolation expressions
2. Parser: create string concatenation AST node
3. Desugar to `String_Concat` calls or `Fmt_FmtN`

**Complexity:** Low — lexer/parser changes only.

---

## P2 — Nice to Have

### 7. Native `switch` / `case`
**Why:** `match` is powerful but overkill for simple integer dispatch. Jump tables are faster.

**Syntax:**
```bux
switch statusCode {
    case 200: PrintLine("OK");
    case 404: PrintLine("Not Found");
    case 500: PrintLine("Server Error");
    default:  PrintLine("Unknown");
}
```

**Implementation Steps:**
1. Parser: `switch expr { case literal: stmts ... default: stmts }`
2. C backend: emit `switch(expr) { case N: ... }`

**Complexity:** Low — straightforward C mapping.

---

### 8. Named / Default Parameters
**Why:** API ergonomics.

**Syntax:**
```bux
func HttpResponse(code: int = 200, contentType: String = "text/plain", body: String = "") -> Response { ... }
let r: Response = HttpResponse(body: "hello");  // code=200, contentType=default
```

**Implementation Steps:**
1. Parser: allow `param: Type = defaultExpr`
2. Sema: fill missing args at call sites
3. C backend: emit args in correct order with defaults

**Complexity:** Medium — sema changes for call resolution.

---

## Recommended Order

1. **`defer`** — Low complexity, huge impact, unlocks safe resource management immediately.
2. **String interpolation** — Low complexity, big ergonomics win.
3. **`switch`/`case`** — Low complexity, complements `match` for numeric dispatch.
4. **Named/default parameters** — Medium complexity, improves stdlib APIs.
5. **Operator overloading** — Medium complexity, transforms stdlib ergonomics.
6. **Closures** — High complexity, unlocks iterators and functional style.
7. **`for x in collection`** — Depends on closures or trait system.
8. **Destructors / Drop** — High complexity, needs ownership + move semantics.
