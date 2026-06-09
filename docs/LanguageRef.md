# Bux Language Reference

This document describes the Bux programming language as implemented by the bootstrap compiler.

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
11. [Error Handling](#error-handling)
12. [Modules and Imports](#modules-and-imports)
13. [Async/Await](#asyncawait)
14. [Operator Overloading](#operator-overloading)
15. [Operators](#operators)

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
(T1, T2, T3)    // Tuple
func(T1) -> T2  // Function type
```

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

func Main() -> int {
    let r: Result = Result { tag: Result_Ok };
    r.data.Ok_0 = 42;

    if r.tag == Result_Ok {
        PrintInt(r.data.Ok_0);
    }
    return 0;
}
```

---

## Pattern Matching

```bux
match opt {
    Option::Some(value) => PrintInt(value),
    Option::None => PrintLine("none")
}
```

Supported patterns:
- Wildcard: `_`
- Literal: `42`, `"hello"`, `true`
- Identifier: `name`
- Range: `1..9`, `1..=9`
- Enum destructuring: `Shape::Circle(r)`
- Struct destructuring: `Point { x: 0, y: 0 }`
- Tuple: `(a, b, c)`
- Guard: `t if t < 0`

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

Bux introduces **gradual ownership** — opt-in borrow checking. By default, Bux is permissive like C. With `@[Checked]`, the borrow checker enforces memory safety rules.

### Syntax

```bux
// Default: permissive mode (like C/Nim) — raw pointers, no checks
func QuickSort(arr: *int, len: int) {
    for i in 0..len {
        arr[i] = arr[i] * 2;
    }
}

// Opt-in: @[Checked] enables borrow checking
@[Checked]
func Scale(val: &mut int) {
    *val = *val * 2;  // OK: &mut T allows mutation
}

@[Checked]
func Read(val: &int) -> int {
    return *val;       // OK: &T allows reading
}

@[Checked]
func BadWrite(val: &int) {
    *val = 42;         // ERROR: cannot write through shared reference '&T'
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

### Rules in @[Checked] functions

- `&T` cannot be used to mutate data (compile-time error)
- `&mut T` allows mutation
- `*T` pointers are unrestricted (escape hatch)
- `&mut T` coerces to `&T` and `*T`
- **Double mutable borrow**: passing `&mut x` twice to the same call is an error
  ```bux
  Swap(&mut x, &mut x);  // ERROR: double mutable borrow of x
  ```
- **Use after move**: using a moved `own T` value is an error until reassigned
  ```bux
  let msg: own String = "hello";
  Process(msg);          // move
  PrintLine(msg);        // ERROR: use of moved value
  msg = "reassigned";    // OK: reinitialization
  PrintLine(msg);
  ```

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
