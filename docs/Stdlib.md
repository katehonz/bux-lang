# Bux Standard Library

The Bux standard library provides core functionality for systems programming. All modules are merged into every compilation, so no explicit linking is needed.

---

## Std::Io

Basic I/O and file operations wrapping C stdio.

### Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `PrintLine` | `func PrintLine(s: String)` | Print string with newline |
| `Print` | `func Print(s: String)` | Print string without newline |
| `PrintInt` | `func PrintInt(n: int)` | Print integer |
| `PrintFloat` | `func PrintFloat(f: float64)` | Print float |
| `PrintBool` | `func PrintBool(b: bool)` | Print boolean |
| `ReadLine` | `func ReadLine() -> String` | Read line from stdin |
| `ReadFile` | `func ReadFile(path: String) -> String` | Read entire file into string |
| `WriteFile` | `func WriteFile(path: String, content: String) -> bool` | Write string to file |
| `FileExists` | `func FileExists(path: String) -> bool` | Check if file exists |

---

## Std::Fs

File system operations beyond basic I/O.

| Function | Signature | Description |
|----------|-----------|-------------|
| `DirExists` | `func DirExists(path: String) -> bool` | Check if directory exists |
| `Mkdir` | `func Mkdir(path: String) -> bool` | Create directory (and parents if needed) |
| `ListDir` | `func ListDir(dir: String, ext: String, count: *int) -> *String` | List files matching extension |

### Example
```bux
import Std::Fs::{DirExists, Mkdir, ListDir};

func Main() -> int {
    if DirExists("/tmp") {
        PrintLine("/tmp exists");
    }
    Mkdir("build/output");
    var count: int = 0;
    let files: *String = ListDir("src", ".bux", &count);
    return 0;
}
```

### Example
```bux
import Std::Io::{PrintLine, ReadFile, WriteFile};

func Main() -> int {
    WriteFile("/tmp/test.txt", "Hello, Bux!");
    PrintLine(ReadFile("/tmp/test.txt"));
    return 0;
}
```

---

## Std::Array

Fully generic dynamic array `Array<T>`.

### Types
```bux
struct Array<T> {
    data: *T,
    len: uint,
    cap: uint,
}
```

### Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `Array_New<T>` | `func Array_New<T>(cap: uint) -> Array<T>` | Create new array |
| `Array_Push<T>` | `func Array_Push<T>(arr: *Array<T>, value: T)` | Append element |
| `Array_Get<T>` | `func Array_Get<T>(arr: *Array<T>, index: uint) -> T` | Get element at index |
| `Array_Len<T>` | `func Array_Len<T>(arr: *Array<T>) -> uint` | Get length |
| `Array_Free<T>` | `func Array_Free<T>(arr: *Array<T>)` | Free memory |

### Example
```bux
import Std::Array::{Array, Array_New, Array_Push, Array_Get};

func Main() -> int {
    let arr: Array<int> = Array_New<int>(4);
    Array_Push<int>(&arr, 10);
    Array_Push<int>(&arr, 20);
    PrintInt(Array_Get<int>(&arr, 0));  // 10
    Array_Free<int>(&arr);
    return 0;
}
```

---

## Std::String

String manipulation utilities.

### Core Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `String_Len` | `func String_Len(s: String) -> uint` | Length of string |
| `String_Eq` | `func String_Eq(a: String, b: String) -> bool` | Compare strings |
| `String_Concat` | `func String_Concat(a: String, b: String) -> String` | Concatenate (allocates) |
| `String_Copy` | `func String_Copy(s: String) -> String` | Copy string (allocates) |
| `String_StartsWith` | `func String_StartsWith(s: String, prefix: String) -> bool` | Check prefix |
| `String_EndsWith` | `func String_EndsWith(s: String, suffix: String) -> bool` | Check suffix |
| `String_Contains` | `func String_Contains(s: String, substr: String) -> bool` | Check substring |

### Slicing & Trimming

| Function | Signature | Description |
|----------|-----------|-------------|
| `String_Slice` | `func String_Slice(s: String, start: uint, len: uint) -> String` | Extract substring |
| `String_Trim` | `func String_Trim(s: String) -> String` | Trim both sides |
| `String_TrimLeft` | `func String_TrimLeft(s: String) -> String` | Trim left side |
| `String_TrimRight` | `func String_TrimRight(s: String) -> String` | Trim right side |

### Split & Join

