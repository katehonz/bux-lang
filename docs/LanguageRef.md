# Bux Language Reference

> **Status:** Normative for **v1.0.0** (language freeze).  
> Describes Bux as implemented by the **bootstrap** (`buxc`, Nim) and **self-hosted** (`buxc2`) compilers.  
> Behaviour here is the contract for semver after 1.0 — see [`SEMVER.md`](SEMVER.md) and [`RELEASE_v1.0.0.md`](RELEASE_v1.0.0.md).

This document is the primary language specification. Compiler bugs that contradict
it are fixed without a MAJOR version bump; intentional breaking changes require MAJOR.

---

## Table of Contents

1. [Lexical Structure](#lexical-structure)
2. [Types](#types)
3. [Variables](#variables)
4. [Functions](#functions)
5. [Control Flow](#control-flow)
6. [Structs](#structs)
7. [Enums](#enums)
8. [Pattern Matching](#pattern-matching)
9. [Methods and Interfaces](#methods-and-interfaces)
10. [Generics](#generics)
11. [Gradual Ownership](#gradual-ownership-phase-82--implemented) — Checked / Release / [Drop & RAII](#drop-and-raii)
12. [Error Handling](#error-handling)
13. [Modules and Imports](#modules-and-imports)
14. [Async/Await](#asyncawait)
15. [Operator Overloading](#operator-overloading)
16. [Operators](#operators)
17. [Macros](#macros)

---

## Lexical Structure

### Comments
```bux
// Single-line comment

/*
   Multi-line comment
   /* Nested comments are supported */
*/
```

### Identifiers
Identifiers start with a letter or underscore, followed by letters, digits, or underscores.

### Keywords
```
func, let, var, const, type, struct, enum, union, interface, extend
module, import, pub, extern, if, else, while, do, loop, for, in
break, continue, return, match, as, is, null, self, super, sizeof
async, await, spawn, defer, switch, case, default, checked
```

### String Literals
```bux
"Hello"           // String (UTF-8) — escape sequences: \n \t \r \\ \"
c8"Hello"         // *char8 (C string)
c16"Hello"        // *char16
c32"Hello"        // *char32
`raw literal`     // Raw multi-line string — no escape processing
`line 1
line 2
line 3`           // Newlines preserved as-is
f"Hello, {name}"  // Interpolated string — expressions inside {}
```

**Backtick raw strings** (`` `...` ``) treat all characters literally:
- `\n` is two characters, not a newline
- Actual newlines in source are preserved in the string
- No way to escape the backtick character itself (use regular strings if needed)

**Interpolated strings** (`f"..."`):
- Expressions inside `{}` are evaluated and converted to `String`
- Supported types: `int`, `uint`, `float`, `bool`, `String`
- Escaped braces: `\{` and `\}`

### Number Literals
```bux
42        // int
3.14      // float64
0x2A      // hex
0o52      // octal
0b101010  // binary
32i8      // int8 literal
1000u64   // uint64 literal
```

---

## Types

### Primitive Types

| Type | Description |
|------|-------------|
| `int8`, `int16`, `int32`, `int64`, `int` | Signed integers |
| `uint8`, `uint16`, `uint32`, `uint64`, `uint` | Unsigned integers |
| `float32`, `float64` | Floating-point |
| `bool`, `bool8`, `bool16`, `bool32` | Booleans |
| `char8`, `char16`, `char32` | Characters |
| `String` | C-compatible string (`const char*`) |

### Composite Types

```bux
*T              // Pointer to T
&T              // Shared reference (read-only in checked functions)
&mut T          // Mutable reference (exclusive borrow)
own T           // Owned value (move semantics)
T[]             // Slice (unsized)
T[N]            // Fixed-size array
(T1, T2, T3)    // Tuple — access fields with .0, .1, .2
func(T1) -> T2  // Function pointer type
```

### Tuples
```bux
func Pair(a: int, b: int) -> (int, int) {
    return (a, b);
}

func Main() -> int {
    let t: (int, int) = Pair(10, 20);
    PrintInt(t.0);  // 10
    PrintInt(t.1);  // 20
    return 0;
}
```

### Function pointers and closures
```bux
func Apply(f: func(int) -> int, x: int) -> int {
    return f(x);
}

func Double(n: int) -> int { return n * 2; }

func MakeAdder(base: int) -> func(int) -> int {
    // Each call allocates its own capture environment
    return |a: int| -> int { return a + base; };
}

func Main() -> int {
    let g: func(int) -> int = Double;   // named func → fat pointer
    let a10 = MakeAdder(10);
    let a20 = MakeAdder(20);
    // a10 and a20 are independent instances
    return Apply(g, 21) + a10(1) + a20(1);  // 42 + 11 + 21
}
```

`func(T) -> R` values are **fat pointers** `{ code, env }`:
- capturing closures store captures in a heap env
- capture-less closures and named functions use `env = null`

### Structs
```bux
struct Point {
    x: int;
    y: int;
}
```

### Enums
```bux
enum Color {
    Red,
    Green,
    Blue
}

// Algebraic enum (tagged union)
enum Result {
    Ok(int),
    Err(String)
}
```

### Unions
```bux
union Bits {
    asByte: uint8;
    asInt: int32;
}
```

---

## Variables

```bux
let x: int = 42;       // Immutable
var y: int = 10;       // Mutable
y = 20;                // OK

const MAX: int = 100;  // Compile-time constant
```

---

## Functions

```bux
func Add(a: int, b: int) -> int {
    return a + b;
}

// Extern C function
extern func printf(fmt: *char8, ...);

// Generic function
func Min<T>(a: T, b: T) -> T {
    if a < b {
        return a;
    }
    return b;
}

// Named and default parameters
func HttpResponse(code: int = 200, body: String = "") -> Response { ... }
let r: Response = HttpResponse(body: "hello");      // code defaults to 200
let s: Response = HttpResponse(404, body: "err");   // positional + named mixed

// Operator overloading (bootstrap only)
func Vec2_operator_add(self: *Vec2, other: Vec2) -> Vec2 { ... }
func Vec2_operator_sub(self: *Vec2, other: Vec2) -> Vec2 { ... }
func Vec2_operator_eq(self: *Vec2, other: Vec2) -> bool { ... }
func Vec2_operator_lt(self: *Vec2, other: Vec2) -> bool { ... }
func MyArray_operator_index_get(self: *MyArray, idx: int) -> int { ... }
func MyArray_operator_index_set(self: *MyArray, idx: int, value: int) { ... }

// Closures (capture-less for now)
let add: func(int, int) -> int = |a: int, b: int| -> int { return a + b; };
let sum: int = add(3, 4);  // 7

// Closure passed to higher-order function
func Apply(x: int, op: func(int) -> int) -> int { return op(x); }
let doubled: int = Apply(5, |x: int| -> int { return x * 2; });  // 10
```

---

## Control Flow

### If / Else
```bux
if x > 0 {
    PrintLine("positive");
} else if x < 0 {
    PrintLine("negative");
} else {
    PrintLine("zero");
}
```

### Loops
```bux
while i < 10 {
    i = i + 1;
}

do {
    i = i + 1;
} while i < 10;

loop {
    // Infinite loop
    break;
}

for i in 0..10 {
    // Range 0 to 9 (exclusive)
}

for i in 0..=10 {
    // Range 0 to 10 (inclusive)
}
```

### Break / Continue with Labels
```bux
outer: loop {
    loop {
        break outer;
    }
}
```

### `defer`
Runs an expression when the current scope exits (LIFO order).

```bux
func ReadFile(path: String) -> String {
    let fd: int = Open(path);
    defer Close(fd);
    defer PrintLine("done");
    let data: String = ReadAll(fd);
    return data;   // both defers run before return
}
```

### `switch` / `case`
Desugars to an if-else chain. Supports a `default` case.

```bux
switch statusCode {
    case 200: PrintLine("OK");
    case 404: PrintLine("Not Found");
    case 500: PrintLine("Server Error");
    default:  PrintLine("Unknown");
}
```

---

## Structs

```bux
struct Rectangle {
    width: int;
    height: int;
}

func Main() -> int {
    let rect: Rectangle = Rectangle { width: 10, height: 5 };
    PrintInt(rect.width);
    return 0;
}
```

---

## Enums

### Simple Enums
```bux
enum Color { Red, Green, Blue }

let c: Color = Color::Red;
if c == Color::Red {
    PrintLine("red");
}
```

### Algebraic Enums
```bux
enum Result {
    Ok(int),
    Err(String)
}

enum Pair {
    Two(int, int),   // multi-field → nested payload
    One(int),        // single-field → flat data.One_0
    None
}

func Main() -> int {
    let r: Result = Result { tag: Result_Ok };
    r.data.Ok_0 = 42;

    // Multi-field construction: data.Variant.Variant_i
    var p: Pair = Pair { tag: Pair_Two };
    p.data.Two.Two_0 = 3;
    p.data.Two.Two_1 = 4;

    if r.tag == Result_Ok {
        PrintInt(r.data.Ok_0);
    }
    return 0;
}
```

Layout notes:
- Single positional field: flat union member `data.Variant_0`
- Multi-field: nested payload `data.Variant.Variant_0` / `data.Variant.Variant_1` (C type `Enum_Variant_Payload`)

---

## Pattern Matching

```bux
// Payload bindings: names in Variant(args) are bound in the arm body
func GetValue(opt: Option) -> int {
    match opt {
        Option::Some(value) => value,
        Option::None => 0
    }
}

match n {
    0 => 100,
    1..5 => 200,
    6..=10 => 300,
    _ => -1
}
```

Supported patterns:
- Wildcard: `_`
- Literal: `42`, `"hello"`, `true`
- Identifier catch-all: `name` (binds whole subject)
- Range: `1..9`, `1..=9`
- Enum tags + **payload bindings**: `Option::Some(value)`, `Pair::Two(a, b)`
- **Nested**: `Box::Val((a, b))`, `Shape::Dot(Point { x, y })`
- **Tuple patterns**: `(a, b)` → binds `subject._0`, `subject._1`
- **Struct patterns**: `Point { x: px, y: py }` or shorthand `Point { x, y }`
- Guard patterns: parsed; full lowering still evolving

```bux
match pair {
    (a, b) => a + b,
    _ => 0
}
match p {
    Point { x, y } => x * 10 + y,
    _ => -1
}
match bx {
    Box::Val((a, c)) => a + c,
    Box::Empty => 0
}
match sh {
    Shape::Dot(Point { x, y }) => x * 10 + y,
    Shape::Empty => -1
}

// Multi-statement arm bodies (block expression; last expr is the value)
match n {
    1 => {
        let a: int = 10;
        a + 1
    },
    _ => 0
}

// Block as expression
let r: int = {
    let x: int = 5;
    x + 6
};
```

---

## Methods and Interfaces

```bux
struct Rectangle {
    width: int;
    height: int;
}

interface Drawable {
    func Draw(self: Rectangle);
}

extend Rectangle for Drawable {
    func Draw(self: Rectangle) {
        PrintLine("Drawing rectangle");
    }
}

// Or extend with standalone methods
extend Rectangle {
    func Area(self: Rectangle) -> int {
        return self.width * self.height;
    }
}
```

---

## Generics

### Generic Functions

Generic functions are monomorphized at compile time. Type parameters can be specified explicitly or inferred from arguments:

```bux
func Max<T>(a: T, b: T) -> T {
    if a > b { return a; }
    return b;
}

func Main() -> int {
    // Explicit type args
    let m1: int = Max<int>(10, 20);

    // Type inference — T inferred as int from arguments
    let m2: int = Max(10, 20);
    return 0;
}
```

### Generic Structs

```bux
struct Box<T> {
    value: T,
}

// Use extend Type<T> for methods on generic structs
extend Box<T> {
    func Get(self: *Box<T>) -> T {
        return self.value;
    }

    func Set(self: *Box<T>, value: T) {
        self.value = value;
    }
}

func Main() -> int {
    let b: Box<int> = Box<int> { value: 42 };
    PrintInt(b.Get());  // 42
    b.Set(100);
    PrintInt(b.Get());  // 100
    return 0;
}
```

> **Note:** `extend Type<T>` syntax requires type parameters on the impl block. The compiler propagates them to each method automatically.

---

## Gradual Ownership (Phase 8.2) ✅ Implemented

Bux has **gradual ownership** — opt-in borrow checking. Default is permissive
(C-like). Turn safety on where it matters; turn it off on hot paths with zero cost.

### Three tiers

| Mode | Attribute | Checks | Cost |
|------|-----------|--------|------|
| **Default** | (none) | None | Zero — raw `*T`, free aliasing |
| **Checked** | `@[Checked]` | Moves, exclusive `&mut`, shared/`&mut` conflicts, dangling returns, elision | Compile-time only |
| **Release** | `@[Release]` | **Forced off** (even if also `@[Checked]`) | Zero — same codegen as default |

**Story:** write most code unchecked for speed of iteration; mark critical APIs
`@[Checked]`; mark micro-hotspots `@[Release]` (or both) when you need C-level
performance without false positives.

```bux
// Tier 1 — default: C-like, no borrow checker
func QuickSort(arr: *int, len: int) {
    // free to alias, no move tracking
}

// Tier 2 — opt-in safety
@[Checked]
func Scale(val: &mut int) {
    *val = *val * 2;
}

// Tier 3 — zero-cost escape (e.g. hot loop helper)
@[Release]
func HotInc(p: *int) {
    *p = *p + 1;   // no checks; same as default, documents intent
}

// Release wins over Checked when both are present
@[Checked]
@[Release]
func HotButDocumented(p: &mut int) {
    *p = *p + 1;   // no borrow checks
}
```

### Reference types

| Type | Syntax | Description |
|------|--------|-------------|
| Raw pointer | `*T` | C-style pointer, no checks |
| Shared ref | `&T` | Borrowed reference (read-only in checked functions) |
| Mutable ref | `&mut T` | Exclusive mutable borrow (allows mutation) |
| Owned | `own T` | Ownership type — values can be moved |

### Move Semantics

`own T` values can be **moved**. After a move, the original variable is uninitialized and cannot be used until reassigned.

```bux
@[Checked]
func Process(data: own String) {
    PrintLine(data);
    // data is consumed here
}

@[Checked]
func Main() {
    let msg: own String = "hello";
    Process(msg);          // move: msg is now uninitialized
    // PrintLine(msg);     // ERROR: use after move
    msg = "reassigned";    // OK: reinitialization
    PrintLine(msg);
}
```

Moves happen in three contexts:
- **Function call argument**: `Process(msg)` moves `msg` into the parameter
- **Assignment**: `b = a` moves `a` into `b`
- **Return**: `return x` moves `x` out of the function

### Rules in `@[Checked]` functions (not `@[Release]`)

- `&T` cannot be used to mutate data (compile-time error)
- `&mut T` allows mutation
- `*T` pointers are unrestricted (escape hatch)
- `&mut T` coerces to `&T` and `*T`
- **Double mutable borrow**: two live `&mut` of the same var (call args or let-bound)
  ```bux
  Swap(&mut x, &mut x);  // ERROR
  let a: &mut int = &mut x;
  let b: &mut int = &mut x;  // ERROR: exclusive mut already live
  ```
- **Use while mutably borrowed**: assign/use of `x` while a let-bound `&mut x` is live
- **Shared while mut**: cannot form `&x` while `&mut x` is live
- **Use after move**: using a moved `own T` until reassigned
- **No dangling returns**: cannot return a reference to a local
  ```bux
  @[Checked]
  func Bad(p: &int) -> &int {
      var x: int = 1;
      return &x;   // ERROR
  }
  ```

### `@[Release]` (C.4 zero-cost path)

Use when a function must stay check-free:

1. **Documented hot path** — same IR as unchecked, but the attribute states intent.
2. **Override Checked** — `@[Checked] @[Release]` on a method that would otherwise inherit team-wide Checked defaults.

There is **no runtime cost**: the attribute only disables the checker for that function body. Prefer `@[Release]` on the smallest possible surface; keep call boundaries `@[Checked]` when you still want API-level safety.

```bux
@[Checked]
func SafeApi(buf: &mut int) {
    // checked here
    HotPath(buf);
}

@[Release]
func HotPath(p: &mut int) {
    // no move / borrow tracking — write like C
    *p = *p + 1;
}
```

### Lifetime elision (C.1)

In `@[Checked]` functions (and not `@[Release]`), most reference signatures need
**no** lifetime annotations. Elision applies the usual single-input rules:

1. Each elided input `&T` / `&mut T` parameter gets a distinct lifetime.
2. If there is **exactly one** input lifetime, it is assigned to all elided outputs.
3. If the first parameter is named `self` / `Self`, that input lifetime is preferred for outputs.
4. Multiple input references + elided return → **error** (write an explicit lifetime).

```bux
// Elided — one input ref, return shares its lifetime
@[Checked]
func Identity(p: &int) -> &int {
    return p;   // OK
}

// Explicit — required when several inputs could be returned
@[Checked]
func Pick<'a>(a: &'a int, b: &'a int) -> &'a int {
    return a;
}

// Syntax: &'a T  and  &mut / &'a mut T  (lifetime before `mut`)
// Type parameters: func F<'a, T>(...)
```

Default and `@[Release]` functions ignore lifetime rules (C-like). Explicit `'a`
is optional documentation when a single input would already elide correctly.

### Drop and RAII

Bux uses **static destructors** (no GC): when a value goes out of scope, the
compiler may emit `TypeName_Drop(&local)`. That is the RAII story — resources
are released at every exit path without manual `defer` on every return.

#### Declaring cleanup

Two equivalent ways to opt a type into auto-drop:

```bux
// 1) Attribute — compiler looks up TypeName_Drop
@[Drop]
struct Token {
    id: int,
    counter: *int,
}

func Token_Drop(self: *Token) {
    // free / close / decrement …
}

// 2) Interface (stdlib `lib/Drop.bux`) — same static call, no vtable
import Drop;

extend Buffer for Drop {
    func Drop(self: *Buffer) {
        Mem_Free(self.data);
    }
}
```

Stdlib collections implement Drop (`Array_Drop`, `Map_Drop`, …). Calling
`Array_Drop` is the same cleanup as `Array_Free` for `Array<T>`.

#### When auto-drop runs

Auto-drop is **not** gated on `@[Checked]`. Any function can receive injected
`Type_Drop` at:

| Exit | Behavior |
|------|----------|
| End of block / function | Drop locals still owned |
| Early `return` | Drop all live locals **after** materializing the return value |
| Branch scope end | Only locals from the taken branch |
| Nested scopes | Drop in reverse order of declaration |

```bux
@[Drop]
struct Token { id: int, counter: *int }
func Token_Drop(self: *Token) { /* … */ }

func Early(flag: int, counter: *int) -> int {
    let t: Token = Token { id: 1, counter: counter };
    if flag == 0 {
        return 0;   // still runs Token_Drop(&t)
    }
    return 1;       // Token_Drop(&t) here too
}
```

See `examples/drop_early_return.bux` for branch-local vs fallthrough counts.

#### Field-move: skip Drop of the source (critical)

**Problem:** a local is moved **by value** into a struct field (or another local).
If the compiler still auto-dropped the source, you get a **double free** — the
field and the original local would both run `Array_Drop` on the same buffer.

**Rule:** after a **value move** out of a local, that local is **not** dropped.

```bux
struct Box {
    items: Array<int>;
}

func MakeBox() -> Box {
    var items: Array<int> = Array_New<int>(4);
    Array_Push<int>(&items, 10);
    Array_Push<int>(&items, 20);
    // Move `items` into the field — compiler skips Drop of `items`
    let b: Box = Box { items: items };
    return b;   // also: return-by-value skips Drop of `b` (caller owns it)
}
```

What the C backend does for `MakeBox` (simplified):

```c
Box MakeBox(void) {
    Array_int items = Array_New_int(4);
    Array_Push_int(&items, 10);
    Array_Push_int(&items, 20);
    Box b = (Box){ .items = items };
    return b;
    /* no Array_Drop_int(&items);  — moved into b.items */
    /* no Array_Drop on b;         — moved to caller via return */
}
```

Ownership after `MakeBox`:

1. Heap buffer lives inside `b.items` (and later the caller's `Box`).
2. `items` is **moved-out** → skip auto-Drop.
3. `b` is **returned by value** → skip auto-Drop at the return site; the caller
   (or the next owner) is responsible.

The same skip applies to:

- **Struct field init** — `S { field: local }` (field-move)
- **Assignment** — `a = b` when `b` is moved (value types with Drop)
- **Call argument** by value into a consuming parameter
- **`return x`** — move-on-return

Live, unmoved Drop locals still clean up on error paths (e.g. early `return`
before the move). That is intentional: only the **successful transfer** path
skips Drop.

Runnable check: `examples/move_field.bux` (also covered by
`make test-selfhost-smoke` on buxc2).

#### Partial field moves

Moving a **droppable field** out of a local (return or `let`) also skips Drop
of the **parent** local:

```bux
@[Drop]
struct Bag {
    items: Array<int>,
    tag: int,
}
func Bag_Drop(self: *Bag) {
    Array_Drop<int>(&self.items);
}

func TakeItems() -> Array<int> {
    var items: Array<int> = Array_New<int>(4);
    Array_Push<int>(&items, 42);
    let bag: Bag = Bag { items: items, tag: 7 };
    return bag.items;   // Bag_Drop skipped — items ownership transferred
}
```

Rules:

- Applies only when the **field type** is droppable (`Array_*`, `@[Drop]` types,
  etc.). Reading `bag.tag` (`int`) does **not** mark `bag` moved.
- After `let moved = bag.items`, `Bag_Drop(&bag)` is skipped; `moved` owns the
  array and is auto-dropped at scope end.
- **Remaining fields:** if the parent has other droppable fields that were *not*
  moved out, those still run their `Type_Drop` / collection Drop (session 70).
  Example: move `pair.left` → skip `PairBag_Drop`, still `Tracked_Drop(&pair.right)`.

```bux
@[Drop]
struct PairBag {
    left: Array<int>,
    right: Tracked,   // also @[Drop]
}
func TakeLeft() -> Array<int> {
    let pair: PairBag = …;
    return pair.left;   // Tracked_Drop(&pair.right) still runs
}
```

#### Nested path moves (`a.b.c`)

Moving a **deep** droppable field also works. The full dotted path is recorded
so remaining fields at every level still Drop:

```bux
@[Drop]
struct Outer {
    inner: Inner,   // Inner has items: Array + note: Tracked
    tag: Tracked,
}
func TakeNested() -> Array<int> {
    let outer: Outer = …;
    return outer.inner.items;
    // skips Outer_Drop
    // still: Tracked_Drop(&outer.inner.note) + Tracked_Drop(&outer.tag)
}
```

#### Field moves through pointers

When a local pointer aliases a local owner (`let p = &bag`), moving a field
through the pointer marks the **owner**, not the pointer:

```bux
let bag: Bag = …;
let p: *Bag = &bag;
return p.items;      // same as (*p).items
// skips Bag_Drop; still Tracked_Drop(&bag.tag)
```

Nested paths work the same: `p.inner.items` resolves `p → outer` then path
`inner.items`.

#### Cross-function pointer transfer (session 76)

When the **caller** passes `&bag` (or a pointer alias) into a function whose
parameter is `*Bag`, and the **callee** moves fields of that param
(`return p.items` / `let x = p.items`), the call site marks `bag` the same way
as a local partial move — parent `Bag_Drop` is skipped; remaining fields Drop.

```bux
func TakeItems(p: *Bag) -> Array<int> {
    return p.items;
}

func Caller() {
    let bag: Bag = …;
    let items: Array<int> = TakeItems(&bag);
    // bag.items transferred; Tracked_Drop(&bag.tag) still runs
}
```

Analysis is **same-module / known callee body** only (bootstrap HIR today).

Golden smoke: `make test-drop-move` / `examples/move_field_partial.bux` /
`examples/move_field_remaining.bux` / `examples/move_field_nested.bux` /
`examples/move_field_ptr.bux` / `examples/move_cross_fn.bux`.

#### Manual Drop and non-Drop types

- Types **without** `@[Drop]` / `Drop` impl are never auto-dropped (plain C layout).
- You can still call `Type_Drop(&x)` or use `defer` for explicit cleanup.
- `@[Release]` / default functions still get auto-drop for Drop types — Release
  only turns off the **borrow checker**, not RAII.

#### Limits (honest)

- Partial field moves skip the **parent** `Type_Drop` and drop **remaining**
  droppable fields individually, including nested paths `a.b.c`, local pointer
  aliases `p = &owner`, and **cross-function** `&owner` args when the callee
  body is visible (sessions 70/73/74/76).
- Local pointer aliases (`p = &local`) are tracked in-function; cross-function
  uses callee-body scan of pointer params (not full borrow checking).
- Interface Drop uses a static `TypeName_Drop` symbol (zero cost), not dynamic
  dispatch through a vtable.
- Double-free bugs in **unchecked** code that manually free *and* auto-drop are
  still possible if you free without invalidating the value — prefer one owner.

---

## Compile-Time Function Execution (CTFE) ✅ Implemented

`const func` functions are evaluated at compile time. Their results can be used in type sizes, array lengths, or other constant contexts.

```bux
const func Factorial(n: int) -> int {
    if n <= 1 {
        return 1;
    }
    return n * Factorial(n - 1);
}

const TABLE_SIZE = Factorial(10);  // 3628800 — computed at compile time

func Main() -> int {
    let arr: [TABLE_SIZE]int;  // Array size from compile-time value
    return 0;
}
```

### Supported in CTFE
- Integer, boolean, and string literals
- Arithmetic (`+`, `-`, `*`, `/`, `%`)
- Comparisons and logical operators
- `if` / `else` with constant conditions
- Calls to other `const func` functions (including recursion)

### Limitations
- No `while` / `for` loops (use recursion)
- No `mut` references or heap allocation
- No non-const function calls

---

## Error Handling

### Result and Option Types
```bux
enum Result {
    Ok(int),
    Err(String)
}

enum Option {
    Some(int),
    None
}
```

### The `?` Operator
The `?` operator automatically propagates errors:

```bux
func Divide(a: int, b: int) -> Result {
    if b == 0 {
        return Result_NewErr("division by zero");
    }
    return Result_NewOk(a / b);
}

func Compute() -> Result {
    let x: int = Divide(10, 2)?;  // If Err, returns immediately
    let y: int = Divide(x, 5)?;
    return Result_NewOk(y);
}
```

`?` can be used on `Result` and `Option` types in any expression context.
The type of `expr?` is the **Ok / Some payload** (`T` in `Result<T,E>` or
`Option<T>`), not always `int`. The enclosing function must return a compatible
Result/Option so Err/None can propagate.

```bux
// Generic Result — payload type is String
func GetName() -> Result<String, String> {
    return Result_NewOk<String, String>("bux");
}
func Run() -> Result<String, String> {
    let n: String = GetName()?;  // n: String
    return Result_NewOk<String, String>(n);
}
```

The postfix unwrap operator `expr!` extracts Ok/Some or panics (and exits) on
Err/None; its type is likewise the payload type.

See also `examples/try_operator.bux` and `examples/try_generic.bux`.

---

## Modules and Imports

```bux
// Single import
import Std::Io::PrintLine;

// Multiple imports
import Std::Io::{PrintLine, PrintInt};

// Wildcard import
import Std::Io::*;

// Module declaration
module MyModule;

pub func PublicFunc() -> int {
    return 42;
}

func PrivateFunc() -> int {
    return 0;
}
```

---

## Concurrency

Bux supports both **async/await** (stackful coroutines) and **pthread-based threads** with channels.

### Threads and Channels

```bux
import Std::Task::{Task_Spawn, Task_Join, TaskHandle};
import Std::Channel::{Channel, Channel_New, Channel_SendInt, Channel_RecvInt, Channel_Close};

func Producer(ch: *Channel<int>) {
    Channel_SendInt(ch, 42);
    Channel_Close<int>(ch);
}

func Consumer(ch: *Channel<int>) -> int {
    let val: int = Channel_RecvInt(ch);
    return val;
}

func Main() -> int {
    let ch: Channel<int> = Channel_New<int>(1);
    let p: *void = spawn Producer(&ch);
    let c: *void = spawn Consumer(&ch);
    Task_Join(TaskHandle { handle: p });
    Task_Join(TaskHandle { handle: c });
    return 0;
}
```

- `spawn Func()` creates a new pthread running `Func`
- `Channel<T>` is a buffered channel with mutex/condvar
- `Channel_RecvInt` returns `0` when the channel is closed and empty

---

## Async/Await

Bux supports stackful coroutines via `async`/`await` with a round-robin scheduler.

### Declaring Async Functions

```bux
async func Compute() -> int {
    PrintLine("step 1");
    bux_async_yield();
    PrintLine("step 2");
    return 42;
}
```

### Spawning Tasks

```bux
let handle = spawn Compute();
```

### Awaiting Results

```bux
let result: int = handle.await as int;
```

### Full Example

```bux
import Std::Io::{PrintLine, PrintInt};

async func Compute() -> int {
    PrintLine("Compute: start");
    bux_async_yield();
    PrintLine("Compute: done");
    return 42;
}

func Main() -> int {
    let h = spawn Compute();
    let r: int = h.await as int;
    PrintInt(r);
    return 0;
}
```

### Runtime Functions

| Function | Description |
|----------|-------------|
| `bux_async_yield()` | Yield control to the scheduler |
| `bux_async_spawn(fn)` | Create a new coroutine from a function |
| `bux_async_await(handle)` | Block until coroutine completes, return result |
| `bux_async_run()` | Run the scheduler (called implicitly from main) |
| `bux_async_sleep(ms)` | Sleep for `ms` milliseconds (non-blocking) |
| `bux_async_return(value, size)` | Copy return value into task result buffer |

---

## Operator Overloading

> **Status:** ✅ Implemented in bootstrap. Selfhost reserves syntax but has no method-table yet.

Overloadable operators use the naming convention `TypeName_operator_<op>`:

| Operator | Function Name | Signature Example |
|----------|--------------|-------------------|
| `+` | `operator_add` | `func T_operator_add(self: *T, other: T) -> T` |
| `-` | `operator_sub` | `func T_operator_sub(self: *T, other: T) -> T` |
| `*` | `operator_mul` | `func T_operator_mul(self: *T, other: T) -> T` |
| `/` | `operator_div` | `func T_operator_div(self: *T, other: T) -> T` |
| `%` | `operator_mod` | `func T_operator_mod(self: *T, other: T) -> T` |
| `==` | `operator_eq` | `func T_operator_eq(self: *T, other: T) -> bool` |
| `!=` | `operator_ne` | `func T_operator_ne(self: *T, other: T) -> bool` |
| `<` | `operator_lt` | `func T_operator_lt(self: *T, other: T) -> bool` |
| `<=` | `operator_le` | `func T_operator_le(self: *T, other: T) -> bool` |
| `>` | `operator_gt` | `func T_operator_gt(self: *T, other: T) -> bool` |
| `>=` | `operator_ge` | `func T_operator_ge(self: *T, other: T) -> bool` |
| `[]` (get) | `operator_index_get` | `func T_operator_index_get(self: *T, idx: int) -> U` |
| `[]` (set) | `operator_index_set` | `func T_operator_index_set(self: *T, idx: int, value: U)` |

**Notes:**
- Short-circuit operators (`&&`, `||`) cannot be overloaded.
- Generic method instantiation is supported.

---

## Operators

### Arithmetic
`+`, `-`, `*`, `/`, `%`, `**` (power)

### Comparison
`==`, `!=`, `<`, `<=`, `>`, `>=`

### Logical
`&&`, `||`, `!`

### Bitwise
`&`, `|`, `^`, `~`, `<<`, `>>`

### Assignment
`=`, `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `|=`, `^=`, `<<=`, `>>=`

### Other
- `as` — Cast: `expr as Type`
- `is` — Type test: `expr is Type`
- `?` — Try / error propagation: `expr?`
- `&` — Address-of: `&var`
- `*` — Dereference: `*ptr`
- `::` — Path separator: `Module::Name`
- `..` — Range (exclusive): `0..10`
- `..=` — Range (inclusive): `0..=10`
- `sizeof` — Size of type: `sizeof(Type)`

---

## Macros

Bux supports **declarative macros**. Expansion runs after parse and before
type-checking. Expanded AST uses **call-site** source locations (quote hygiene).
Both bootstrap and selfhost (`buxc2`) expand macros.

### Definition

```bux
macro! twice {
    ($x:expr) => {
        ($x) + ($x)
    }
}

// Trailing repetition
macro! sum_n {
    ( $($x:expr),* ) => {
        var acc: int = 0;
        $( acc = acc + $x; )*
        acc
    }
}

// Compound / zip: parallel lists from interleaved args
macro! add_pairs {
    ( $($a:expr, $b:expr),* ) => {
        var acc: int = 0;
        $( acc = acc + ($a + $b); )*
        acc
    }
}

// Multi-rep groups: `;` separates arg groups at the call site
macro! sum_groups {
    ( $($x:expr),* ; $($y:expr),* ) => {
        var s: int = 0;
        $( s = s + $x; )*
        $( s = s + $y; )*
        s
    }
}

// Nested template repetition (outer list → inner expands once per item)
macro! double_each_sum {
    ( $($x:expr),* ) => {
        var t: int = 0;
        $(
            $( t = t + $x; )*
            $( t = t + $x; )*
        )*
        t
    }
}

// ident fragment: bare identifier at the call site
macro! call0 {
    ( $f:ident ) => {
        $f()
    }
}

// literal (alias: lit) — only int/float/string/char/bool literals
macro! only_lit {
    ( $x:literal ) => { $x }
}

// block — only `{ … }` block expressions
macro! wrap_block {
    ( $b:block ) => { $b }
}

// stmt — one statement (let/if/… or expression-statement)
macro! with_setup {
    ( $s:stmt, $body:expr ) => {
        {
            $s
            $body
        }
    }
}
// call: with_setup!(let x: int = 10, x + 1)

// pat — match/let pattern (literals, `_`, enum variants, …)
macro! matches {
    ( $p:pat, $e:expr ) => {
        match $e { $p => 1, _ => 0 }
    }
}
// call: matches!(1, 1) · matches!(_, 99) · matches!(Opt::Some(v), opt)

// gensym: template locals renamed per expansion
macro! with_acc {
    ( $start:literal ) => {
        var n: int = $start;
        n = n + 1;
        n
    }
}
```

- Introduced with the `macro!` keyword.
- Each **rule** is `( pattern ) => { template }`.
- **Fragment kinds:**

  | Kind | Matches |
  |------|---------|
  | `expr` | any expression |
  | `ident` | bare identifier (`ekIdent`) |
  | `tt` | token-tree: any single call-site AST fragment; **delimiter-balanced multi-element groups** `(a, b)` and `[a, b]` flatten when spliced as the sole call argument (`$f($args)` → `f(a, b)`, not `f((a, b))`). Non-group `tt` unwraps to the value. Broader than `expr`. |
  | `literal` / `lit` | int/float/string/char/bool literal only |
  | `block` | block expression `{ … }` |
  | `stmt` | one statement (`let`/`if`/… or expression-stmt) |
  | `pat` / `pattern` | match pattern (`_`, literals, `Enum::Var(…)`, …) |
  | `type` | type expression from call-site shape: named (`int`), pointer (`*int`); spliced into `sizeof($t)`, `as $t`, `let x: $t` |

- Fragment names start with `$` (lexer `$ident`).
- **Repetition:** `$( $x:expr ),*` / `$( $x:expr )*` — one or more rep fragments per pattern.
- **Compound rep:** `$( $a:expr, $b:expr ),*` — interleaved args zip into parallel lists.
- **Multi-rep:** two (or more) `$(…)*` in one pattern; call site uses `;` between groups:
  `sum_groups!(1, 2; 10, 20, 30)`.
- Template `$( stmt; … )*` expands once per list item (zip when multiple lists used).
- Nested `$( $(…)* )*`: after outer binds list items as singles, inner expands once.
- **Expression-level rep in templates:** `$f( $($a),* )` — `$( expr ),*` / `$( expr )*`
  inside call arguments expands to N positional args (session 84).
- **Delimiter-balanced `:tt` groups:** `apply_tt!(Add, (3, 4))` or
  `apply_tt!(Add, [3, 4])` with `($f:ident, $args:tt) => { $f($args) }`
  expands to `Add(3, 4)`. Contrast `:expr`, which keeps the group as one value.
- **Free-form juxta (session 86):** pattern `$f:ident $args:tt` (comma optional
  between fragments) matches a **single call-site argument** that is a call
  expression: `apply_juxta!(Add(2, 5))` → binds `$f=Add`, `$args` = arg-list
  group, then `$f($args)` flattens to `Add(2, 5)`.
- **Type fragments (session 87+):** named, pointer, and **generic** types
  (`Array<int>`, `*int`); `$t` substitutes in `sizeof` / cast / let types and
  monomorph call type args (`Array_New<$t>`).
  ```bux
  macro! size_of {
      ( $t:type ) => { sizeof($t) as int }
  }
  macro! new_array {
      ( $t:type, $cap:expr ) => { Array_New<$t>($cap) }
  }
  let n: int = size_of!(int);
  let p: int = size_of!(*int);
  let s: int = size_of!(Array<int>);
  var a: Array<int> = new_array!(int, 4);
  ```
- **Operators-only `:tt` paste:**
  ```bux
  macro! apply_op {
      ( $op:tt, $a:expr, $b:expr ) => { $op($a, $b) }
  }
  macro! flip_op {
      ( $a:expr, $op:tt, $b:expr ) => { $op($b, $a) }
  }
  let x: int = apply_op!(+, 3, 4);   // 7
  let y: int = apply_op!(*, 6, 7);   // 42
  let z: int = flip_op!(10 - 3);     // -7  (juxta binary split)
  ```

### Invocation

```bux
let n = twice!(21);
let s = sum_n!(1, 2, 3);          // 6
let z = sum_n!();                 // 0
let p = add_pairs!(1, 10, 2, 20); // (1+10)+(2+20) = 33
let g = sum_groups!(1, 2; 10, 20, 30); // 63
let d = double_each_sum!(3, 4);   // 14
call0!(SomeFunc);
let a = with_acc!(10);            // 11
let b = with_acc!(20);            // 21 — different gensym'd `n`
let c = only_lit!(7);
// only_lit!(1 + 2);              // ERROR: no matching rule
let w = wrap_block!({ 1 + 2 });   // 3
```

- Syntax: `name!( arg, … )` (not unwrap: unwrap is `expr!` without `(`).
- Matching: fixed-arity by count; kind constraints; rep by groups / remaining args / chunk.

### Built-in `quote!`

```bux
let x = quote!(1 + 2);   // identity expand; locations grafted to call site
```

### Hygiene

Two layers (both bootstrap + selfhost):

1. **Call-site graft** — expanded AST uses the call site’s line/col/`sourceFile`
   (so diagnostics and `#line` point at the user call, not the macro definition).
2. **Gensym of template binders** — each expansion renames:
   - `let` / `var` locals introduced by the template
   - `for` loop binders in the template
   - Nested scopes (if/while/for bodies, MacroRep bodies)

   so two expansions of the same macro in one function do not collide under the
   C backend’s **function-scoped** locals (e.g. `__m1_n` and `__m2_n`).

Spliced `$frags` in expression positions are **not** gensym’d — they keep
call-site names/values.

#### Unhygienic binders (`var $name`)

To **introduce a binder whose name comes from the call site**, use a `$frag`
as the binder itself. That name is **not** gensym’d:

```bux
macro! let_mut {
    ( $name:ident, $init:literal ) => {
        var $name: int = $init;   // unhygienic: becomes `counter`, not __m1_…
        $name = $name + 1;
        $name
    }
}

// expands with local `counter` (and hygienic locals still unique)
let a = let_mut!(counter, 10);   // 11
let b = let_mut!(other, 20);     // 21

macro! double_acc {
    ( $start:literal ) => {
        var acc: int = $start;   // hygienic → __m1_acc / __m2_acc
        acc = acc + acc;
        acc
    }
}
```

| Binder form | After expand | Gensym? |
|-------------|--------------|---------|
| `var acc = …` (plain name in template) | `__mN_acc` | yes |
| `var $name = …` with `$name:ident` | call-site ident | **no** |
| `for $i in …` with `$i:ident` | call-site ident | **no** |

The binder must be a **`:ident` fragment** bound to a bare identifier. A plain
template name is always hygienic.

Examples: `examples/macro_hygiene.bux`, `examples/macro_unhygienic.bux`.

### Limits

- Up to two named rep lists per rule on selfhost (enough for zip + multi-rep).
- Compound chunk size currently 1 or 2.
- Nested macro *calls* expanded recursively (depth limit 32).
- Unhygienic binders only rename `let`/`var`/`for` binders — not full
  Scheme/Rust colored identifiers or `stmt`/`pat` token trees.
- Macro expansion still yields a **block expression**; unhygienic names are
  scoped to that block (not automatically injected into the caller scope).
- Expression-level `$(…)*` is only parsed inside **call argument lists** in
  templates (not as a free-standing primary expression).
- Raw delimiter-balanced `tt` covers **tuple** `(a, b)` and **slice lit**
  `[a, b]` groups, plus **juxta call-split** for `$f:ident $args:tt` matching
  `F(a, b)`.
- **Operators-only paste:** bare binary ops as `:tt` (`+`, `*`, `==`, …) and
  juxta binary split `$a:expr $op:tt $b:expr` on a single binary arg. Template
  form `$op($a, $b)` rebuilds `a OP b`. See `examples/macro_op_paste.bux`.
- **`:type` generics:** `Array<int>`, `*int`, nested type args; `$t` splices
  into `sizeof($t)`, casts, and `Array_New<$t>(…)`. See
  `examples/macro_type.bux`, `examples/macro_type_generic.bux`.
- Fully free-form token streams (unparsed soup) remain out of scope.

Examples: `examples/macro_tt.bux`, `examples/macro_tt_raw.bux`,
`examples/macro_repeat.bux`, `examples/macro_nested.bux`,
`examples/macro_type_generic.bux`, `examples/macro_op_paste.bux`.
