# Bux Standard Library

The Bux standard library provides core functionality for systems programming. It is intentionally minimal for the bootstrap phase and will grow as the language matures.

---

## Std::Io

Basic input/output operations wrapping C stdio.

### Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `PrintLine` | `func PrintLine(s: String)` | Print string with newline |
| `Print` | `func Print(s: String)` | Print string without newline |
| `PrintInt` | `func PrintInt(n: int)` | Print integer |
| `PrintFloat` | `func PrintFloat(f: float64)` | Print float |
| `PrintBool` | `func PrintBool(b: bool)` | Print boolean |
| `ReadLine` | `func ReadLine() -> String` | Read line from stdin |

### Example
```bux
import Std::Io::{PrintLine, PrintInt};

func Main() -> int {
    PrintLine("Hello, World!");
    PrintInt(42);
    return 0;
}
```

---

## Std::Array

Dynamic array of integers (currently hardcoded for `int`).

### Types

```bux
struct Array {
    data: *int,
    len: uint,
    cap: uint,
}
```

### Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `Array_New` | `func Array_New(cap: uint) -> Array` | Create new array with capacity |
| `Array_Push` | `func Array_Push(arr: *Array, value: int)` | Append element |
| `Array_Get` | `func Array_Get(arr: *Array, index: uint) -> int` | Get element at index |
| `Array_Len` | `func Array_Len(arr: *Array) -> uint` | Get length |
| `Array_Free` | `func Array_Free(arr: *Array)` | Free memory |

### Example
```bux
import Std::Array::{Array, Array_New, Array_Push, Array_Get};

func Main() -> int {
    let arr: Array = Array_New(4);
    Array_Push(&arr, 10);
    Array_Push(&arr, 20);
    PrintInt(Array_Get(&arr, 0));  // 10
    Array_Free(&arr);
    return 0;
}
```

---

## Std::String

String manipulation utilities for the built-in `String` type (`const char*` in C).

### Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `String_Len` | `func String_Len(s: String) -> uint` | Length of string (wraps `strlen`) |
| `String_Eq` | `func String_Eq(a: String, b: String) -> bool` | Compare strings for equality |
| `String_Concat` | `func String_Concat(a: String, b: String) -> String` | Concatenate two strings (allocates) |
| `String_Copy` | `func String_Copy(s: String) -> String` | Copy string (allocates) |
| `String_StartsWith` | `func String_StartsWith(s: String, prefix: String) -> bool` | Check prefix |

### Example
```bux
import Std::String::{String_Len, String_Concat, String_Eq};

func Main() -> int {
    let hello: String = "Hello";
    let world: String = "World";
    let greeting: String = String_Concat(hello, ", ");
    let full: String = String_Concat(greeting, world);
    PrintLine(full);  // "Hello, World"
    return 0;
}
```

---

## Std::Map

Hash map with `String` keys and `int` values using linear probing.

### Types

```bux
struct MapEntry {
    key: String,
    value: int,
    occupied: bool,
}

struct Map {
    entries: *MapEntry,
    cap: uint,
    len: uint,
}
```

### Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `Map_New` | `func Map_New(cap: uint) -> Map` | Create new map with given capacity |
| `Map_Set` | `func Map_Set(m: *Map, key: String, value: int)` | Insert or update key |
| `Map_Get` | `func Map_Get(m: *Map, key: String) -> int` | Get value by key (0 if missing) |
| `Map_Has` | `func Map_Has(m: *Map, key: String) -> bool` | Check if key exists |
| `Map_Len` | `func Map_Len(m: *Map) -> uint` | Number of entries |
| `Map_Free` | `func Map_Free(m: *Map)` | Free memory |

### Example
```bux
import Std::Map::{Map, Map_New, Map_Set, Map_Get, Map_Has};

func Main() -> int {
    let m: Map = Map_New(16);
    Map_Set(&m, "one", 1);
    Map_Set(&m, "two", 2);
    PrintInt(Map_Get(&m, "one"));   // 1
    PrintInt(Map_Get(&m, "three")); // 0
    Map_Free(&m);
    return 0;
}
```

---

## Runtime Functions

These C functions are provided by `runtime.c` and are available via `extern` declarations.

| Function | Signature | Description |
|----------|-----------|-------------|
| `bux_alloc` | `func bux_alloc(size: uint) -> *void` | Allocate memory (wraps `malloc`) |
| `bux_realloc` | `func bux_realloc(ptr: *void, size: uint) -> *void` | Reallocate memory |
| `bux_free` | `func bux_free(ptr: *void)` | Free memory |
| `bux_bounds_check` | `func bux_bounds_check(index: uint, len: uint)` | Panic on out-of-bounds |

---

## Future Modules

Planned for future phases:

- `Std::Result` — Generic `Result<T, E>` with `?` operator support
- `Std::Option` — Generic `Option<T>`
- `Std::Math` — `Sqrt`, `Pow`, `Min`, `Max`, `Abs`
- `Std::Os` — `Args`, `Env`, `Exit`, `Cwd`
- `Std::Fmt` — String formatting with interpolation
- `Std::Iter` — Iterator trait and combinators
- `Std::Task` / `Std::Channel` — Lightweight concurrency
