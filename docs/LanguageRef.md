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
13. [Operators](#operators)

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
```

### String Literals
```bux
"Hello"           // String (UTF-8)
c8"Hello"         // *char8 (C string)
c16"Hello"        // *char16
c32"Hello"        // *char32
```

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

## Gradual Ownership (Phase 8.2)

Bux introduces **gradual ownership** — the first language to offer opt-in borrow checking.

### Syntax

```bux
// Default: permissive mode (like C/Nim)
func QuickSort(arr: *int, len: int) {
    for i in 0..len {
        arr[i] = arr[i] * 2;
    }
}

// Opt-in: @[Checked] enables borrow checking
@[Checked]
func SafeMerge(a: &[int], b: &[int]) -> Vec<int> {
    // &T = shared reference (borrow checker enforced)
    // &mut T = mutable reference (exclusive)
    // own T = ownership transfer
}
```

### Reference types

| Type | Syntax | Description |
|------|--------|-------------|
| Raw pointer | `*T` | C-style pointer, no checks |
| Shared ref | `&T` | Borrowed reference (checked) |
| Mutable ref | `&mut T` | Exclusive mutable borrow |
| Owned | `own T` | Ownership transfer |

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
