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

### 4. String Interpolation
**Status:** ✅ Implemented in bootstrap (selfhost reserves AST node).

**Syntax:**
```bux
let name: String = "Bux";
let msg: String = f"Hello, {name}!";
let num: int = 42;
let msg2: String = f"Count: {num}";
```

**Notes:**
- `f"..."` prefix enables interpolation.
- Escaped braces: `\{` and `\}`.
- Auto-converts `int`, `uint`, `float`, `bool`, and `String` inside braces.

---

### 5. Named / Default Parameters
**Status:** ✅ Implemented in both bootstrap and selfhost.

**Syntax:**
```bux
func HttpResponse(code: int = 200, body: String = "") -> Response { ... }
let r: Response = HttpResponse(body: "hello");  // code=200
let s = HttpResponse(404, body: "err");         // positional + named mixed
```

**Notes:**
- Bootstrap parser already parsed defaults; added named-arg parsing and sema injection.
- Selfhost parser parses `= defaultExpr` in params and `name: value` at call sites.
- Sema injects default expressions and reorders named args into param order.

---

### 6. CLI Commands (`bux new`, `bux init`, `bux test`, `bux fmt`)
**Status:** ✅ Implemented in selfhost.

| Command | Description |
|---------|-------------|
| `bux new <name>` | Create a new project directory with `bux.toml` and `src/Main.bux` |
| `bux init` | Initialize a Bux project in the current directory |
| `bux test [dir]` | Build and run the project binary, reporting pass/fail |
| `bux fmt <file|dir>` | Format `.bux` files (4-space indentation, preserves comments) |

---

### 7. Basic Borrow Checker (`@[Checked]`)
**Status:** ✅ Implemented in selfhost.

**Features:**
- `@[Checked]` attribute enables per-function borrow checking.
- `&T` (shared reference) and `&mut T` (mutable reference) type syntax.
- Rejects write-through raw pointer (`*T`) in checked functions.
- Detects double mutable borrow (`Swap(&mut x, &mut x)`).
- Tracks use-after-move for `own T` values.

---

## P0 — Critical (Unlocks Major Use Cases)

### 8. Full Selfhost Bootstrap Loop
**Why:** The selfhost compiler must compile itself deterministically.

**Status:** 🔄 In progress — borrow checker works, but some features still missing in selfhost vs bootstrap.

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
4. ✅ **String interpolation** — Done (bootstrap)
5. ✅ **Named/default parameters** — Done
6. ✅ **Basic borrow checker (`@[Checked]`)** — Done (selfhost)
7. ✅ **`bux fmt`, `bux test`, `bux new`, `bux init`** — Done (selfhost)
8. ✅ **Closures (capture-less)** — Done. Enables callbacks and higher-order functions.
9. **Closures with captures** — Needs capture analysis + environment struct. **← NEXT**
10. **`for x in collection`** — Depends on closures with captures or trait system.
11. **Destructors / Drop** — High complexity, needs ownership + move semantics.
