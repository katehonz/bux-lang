# Bux Language Roadmap — New Constructs

> **Updated:** 2026-06-09 | **Status:** In Progress

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

**Status:** ✅ Done — selfhost-loop produces identical C output on every iteration.

---

### 6. Closures / Anonymous Functions
**Status:** ✅ Implemented in both bootstrap and selfhost. Capture-less and with captures.

**Syntax:**
```bux
// Capture-less closure
let add: func(int, int) -> int = |a, b| { return a + b; };

// Closure with captures
let base: int = 10;
let adder: func(int) -> int = |a: int| -> int { return a + base; };
let result: int = adder(5);  // 15

// Pass closure to higher-order function
Array_Filter(nums, |x| { return x > 10; });
```

**Implementation:**
- Capture-less closures: generate global thunk function, return `&thunk` as function pointer.
- Closures with captures:
  1. Sema: `Scope_LookupUpTo` identifies captured variables from outer scope.
  2. HIR Lower: generate `__closure_env_N` struct + global instance `__closure_env_instance_N`.
  3. At closure creation site: emit capture assignments (`env_instance.x = x;`).
  4. In thunk body: rewrite captured identifiers to `env_instance.x` via `hFieldAccess`.
  5. C backend: emit env struct definition + global instance before thunk function.

**Limitations:** One global instance per closure AST node (no multiple instances). No loop/return support in closures yet.

**Complexity:** High — touches parser, sema, type system, HIR/LIR backend.

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
1. ✅ Parser: extend `for` to accept `for <ident> in <expr> { ... }`
2. ✅ Range-based: `for i in lo..hi` and `for i in lo..=hi` — desugared to `while` loop with counter
3. ✅ Collection-based: `for x in arr` — desugared to `Array_Iter_T` + `Iter_HasNext_T` + `Iter_Next_T`

**Complexity:** Medium — done.

---

## P1 — High Impact

### 8. Destructors / `Drop` Trait
**Status:** ✅ Done in selfhost.

**Why:** `own T` exists but nothing cleans up automatically. Complements `defer`.

**Syntax:**
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
```

**Implementation Steps:**
1. ✅ Define `Drop` interface in stdlib (`lib/Drop.bux`)
2. ✅ HIR lowering: emit `TypeName_Drop(&value)` before variable goes out of scope (selfhost)
3. ✅ Respect move semantics — moved values are skipped via `CBE_IsMoved`

**Notes:**
- Bootstrap compiler still requires explicit `defer` for user-defined cleanup.
- See `docs/superpowers/specs/2026-06-14-drop-interface-auto-drop-design.md`.

**Complexity:** Medium — reused existing `@[Drop]` auto-drop path and interface method table.

---

### 9. Trait Bounds (`T: Comparable`)
**Why:** Generic functions need constraints on type parameters.

**Syntax:**
```bux
func Sort<T: Comparable>(arr: &mut Array<T>) { ... }
```

**Status:** ✅ Implemented — `@[Comparable]` attribute + `Sema_CheckTraitBounds` in selfhost.

---

### 10. CTFE (Compile-Time Function Execution)
**Why:** Precomputed tables for embedded / kernel dev.

**Syntax:**
```bux
const A: int = 10;
const B: int = 20;
const C: int = A + B;  // Evaluated at compile time
```

**Status:** ✅ Implemented — multi-pass expression evaluator in HIR lowering.

**Supported:** literals, binary/unary/ternary ops, casts, cross-const references.

---

## P2 — Nice to Have

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
8. ✅ **Closures (capture-less)** — Done
9. ✅ **Closures with captures** — Done
10. ✅ **`for x in collection`** — Done
11. ✅ **Trait bounds (`T: Comparable`)** — Done
12. ✅ **CTFE** — Done
13. ✅ **Selfhost bootstrap loop** — Done
14. ✅ **Destructors / Drop** — Done in selfhost.
15. ✅ **Bounds checking on slices** — `Slice<T>` with bounds-checked indexing works in selfhost via `lib/Slice.bux`.
16. **Concurrency** — Green threads + channels.