| Function | Signature | Description |
|----------|-----------|-------------|
| `String_SplitCount` | `func String_SplitCount(s: String, delim: String) -> uint` | Count parts |
| `String_SplitPart` | `func String_SplitPart(s: String, delim: String, index: uint) -> String` | Get nth part (0-indexed) |
| `String_Join2` | `func String_Join2(a: String, b: String, sep: String) -> String` | Join two strings with separator |

### Conversion

| Function | Signature | Description |
|----------|-----------|-------------|
| `String_FromInt` | `func String_FromInt(n: int64) -> String` | Int to string |
| `String_ToInt` | `func String_ToInt(s: String) -> int64` | String to int |

### Find, Replace & Format

| Function | Signature | Description |
|----------|-----------|-------------|
| `String_Find` | `func String_Find(haystack: String, needle: String) -> String` | Find substring (returns pointer; 0 = not found) |
| `String_Replace` | `func String_Replace(s: String, old: String, new: String) -> String` | Replace first occurrence |
| `String_Format1` | `func String_Format1(pattern: String, a0: String) -> String` | Format with 1 arg (`{0}`) |
| `String_Format2` | `func String_Format2(pattern: String, a0: String, a1: String) -> String` | Format with 2 args |
| `String_Format3` | `func String_Format3(pattern: String, a0: String, a1: String, a2: String) -> String` | Format with 3 args |

### Example
```bux
import Std::String;

func Main() -> int {
    let s: String = String_Replace("hello world", "world", "Bux");
    PrintLine(s);  // "hello Bux"

    let fmt: String = String_Format2("{0} + {1} = magic", "Bux", "QBE");
    PrintLine(fmt);  // "Bux + QBE = magic"

    let found: String = String_Find("hello world", "world");
    if found as uint != 0 {
        PrintLine("found!");
    }
    return 0;
}
```

---

## Std::StringBuilder

Efficient string construction using a dynamic buffer.

### Types
```bux
struct StringBuilder {
    handle: *void,
}
```

### Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `StringBuilder_New` | `func StringBuilder_New() -> StringBuilder` | Create with default capacity (64) |
| `StringBuilder_NewCap` | `func StringBuilder_NewCap(cap: uint) -> StringBuilder` | Create with custom capacity |
| `StringBuilder_Append` | `func StringBuilder_Append(sb: *StringBuilder, s: String)` | Append string |
| `StringBuilder_AppendInt` | `func StringBuilder_AppendInt(sb: *StringBuilder, n: int64)` | Append integer |
| `StringBuilder_AppendFloat` | `func StringBuilder_AppendFloat(sb: *StringBuilder, f: float64)` | Append float |
| `StringBuilder_AppendChar` | `func StringBuilder_AppendChar(sb: *StringBuilder, c: char8)` | Append char |
| `StringBuilder_Build` | `func StringBuilder_Build(sb: *StringBuilder) -> String` | Build result string |
| `StringBuilder_Free` | `func StringBuilder_Free(sb: *StringBuilder)` | Free memory |

### Example
```bux
import Std::String::{StringBuilder, StringBuilder_New, StringBuilder_Append, StringBuilder_AppendInt, StringBuilder_Build, StringBuilder_Free};

func Main() -> int {
    let sb: StringBuilder = StringBuilder_New();
    StringBuilder_Append(&sb, "Hello, ");
    StringBuilder_Append(&sb, "World! #");
    StringBuilder_AppendInt(&sb, 42);
    PrintLine(StringBuilder_Build(&sb));  // "Hello, World! #42"
    StringBuilder_Free(&sb);
    return 0;
}
```

---

## Std::Mem

Memory management wrappers around C runtime functions.

| Function | Signature | Description |
|----------|-----------|-------------|
| `Alloc` | `func Alloc(size: uint) -> *void` | Allocate memory |
| `Realloc` | `func Realloc(ptr: *void, size: uint) -> *void` | Reallocate memory |
| `Free` | `func Free(ptr: *void)` | Free memory |
| `MemEq` | `func MemEq(a: *void, b: *void, size: uint) -> bool` | Byte-wise memory comparison |
| `New` | `func New<T>() -> *T` | Typed allocation (`sizeof(T)` bytes) |

### Example
```bux
import Std::Mem;

func Main() -> int {
    let p: *void = Alloc(64);
    Free(p);

    let n: *int = New<int>();
    // use n...
    Free(n as *void);
    return 0;
}
```

---

## Std::Set

Generic hash set for deduplication and membership testing.

### Types
```bux
struct SetEntry<T> {
    value: T,
    occupied: bool,
}

struct Set<T> {
    entries: *SetEntry<T>,
    cap: uint,
    len: uint,
}
```

### Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `Set_New<T>` | `func Set_New<T>(cap: uint) -> Set<T>` | Create set |
| `Set_Add<T>` | `func Set_Add<T>(s: *Set<T>, value: T)` | Insert element (ignores duplicates) |
| `Set_Has<T>` | `func Set_Has<T>(s: *Set<T>, value: T) -> bool` | Check membership |
| `Set_Len<T>` | `func Set_Len<T>(s: *Set<T>) -> uint` | Element count |
| `Set_Free<T>` | `func Set_Free<T>(s: *Set<T>)` | Free memory |

### Example
```bux
import Std::Set;

func Main() -> int {
    var s: Set<int> = Set_New<int>(16);
    Set_Add(&s, 10);
    Set_Add(&s, 20);
    Set_Add(&s, 10);  // duplicate, ignored
    if Set_Has(&s, 10) {
        PrintLine("has 10");
    }
    Set_Free(&s);
    return 0;
}
```

---

## Std::Map

Generic hash map `Map<K, V>` for value-type keys (int, float, etc.).

### Types
```bux
struct MapEntry<K, V> {
    key: K,
    value: V,
    occupied: bool,
}

struct Map<K, V> {
    entries: *MapEntry<K, V>,
    cap: uint,
    len: uint,
}
```

### Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `Map_New<K,V>` | `func Map_New<K,V>(cap: uint) -> Map<K,V>` | Create map |
| `Map_Set<K,V>` | `func Map_Set<K,V>(m: *Map<K,V>, key: K, value: V)` | Insert/update |
| `Map_Get<K,V>` | `func Map_Get<K,V>(m: *Map<K,V>, key: K) -> V` | Get value (zero if missing) |
| `Map_Has<K,V>` | `func Map_Has<K,V>(m: *Map<K,V>, key: K) -> bool` | Check key exists |
| `Map_Len<K,V>` | `func Map_Len<K,V>(m: *Map<K,V>) -> uint` | Entry count |
| `Map_Free<K,V>` | `func Map_Free<K,V>(m: *Map<K,V>)` | Free memory |

### Example
```bux
import Std::Map::{Map, Map_New, Map_Set, Map_Get, Map_Free};

func Main() -> int {
    let m: Map<int, String> = Map_New<int, String>(16);
    Map_Set<int, String>(&m, 1, "one");
    Map_Set<int, String>(&m, 2, "two");
    PrintLine(Map_Get<int, String>(&m, 1));  // "one"
    Map_Free<int, String>(&m);
    return 0;
}
```

> **Note:** For `String` keys, use `StringMap<V>` below which uses `strcmp` for key comparison.

---

## Std::StringMap

Specialized hash map for `String` keys with any value type.

### Types
```bux
struct StringMapEntry<V> {
    key: String,
    value: V,
    occupied: bool,
}

struct StringMap<V> {
    entries: *StringMapEntry<V>,
    cap: uint,
    len: uint,
}
```

### Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `StringMap_New<V>` | `func StringMap_New<V>(cap: uint) -> StringMap<V>` | Create map |
| `StringMap_Set<V>` | `func StringMap_Set<V>(m: *StringMap<V>, key: String, value: V)` | Insert/update |
| `StringMap_Get<V>` | `func StringMap_Get<V>(m: *StringMap<V>, key: String) -> V` | Get value |
| `StringMap_Has<V>` | `func StringMap_Has<V>(m: *StringMap<V>, key: String) -> bool` | Check key exists |
| `StringMap_Len<V>` | `func StringMap_Len<V>(m: *StringMap<V>) -> uint` | Entry count |
| `StringMap_Free<V>` | `func StringMap_Free<V>(m: *StringMap<V>)` | Free memory |

---

## Std::Path

Path manipulation utilities.

| Function | Signature | Description |
|----------|-----------|-------------|
| `Path_Join` | `func Path_Join(a: String, b: String) -> String` | Join path segments |
| `Path_Parent` | `func Path_Parent(path: String) -> String` | Get parent directory |
| `Path_Ext` | `func Path_Ext(path: String) -> String` | Get file extension |

### Example
```bux
import Std::Path::{Path_Join, Path_Parent, Path_Ext};

func Main() -> int {
    PrintLine(Path_Join("/home", "docs"));       // "/home/docs"
    PrintLine(Path_Parent("/a/b/c.txt"));         // "/a/b"
    PrintLine(Path_Ext("main.bux"));              // ".bux"
    return 0;
}
```

