# Bux Language Roadmap — New Constructs

> **Updated:** 2026-06-08 | **Status:** In Progress

This document tracks planned language constructs beyond Phase 8 strategy.

---

## ✅ Done

### 1. `defer` Statement
**Status:** ✅ Implemented in both bootstrap and selfhost.

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

---

### 2. Native `switch` / `case`
**Status:** ✅ Implemented in both bootstrap and selfhost. Desugars to if-else chain.

**Syntax:**
```bux
switch statusCode {
    case 200: PrintLine("OK");
    case 404: PrintLine("Not Found");
    case 500: PrintLine("Server Error");
    default:  PrintLine("Unknown");
}
```

---

### 3. Operator Overloading
**Status:** ✅ Implemented in bootstrap. Selfhost has no method-table yet (not needed for selfhost-loop parity).

**Supported operators:**
```bux
func Vec2_operator_add(self: *Vec2, other: Vec2) -> Vec2 { ... }
func Vec2_operator_sub(self: *Vec2, other: Vec2) -> Vec2 { ... }
func Vec2_operator_eq(self: *Vec2, other: Vec2) -> bool { ... }
func Vec2_operator_lt(self: *Vec2, other: Vec2) -> bool { ... }
func MyArray_operator_index_get(self: *MyArray, idx: int) -> int { ... }
func MyArray_operator_index_set(self: *MyArray, idx: int, value: int) { ... }
```

**Notes:**
- Works via method-table lookup in sema + hir_lower.
- Generic method instantiation supported.
- Short-circuit operators (`&&`, `||`) remain builtin.

---

## P0 — Critical (Unlocks Major Use Cases)

### 4. String Interpolation
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

### 5. Named / Default Parameters
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

### 6. Closures / Anonymous Functions
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

### 7. `for x in collection` Iterator Loops
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

### 8. Destructors / `Drop` Trait
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

## P2 — Nice to Have

### 9. Trait System Enhancement
**Why:** Currently have `interface` + `extend` (basic). Need trait bounds, associated types.

**Syntax:**
```bux
func Sort<T: Comparable>(arr: &mut Array<T>) { ... }
```

---

### 10. CTFE (Compile-Time Function Execution)
**Why:** Precomputed tables for embedded / kernel dev.

**Syntax:**
```bux
const func Fib(n: int) -> int { ... }
const TABLE_SIZE = Fib(20);
```

---

### 11. Concurrency
**Why:** Go-style goroutines + channels, but without GC.

**Syntax:**
```bux
let (tx, rx) = Channel::New<int>();
Task::Spawn(Worker, rx);
```

---

## Recommended Order

1. ✅ **`defer`** — Done
2. ✅ **`switch`/`case`** — Done
3. ✅ **Operator overloading** — Done (bootstrap)
4. **String interpolation** — Low complexity, big ergonomics win. **← NEXT**
5. **Named/default parameters** — Medium complexity, improves stdlib APIs.
6. **Closures** — High complexity, unlocks iterators and functional style.
7. **`for x in collection`** — Depends on closures or trait system.
8. **Destructors / Drop** — High complexity, needs ownership + move semantics.