---

## Runtime Functions

These C functions are provided by `runtime.c` and are available via `extern` declarations.

| Function | Signature | Description |
|----------|-----------|-------------|
| `bux_alloc` | `func bux_alloc(size: uint) -> *void` | Allocate memory |
| `bux_realloc` | `func bux_realloc(ptr: *void, size: uint) -> *void` | Reallocate memory |
| `bux_free` | `func bux_free(ptr: *void)` | Free memory |
| `bux_bounds_check` | `func bux_bounds_check(index: uint, len: uint)` | Panic on OOB |
| `bux_hash_string` | `func bux_hash_string(s: String) -> uint` | DJB2 hash for strings |
| `bux_hash_bytes` | `func bux_hash_bytes(ptr: *void, size: uint) -> uint` | DJB2 hash for raw bytes |

---

## Std::Async

Low-level async runtime for stackful coroutines. These functions are used by the `async`/`await` language features.

### Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `bux_async_spawn` | `func bux_async_spawn(fn: *void) -> *void` | Create a new coroutine from a function pointer |
| `bux_async_yield` | `func bux_async_yield()` | Yield control to the scheduler |
| `bux_async_await` | `func bux_async_await(handle: *void) -> *void` | Block until coroutine completes, return result pointer |
| `bux_async_run` | `func bux_async_run()` | Run the round-robin scheduler |
| `bux_async_sleep` | `func bux_async_sleep(ms: int64)` | Non-blocking sleep for `ms` milliseconds |
| `bux_async_return` | `func bux_async_return(value: *void, size: int64)` | Copy return value into task result buffer |
| `bux_now_ms` | `func bux_now_ms() -> int64` | Monotonic clock in milliseconds |

### Example

```bux
extern func bux_async_yield();
extern func bux_async_spawn(fn: *void) -> *void;
extern func bux_async_await(handle: *void) -> *void;

async func Compute() -> int {
    bux_async_yield();
    return 42;
}

func Main() -> int {
    let h = spawn Compute();
    let r: int = h.await as int;
    return 0;
}
```

---

## Future Modules

- `Std::Result` — Shipped via algebraic enums ✅
- `Std::Option` — Shipped via algebraic enums ✅
- `Std::Math` — `Sqrt`, `Pow`, `Min`, `Max`, `Abs` ✅
- `Std::Fs` — Directory operations ✅
- `Std::Mem` — Memory wrappers ✅
- `Std::Set` — Hash set ✅
- `Std::Path` — Path manipulation ✅
- `Std::Os` — `Args`, `Env`, `Cwd`, `Chdir` ✅
- `Std::Time` — `NowMs`, `NowUs`, `SleepMs` ✅
- `Std::Process` — `Run`, `Output` ✅
- `Std::Fmt` — String formatting with interpolation ⏳
- `Std::Iter` — Iterator trait and combinators ⏳
- `Std::Task` / `Std::Channel` — Lightweight concurrency (pthread-based threads) ✅
---

## Std::Os

Operating system interface.

```bux
import Std::Os::{Os_ArgsCount, Os_Args, Os_GetEnv, Os_SetEnv, Os_GetCwd, Os_Chdir};
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `Os_ArgsCount` | `func Os_ArgsCount() -> int` | Number of command-line arguments |
| `Os_Args` | `func Os_Args(index: int) -> String` | Get argument at index |
| `Os_GetEnv` | `func Os_GetEnv(name: String) -> String` | Get environment variable |
| `Os_SetEnv` | `func Os_SetEnv(name: String, value: String) -> bool` | Set environment variable |
| `Os_GetCwd` | `func Os_GetCwd() -> String` | Get current working directory |
| `Os_Chdir` | `func Os_Chdir(path: String) -> bool` | Change directory |

---

## Std::Time

Time utilities.

```bux
import Std::Time::{Time_NowMs, Time_NowUs, Time_SleepMs};
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `Time_NowMs` | `func Time_NowMs() -> int64` | Current time in milliseconds |
| `Time_NowUs` | `func Time_NowUs() -> int64` | Current time in microseconds |
| `Time_SleepMs` | `func Time_SleepMs(ms: int64)` | Sleep for N milliseconds |

---

## Std::Process

Process spawning.

```bux
import Std::Process::{Process_Run, Process_Output};
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `Process_Run` | `func Process_Run(cmd: String) -> int` | Run command, return exit code |
| `Process_Output` | `func Process_Output(cmd: String) -> String` | Run command, capture stdout |

