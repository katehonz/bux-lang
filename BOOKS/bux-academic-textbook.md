# Bux: Съвременен Системен Език за Програмиране
## Bux: A Modern Systems Programming Language

### Академичен Учебник / Academic Textbook

**Версия 0.2.0 / Version 0.2.0**

**Юни 2026 / June 2026**

---

**Авторски колектив / Authors:** Екипът на Bux / The Bux Team

**Резюме / Abstract:** Настоящият учебник представлява изчерпателно академично въведение в езика за програмиране Bux — бърз, компилиран, строго типизиран, многопарадигмен системен език с постепенна собственост (gradual ownership). Учебникът обхваща лексикална структура, типове, контрол на потока, функции, структури, изброими типове, съпоставяне на образци, генерични типове, интерфейси, управление на паметта, обработка на грешки, модули, стандартна библиотека, метапрограмиране по време на компилация, асинхронно програмиране и инструментариум. Всеки раздел е представен двуезично (български/английски) с академичен стил, примери и практически упражнения.

This textbook provides a comprehensive academic introduction to the Bux programming language — a fast, compiled, strongly-typed, multi-paradigm systems language featuring gradual ownership. The textbook covers lexical structure, types, control flow, functions, structs, enums, pattern matching, generics, interfaces, memory management, error handling, modules, the standard library, compile-time function execution, asynchronous programming, and the toolchain. Each section is presented bilingually (Bulgarian/English) in an academic style, with examples and practical exercises.

---

## Съдържание / Table of Contents

| Глава / Chapter | Заглавие / Title | Стр. / Page |
|:---|:---|---:|
| | **Предговор / Preface** | |
| 1 | Въведение в програмирането и Bux / Introduction to Programming and Bux | |
| 2 | Лексикална структура / Lexical Structure | |
| 3 | Типове данни и променливи / Data Types and Variables | |
| 4 | Изрази и оператори / Expressions and Operators | |
| 5 | Управление на изпълнението / Control Flow | |
| 6 | Функции / Functions | |
| 7 | Структури от данни (Structs) / Data Structures (Structs) | |
| 8 | Методи и интерфейси / Methods and Interfaces | |
| 9 | Изброими типове (Enums) / Enumerated Types (Enums) | |
| 10 | Съпоставяне на образци / Pattern Matching | |
| 11 | Генерични типове / Generics | |
| 12 | Постепенна собственост / Gradual Ownership | |
| 13 | Обработка на грешки / Error Handling | |
| 14 | Модули, пакети и импорти / Modules, Packages, and Imports | |
| 15 | Стандартна библиотека / The Standard Library | |
| 16 | Изпълнение по време на компилация (CTFE) / Compile-Time Function Execution | |
| 17 | Асинхронно програмиране / Asynchronous Programming | |
| 18 | Инструментариум и работен процес / Toolchain and Workflow | |
| 19 | Интероперативност с C / C Interoperability | |
| | **Приложения / Appendices** | |
| A | Справочник на вградените типове / Built-in Types Reference | |
| B | Справочник на операторите / Operator Reference | |
| C | Пълен справочник на стандартната библиотека / Standard Library Full Reference | |
| D | Ключови думи / Reserved Keywords | |
| E | Атрибути на компилатора / Compiler Attributes | |
| | **Индекси / Indexes** | |
| | Азбучен индекс (български) / Alphabetical Index (Bulgarian) | |
| | Alphabetical Index (English) | |

---

## Предговор / Preface

### Български

Настоящият учебник е създаден с цел да популяризира езика за програмиране Bux сред академичната общност в България и по света. Bux е проектиран като мост между свободата на C и безопасността на Rust — предлагайки *постепенна собственост* (gradual ownership), при която програмистът сам избира кога да активира проверките на паметта чрез атрибута `@[Checked]`.

Езикът е в активна фаза на разработка (bootstrapping). Първият компилатор (`buxc`) е написан на Nim. Само-хостващият компилатор (`buxc2`) е написан на самия Bux и генерира C код, който се компилира с GCC/Clang до нативен машинен код. Към юни 2026 г. езикът разполага с пълна стандартна библиотека от 11 модула, 23 примерни програми и напълно функционален само-хостващ компилатор.

Учебникът е предназначен за студенти от специалности "Информатика", "Компютърни науки" и "Софтуерно инженерство", както и за практикуващи програмисти, които желаят да разширят инструментариума си с модерен системен език. Не се изисква предварителен опит с конкретен език, но се предполага базово разбиране на концепциите на програмирането.

### English

This textbook was created to promote the Bux programming language within the academic community in Bulgaria and globally. Bux is designed as a bridge between the freedom of C and the safety of Rust — offering *gradual ownership*, whereby the programmer chooses when to activate memory safety checks via the `@[Checked]` attribute.

The language is in an active bootstrap phase. The first compiler (`buxc`) is written in Nim. The self-hosting compiler (`buxc2`) is written in Bux itself and generates C code, which is compiled with GCC/Clang to native machine code. As of June 2026, the language features a full standard library of 11 modules, 23 example programs, and a fully functional self-hosting compiler.

This textbook is intended for students in Computer Science, Informatics, and Software Engineering programs, as well as for practicing programmers who wish to expand their toolkit with a modern systems language. No prior experience with a specific language is required, though basic understanding of programming concepts is assumed.

---

## Глава 1 / Chapter 1
## Въведение в програмирането и Bux
## Introduction to Programming and Bux

### 1.1 Какво е Bux? / What is Bux?

**BG:** Bux е бърз, компилиран, строго типизиран, многопарадигмен език за системно програмиране. Той заема уникална ниша между C (пълна свобода, ръчно управление на паметта) и Rust (стриктна безопасност чрез borrow checker). Основната иновация на Bux е **постепенната собственост** (*gradual ownership*) — механизъм, при който програмистът може да активира проверки за безопасност на паметта само върху избрани функции чрез атрибута `@[Checked]`, докато останалата част от кода остава неограничена като в C.

**EN:** Bux is a fast, compiled, strongly-typed, multi-paradigm systems programming language. It occupies a unique niche between C (complete freedom, manual memory management) and Rust (strict safety via borrow checker). Bux's primary innovation is **gradual ownership** — a mechanism whereby the programmer can enable memory safety checks only on selected functions via the `@[Checked]` attribute, while the remainder of the code remains unrestricted as in C.

### 1.2 Философия на езика / Language Philosophy

**BG:** Bux следва следните фундаментални принципи:

1. **Няма скрити разходи** (*No hidden costs*) — всяка операция в кода съответства на предвидима машинна инструкция.
2. **Няма скрити алокации** (*No hidden allocations*) — паметта се заделя само когато програмистът изрично го поиска.
3. **Няма скрит контролен поток** (*No hidden control flow*) — няма неявни изключения, деструктори или операторно претоварване.
4. **Постепенна безопасност** (*Gradual safety*) — от C-подобна свобода до Rust-подобна безопасност, по избор на програмиста.
5. **Без боклукчийско събиране** (*No garbage collection*) — цялата памет се управлява ръчно, чрез borrow checker или чрез стандартната библиотека.

**EN:** Bux adheres to the following fundamental principles:

1. **No hidden costs** — every operation in the code corresponds to a predictable machine instruction.
2. **No hidden allocations** — memory is allocated only when the programmer explicitly requests it.
3. **No hidden control flow** — no implicit exceptions, destructors, or operator overloading.
4. **Gradual safety** — from C-like freedom to Rust-like safety, at the programmer's discretion.
5. **No garbage collection** — all memory is managed manually, via the borrow checker, or via the standard library.

### 1.3 Сравнение с други езици / Comparison with Other Languages

| Характеристика / Feature | C | Rust | Nim | Bux |
|:---|:---:|:---:|:---:|:---:|
| Компилиран до машинен код / Compiled to native | ✓ | ✓ | ✓ | ✓ |
| Ръчно управление на паметта / Manual memory | ✓ | — | ✓ | ✓ |
| Borrow checker | — | ✓ (задължителен) | — | ✓ (по избор / optional) |
| Генерични типове / Generics | — | ✓ | ✓ | ✓ |
| Алгебрични изброими типове / Algebraic enums | — | ✓ | — | ✓ |
| CTFE (compile-time execution) | — | ✓ (ограничено) | ✓ | ✓ (пълна рекурсия) |
| Self-hosting компилатор | — | ✓ | ✓ | ✓ |
| C бекенд / C backend | — | — | ✓ | ✓ |
| Асинхронност / Async | — | ✓ | ✓ | ✓ |

### 1.4 Инсталация и първа програма / Installation and First Program

**BG:** За да инсталирате Bux, са необходими:
- Nim 1.6+ (за bootstrap компилатора)
- GCC или Clang
- GNU Make

```bash
git clone https://github.com/bux-lang/bux
cd bux
make build          # Компилира bootstrap компилатора 'buxc'
./buxc new hello    # Създава нов проект
cd hello
./buxc run          # Компилира и изпълнява програмата
```

**EN:** To install Bux, the following prerequisites are needed:
- Nim 1.6+ (for the bootstrap compiler)
- GCC or Clang
- GNU Make

```bash
git clone https://github.com/bux-lang/bux
cd bux
make build          # Compiles the bootstrap compiler 'buxc'
./buxc new hello    # Creates a new project
cd hello
./buxc run          # Compiles and runs the program
```

### 1.5 "Hello, World!" / "Hello, World!"

**BG:** Първата програма на всеки програмист:

```bux
import Std::Io::PrintLine;

func Main() -> int {
    PrintLine("Здравей, свят!");
    return 0;
}
```

- `import Std::Io::PrintLine` — импортира функцията `PrintLine` от стандартната библиотека.
- `func Main() -> int` — дефинира главната функция, която връща целочислен код на изход (0 = успех).
- `PrintLine(...)` — извежда низ на стандартния изход с нов ред.
- Всяка инструкция завършва с `;`.

**EN:** Every programmer's first program:

```bux
import Std::Io::PrintLine;

func Main() -> int {
    PrintLine("Hello, world!");
    return 0;
}
```

- `import Std::Io::PrintLine` — imports the `PrintLine` function from the standard library.
- `func Main() -> int` — defines the main function, which returns an integer exit code (0 = success).
- `PrintLine(...)` — outputs a string to standard output with a newline.
- Each statement ends with `;`.

---

## Глава 2 / Chapter 2
## Лексикална структура / Lexical Structure

### 2.1 Коментари / Comments

**BG:** Bux поддържа едноредови и многоредови коментари. Многоредовите коментари могат да бъдат влагани (*nested*).

```bux
// Това е едноредов коментар

/*
   Това е многоредов коментар.
   Може да обхваща няколко реда.
   /* Вложените коментари са позволени */
*/
```

**EN:** Bux supports single-line and multi-line comments. Multi-line comments may be nested.

```bux
// This is a single-line comment

/*
   This is a multi-line comment.
   It can span multiple lines.
   /* Nested comments are allowed */
*/
```

### 2.2 Идентификатори / Identifiers

**BG:** Идентификаторите започват с буква (a–z, A–Z) или долна черта (`_`), последвани от букви, цифри или долни черти. Различават се главни от малки букви (*case-sensitive*).

Валидни: `x`, `myVar`, `_private`, `MAX_SIZE`, `iter2`

Невалидни: `2var`, `my-var`, `class`

**EN:** Identifiers begin with a letter (a–z, A–Z) or underscore (`_`), followed by letters, digits, or underscores. They are case-sensitive.

Valid: `x`, `myVar`, `_private`, `MAX_SIZE`, `iter2`

Invalid: `2var`, `my-var`, `class`

### 2.3 Запазени думи / Reserved Keywords

**BG:** Следните думи са запазени и не могат да се използват като идентификатори:

```
func, let, var, const, type, struct, enum, union, interface, extend,
module, import, pub, extern, if, else, while, do, loop, for, in,
break, continue, return, match, as, is, null, self, super, sizeof,
async, await, spawn
```

**EN:** The following words are reserved and cannot be used as identifiers:

```
func, let, var, const, type, struct, enum, union, interface, extend,
module, import, pub, extern, if, else, while, do, loop, for, in,
break, continue, return, match, as, is, null, self, super, sizeof,
async, await, spawn
```

### 2.4 Низови литерали / String Literals

**BG:** Bux поддържа три категории низови литерали:

| Синтаксис / Syntax | Тип / Type | Описание / Description |
|:---|:---|:---|
| `"текст"` | `String` | Стандартен UTF-8 низ. Поддържа escape-последователности: `\n`, `\t`, `\r`, `\\`, `\"` |
| `c8"текст"` | `*char8` | C-низ (8-битови символи) |
| `c16"текст"` | `*char16` | C-низ (16-битови символи) |
| `c32"текст"` | `*char32` | C-низ (32-битови символи) |
| `` `суров текст` `` | `String` | Суров низ — всички символи се третират буквално. `\n` е два символа, а не нов ред. Новите редове в изходния код се запазват. |

**EN:** Bux supports three categories of string literals:

| Syntax | Type | Description |
|:---|:---|:---|
| `"text"` | `String` | Standard UTF-8 string. Supports escape sequences: `\n`, `\t`, `\r`, `\\`, `\"` |
| `c8"text"` | `*char8` | C string (8-bit characters) |
| `c16"text"` | `*char16` | C string (16-bit characters) |
| `c32"text"` | `*char32` | C string (32-bit characters) |
| `` `raw text` `` | `String` | Raw string — all characters are treated literally. `\n` is two characters, not a newline. Newlines in source are preserved. |

### 2.5 Числови литерали / Number Literals

**BG:** Bux поддържа цели числа, числа с плаваща запетая и системи с различна основа:

```bux
42          // int (десетичен)
3.14        // float64
0x2A        // шестнадесетичен (hex)
0o52        // осмичен (octal)
0b101010    // двоичен (binary)
32i8        // int8 с наставка
1000u64     // uint64 с наставка
```

Налични наставки: `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`, `f32`, `f64`.

**EN:** Bux supports integers, floating-point numbers, and alternative bases:

```bux
42          // int (decimal)
3.14        // float64
0x2A        // hexadecimal
0o52        // octal
0b101010    // binary
32i8        // int8 with suffix
1000u64     // uint64 with suffix
```

Available suffixes: `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`, `f32`, `f64`.

---

## Глава 3 / Chapter 3
## Типове данни и променливи / Data Types and Variables

### 3.1 Декларация на променливи / Variable Declaration

**BG:** Bux разграничава три вида обвързвания (*bindings*):

```bux
let x: int = 42;        // Непроменливо (immutable) — стойността не може да се променя
var y: int = 10;        // Променливо (mutable) — стойността може да се променя
y = 20;                 // Позволено

const MAX: int = 100;   // Константа по време на компилация (като #define в C)
```

- `let` — създава непроменлива променлива. Веднъж зададена, стойността не може да бъде променяна.
- `var` — създава променлива променлива. Стойността може да бъде променяна чрез присвояване.
- `const` — създава константа, чиято стойност се изчислява по време на компилация.

Анотацията на типа (`: Type`) е **задължителна** при декларация.

**EN:** Bux distinguishes three kinds of bindings:

```bux
let x: int = 42;        // Immutable — the value cannot be changed
var y: int = 10;        // Mutable — the value can be changed
y = 20;                 // Allowed

const MAX: int = 100;   // Compile-time constant (like #define in C)
```

- `let` — creates an immutable variable. Once assigned, the value cannot be changed.
- `var` — creates a mutable variable. The value can be changed via assignment.
- `const` — creates a constant whose value is computed at compile time.

Type annotation (`: Type`) is **mandatory** at declaration.

### 3.2 Примитивни типове / Primitive Types

**BG:** Bux предоставя богат набор от вградени числови и символни типове:

| Тип / Type | Описание / Description | Размер / Size |
|:---|:---|:---|
| `int8` | Знаков 8-битов | 1 байт |
| `int16` | Знаков 16-битов | 2 байта |
| `int32` | Знаков 32-битов | 4 байта |
| `int64` | Знаков 64-битов | 8 байта |
| `int` | Знаков, размер според архитектурата | 4 или 8 байта |
| `uint8` | Беззнаков 8-битов | 1 байт |
| `uint16` | Беззнаков 16-битов | 2 байта |
| `uint32` | Беззнаков 32-битов | 4 байта |
| `uint64` | Беззнаков 64-битов | 8 байта |
| `uint` | Беззнаков, размер според архитектурата | 4 или 8 байта |
| `float32` | Плаваща запетая, единична точност | 4 байта |
| `float64` | Плаваща запетая, двойна точност | 8 байта |
| `bool` | Булев (true/false) | 1 байт |
| `bool8`, `bool16`, `bool32` | Булев с изричен размер | 1/2/4 байта |
| `char8` | 8-битов символ | 1 байт |
| `char16` | 16-битов символ | 2 байта |
| `char32` | 32-битов символ | 4 байта |
| `String` | C-съвместим низ (`const char*`) | размер на указател |

**EN:** Bux provides a rich set of built-in numeric and character types:

| Type | Description | Size |
|:---|:---|:---|
| `int8` | Signed 8-bit | 1 byte |
| `int16` | Signed 16-bit | 2 bytes |
| `int32` | Signed 32-bit | 4 bytes |
| `int64` | Signed 64-bit | 8 bytes |
| `int` | Signed, architecture-dependent | 4 or 8 bytes |
| `uint8` | Unsigned 8-bit | 1 byte |
| `uint16` | Unsigned 16-bit | 2 bytes |
| `uint32` | Unsigned 32-bit | 4 bytes |
| `uint64` | Unsigned 64-bit | 8 bytes |
| `uint` | Unsigned, architecture-dependent | 4 or 8 bytes |
| `float32` | Single-precision floating point | 4 bytes |
| `float64` | Double-precision floating point | 8 bytes |
| `bool` | Boolean (true/false) | 1 byte |
| `bool8`, `bool16`, `bool32` | Boolean with explicit size | 1/2/4 bytes |
| `char8` | 8-bit character | 1 byte |
| `char16` | 16-bit character | 2 bytes |
| `char32` | 32-bit character | 4 bytes |
| `String` | C-compatible string (`const char*`) | pointer size |

### 3.3 Съставни типове / Composite Types

**BG:** Bux поддържа следните съставни типове:

```bux
*T              // Указател към T (Pointer)
T[]             // Срез (Slice) — непълен масив
T[N]            // Масив с фиксиран размер N
(T1, T2, T3)    // Кортеж (Tuple)
func(T1) -> T2  // Функционален тип
```

- `*T` — суров C-подобен указател. Без проверки.
- `T[]` — непълен срез (без информация за дължина).
- `T[N]` — масив с фиксиран размер, известен по време на компилация.
- `(T1, T2)` — разнороден кортеж от две или повече стойности.

**EN:** Bux supports the following composite types:

```bux
*T              // Pointer to T
T[]             // Slice — unsized array
T[N]            // Fixed-size array of N elements
(T1, T2, T3)    // Tuple
func(T1) -> T2  // Function type
```

- `*T` — raw C-like pointer. No checks.
- `T[]` — unsized slice (no length information carried).
- `T[N]` — array with a fixed size known at compile time.
- `(T1, T2)` — heterogeneous tuple of two or more values.

### 3.4 Област на видимост (Scope) / Scope

**BG:** Променливите в Bux са видими в блока, в който са декларирани. Блоковете се ограничават с `{` и `}`. Вложените блокове имат достъп до променливите от външните блокове, но не и обратното.

```bux
func Main() -> int {
    let x: int = 10;
    {
        let y: int = 20;
        // x е видимо тук: OK
        PrintInt(x + y);
    }
    // y не е видимо тук: ГРЕШКА
    return 0;
}
```

**EN:** Variables in Bux are visible within the block in which they are declared. Blocks are delimited by `{` and `}`. Inner blocks have access to variables from outer blocks, but not vice versa.

```bux
func Main() -> int {
    let x: int = 10;
    {
        let y: int = 20;
        // x is visible here: OK
        PrintInt(x + y);
    }
    // y is not visible here: ERROR
    return 0;
}
```

---

## Глава 4 / Chapter 4
## Изрази и оператори / Expressions and Operators

### 4.1 Аритметични оператори / Arithmetic Operators

**BG:**

| Оператор / Operator | Описание / Description | Пример / Example |
|:---|:---|:---|
| `+` | Събиране / Addition | `a + b` |
| `-` | Изваждане / Subtraction | `a - b` |
| `*` | Умножение / Multiplication | `a * b` |
| `/` | Деление / Division | `a / b` |
| `%` | Остатък от деление / Modulo | `a % b` |
| `**` | Степенуване / Exponentiation | `a ** b` |

**EN:**

| Operator | Description | Example |
|:---|:---|:---|
| `+` | Addition | `a + b` |
| `-` | Subtraction | `a - b` |
| `*` | Multiplication | `a * b` |
| `/` | Division | `a / b` |
| `%` | Modulo | `a % b` |
| `**` | Exponentiation | `a ** b` |

### 4.2 Оператори за сравнение / Comparison Operators

**BG:**

| Оператор / Operator | Описание / Description |
|:---|:---|
| `==` | Равенство / Equal |
| `!=` | Различие / Not equal |
| `<` | По-малко / Less than |
| `<=` | По-малко или равно / Less than or equal |
| `>` | По-голямо / Greater than |
| `>=` | По-голямо или равно / Greater than or equal |

Връщат стойност от тип `bool`.

**EN:**

| Operator | Description |
|:---|:---|
| `==` | Equal |
| `!=` | Not equal |
| `<` | Less than |
| `<=` | Less than or equal |
| `>` | Greater than |
| `>=` | Greater than or equal |

They return a value of type `bool`.

### 4.3 Логически оператори / Logical Operators

**BG:**

| Оператор / Operator | Описание / Description | Пример / Example |
|:---|:---|:---|
| `&&` | Логическо И / Logical AND | `a && b` |
| `\|\|` | Логическо ИЛИ / Logical OR | `a \|\| b` |
| `!` | Логическо отрицание / Logical NOT | `!a` |

Късо съединение (*short-circuit evaluation*): ако левият операнд на `&&` е `false`, десният не се изчислява. Ако левият операнд на `||` е `true`, десният не се изчислява.

**EN:**

| Operator | Description | Example |
|:---|:---|:---|
| `&&` | Logical AND | `a && b` |
| `\|\|` | Logical OR | `a \|\| b` |
| `!` | Logical NOT | `!a` |

Short-circuit evaluation: if the left operand of `&&` is `false`, the right operand is not evaluated. If the left operand of `||` is `true`, the right operand is not evaluated.

### 4.4 Побитови оператори / Bitwise Operators

**BG:**

| Оператор / Operator | Описание / Description |
|:---|:---|
| `&` | Побитово И / Bitwise AND |
| `\|` | Побитово ИЛИ / Bitwise OR |
| `^` | Побитово изключващо ИЛИ / Bitwise XOR |
| `~` | Побитово отрицание / Bitwise NOT |
| `<<` | Отместване наляво / Left shift |
| `>>` | Отместване надясно / Right shift |

**EN:**

| Operator | Description |
|:---|:---|
| `&` | Bitwise AND |
| `\|` | Bitwise OR |
| `^` | Bitwise XOR |
| `~` | Bitwise NOT |
| `<<` | Left shift |
| `>>` | Right shift |

### 4.5 Оператори за присвояване / Assignment Operators

**BG:** Bux поддържа стандартни съставни присвоявания:

```bux
x = value;      // Присвояване
x += value;     // x = x + value
x -= value;     // x = x - value
x *= value;     // x = x * value
x /= value;     // x = x / value
x %= value;     // x = x % value
x &= value;     // x = x & value
x |= value;     // x = x | value
x ^= value;     // x = x ^ value
x <<= value;    // x = x << value
x >>= value;    // x = x >> value
```

**EN:** Bux supports standard compound assignments:

```bux
x = value;      // Assignment
x += value;     // x = x + value
x -= value;     // x = x - value
x *= value;     // x = x * value
x /= value;     // x = x / value
x %= value;     // x = x % value
x &= value;     // x = x & value
x |= value;     // x = x | value
x ^= value;     // x = x ^ value
x <<= value;    // x = x << value
x >>= value;    // x = x >> value
```

### 4.6 Специални оператори / Special Operators

**BG:**

| Оператор / Operator | Описание / Description | Пример / Example |
|:---|:---|:---|
| `as` | Преобразуване на тип / Type cast | `value as int64` |
| `is` | Проверка на тип / Type test | `value is int` |
| `?` | Разпространение на грешка / Error propagation | `func()?` |
| `!` | Разопаковане / Unwrap (panic on error) | `result!` |
| `&` | Адрес на / Address-of | `&variable` |
| `*` | Дереференция / Dereference | `*pointer` |
| `::` | Разделител на път / Path separator | `Module::Name` |
| `..` | Изключващ интервал / Exclusive range | `0..10` |
| `..=` | Включващ интервал / Inclusive range | `0..=10` |
| `sizeof` | Размер на тип / Size of type | `sizeof(int64)` |

**EN:**

| Operator | Description | Example |
|:---|:---|:---|
| `as` | Type cast | `value as int64` |
| `is` | Type test | `value is int` |
| `?` | Error propagation | `func()?` |
| `!` | Unwrap (panic on error) | `result!` |
| `&` | Address-of | `&variable` |
| `*` | Dereference | `*pointer` |
| `::` | Path separator | `Module::Name` |
| `..` | Exclusive range | `0..10` |
| `..=` | Inclusive range | `0..=10` |
| `sizeof` | Size of type | `sizeof(int64)` |

### 4.7 Приоритет на операторите / Operator Precedence

**BG:** Операторите са групирани в следните нива на приоритет (от най-висок към най-нисък):

1. `*`, `/`, `%`, `**` (умножение/деление)
2. `+`, `-` (събиране/изваждане)
3. `<<`, `>>` (побитово отместване)
4. `&` (побитово И)
5. `^` (побитово XOR)
6. `|` (побитово ИЛИ)
7. `==`, `!=`, `<`, `<=`, `>`, `>=` (сравнение)
8. `&&` (логическо И)
9. `||` (логическо ИЛИ)
10. `=` , `+=`, `-=`, и т.н. (присвояване)

Препоръчва се използването на скоби `()` за изрично указване на реда на изчисление.

**EN:** Operators are grouped into the following precedence levels (from highest to lowest):

1. `*`, `/`, `%`, `**` (multiplication/division)
2. `+`, `-` (addition/subtraction)
3. `<<`, `>>` (bit shift)
4. `&` (bitwise AND)
5. `^` (bitwise XOR)
6. `|` (bitwise OR)
7. `==`, `!=`, `<`, `<=`, `>`, `>=` (comparison)
8. `&&` (logical AND)
9. `||` (logical OR)
10. `=`, `+=`, `-=`, etc. (assignment)

The use of parentheses `()` is recommended to explicitly specify evaluation order.

---

## Глава 5 / Chapter 5
## Управление на изпълнението / Control Flow

### 5.1 Условен оператор if/else / If/Else Conditional

**BG:** Конструкцията `if`/`else if`/`else` е стандартният механизъм за условно изпълнение:

```bux
if x > 0 {
    PrintLine("положително");
} else if x < 0 {
    PrintLine("отрицателно");
} else {
    PrintLine("нула");
}
```

- Условието трябва да е от тип `bool`.
- Скобите около условието не са задължителни.
- Тялото на всеки клон се огражда с `{ }`.

**EN:** The `if`/`else if`/`else` construct is the standard mechanism for conditional execution:

```bux
if x > 0 {
    PrintLine("positive");
} else if x < 0 {
    PrintLine("negative");
} else {
    PrintLine("zero");
}
```

- The condition must be of type `bool`.
- Parentheses around the condition are optional.
- The body of each branch is delimited by `{ }`.

### 5.2 Цикъл while / While Loop

**BG:** Цикълът `while` изпълнява тялото си докато условието е истина. Условието се проверява **преди** всяка итерация.

```bux
var i: int = 0;
while i < 10 {
    PrintInt(i);
    i += 1;
}
```

**EN:** The `while` loop executes its body as long as the condition is true. The condition is checked **before** each iteration.

```bux
var i: int = 0;
while i < 10 {
    PrintInt(i);
    i += 1;
}
```

### 5.3 Цикъл do/while / Do/While Loop

**BG:** Цикълът `do`/`while` изпълнява тялото си поне веднъж, след което проверява условието **след** всяка итерация.

```bux
var i: int = 0;
do {
    PrintInt(i);
    i += 1;
} while i < 10;
```

**EN:** The `do`/`while` loop executes its body at least once, then checks the condition **after** each iteration.

```bux
var i: int = 0;
do {
    PrintInt(i);
    i += 1;
} while i < 10;
```

### 5.4 Цикъл loop (безкраен) / Loop (Infinite)

**BG:** Цикълът `loop` е безкраен цикъл. Използва се заедно с `break` и `continue` за ръчно управление.

```bux
var i: int = 0;
loop {
    if i >= 10 {
        break;
    }
    PrintInt(i);
    i += 1;
}
```

**EN:** The `loop` construct is an infinite loop. It is used together with `break` and `continue` for manual control.

```bux
var i: int = 0;
loop {
    if i >= 10 {
        break;
    }
    PrintInt(i);
    i += 1;
}
```

### 5.5 Цикъл for с интервали / For Loop with Ranges

**BG:** Цикълът `for` итерира върху интервал от стойности:

```bux
// Изключващ интервал 0, 1, 2, ..., 9
for i in 0..10 {
    PrintInt(i);
}

// Включващ интервал 0, 1, 2, ..., 10
for i in 0..=10 {
    PrintInt(i);
}
```

- `a..b` — интервал от `a` (включително) до `b` (изключително).
- `a..=b` — интервал от `a` (включително) до `b` (включително).

**EN:** The `for` loop iterates over a range of values:

```bux
// Exclusive range 0, 1, 2, ..., 9
for i in 0..10 {
    PrintInt(i);
}

// Inclusive range 0, 1, 2, ..., 10
for i in 0..=10 {
    PrintInt(i);
}
```

- `a..b` — range from `a` (inclusive) to `b` (exclusive).
- `a..=b` — range from `a` (inclusive) to `b` (inclusive).

### 5.6 Етикетиран break и continue / Labeled Break and Continue

**BG:** Bux поддържа етикетирани `break` и `continue`, които позволяват излизане от външни цикли:

```bux
outer: for i in 0..5 {
    for j in 0..5 {
        if i * j > 10 {
            break outer;       // Излиза от двата цикъла
        }
        PrintInt(i * j);
    }
}
```

Етикетът се поставя пред цикъла с двоеточие (`outer:`). `break outer` излиза от цикъла с етикет `outer`.

**EN:** Bux supports labeled `break` and `continue`, which allow breaking out of outer loops:

```bux
outer: for i in 0..5 {
    for j in 0..5 {
        if i * j > 10 {
            break outer;       // Breaks out of both loops
        }
        PrintInt(i * j);
    }
}
```

The label is placed before the loop with a colon (`outer:`). `break outer` exits the loop labeled `outer`.

---

## Глава 6 / Chapter 6
## Функции / Functions

### 6.1 Дефиниция на функция / Function Definition

**BG:** Функциите в Bux се дефинират с ключовата дума `func`:

```bux
func Add(a: int, b: int) -> int {
    return a + b;
}
```

- `func` — ключова дума за дефиниция на функция.
- `Add` — име на функцията (с главна буква по конвенция).
- `(a: int, b: int)` — списък с параметри, всеки с изричен тип.
- `-> int` — тип на връщаната стойност.
- `{ ... }` — тяло на функцията.
- `return` — връща стойност и прекратява изпълнението на функцията.
- Всяка инструкция завършва с `;`.

**EN:** Functions in Bux are defined with the `func` keyword:

```bux
func Add(a: int, b: int) -> int {
    return a + b;
}
```

- `func` — keyword for function definition.
- `Add` — function name (capitalized by convention).
- `(a: int, b: int)` — parameter list, each with an explicit type.
- `-> int` — return type.
- `{ ... }` — function body.
- `return` — returns a value and terminates the function.
- Each statement ends with `;`.

### 6.2 Главна функция / Main Function

**BG:** Всяка изпълнима програма на Bux трябва да съдържа функция `Main`, която връща `int` (код на завършване):

```bux
func Main() -> int {
    // тяло на програмата
    return 0;
}
```

**EN:** Every executable Bux program must contain a `Main` function that returns `int` (exit code):

```bux
func Main() -> int {
    // program body
    return 0;
}
```

### 6.3 Предварителна декларация / Forward Declaration

**BG:** Функциите могат да бъдат декларирани преди дефиницията си (forward declaration). Това позволява взаимно-рекурсивни функции:

```bux
func IsEven(n: int) -> bool;     // Декларация без тяло

func IsOdd(n: int) -> bool {
    if n == 0 {
        return false;
    }
    return IsEven(n - 1);
}

func IsEven(n: int) -> bool {    // Дефиниция
    if n == 0 {
        return true;
    }
    return IsOdd(n - 1);
}
```

**EN:** Functions can be declared before their definition (forward declaration). This enables mutually recursive functions:

```bux
func IsEven(n: int) -> bool;     // Declaration without body

func IsOdd(n: int) -> bool {
    if n == 0 {
        return false;
    }
    return IsEven(n - 1);
}

func IsEven(n: int) -> bool {    // Definition
    if n == 0 {
        return true;
    }
    return IsOdd(n - 1);
}
```

### 6.4 Външни функции (C FFI) / External Functions (C FFI)

**BG:** Функции от C могат да бъдат извиквани чрез `extern func`:

```bux
extern func printf(fmt: *char8, ...);
extern func malloc(size: uint) -> *void;
extern func free(ptr: *void);

func Main() -> int {
    printf(c8"Hello %s\n", c8"world");
    return 0;
}
```

Променливият брой аргументи се обозначава с `...`.

**EN:** C functions can be called via `extern func`:

```bux
extern func printf(fmt: *char8, ...);
extern func malloc(size: uint) -> *void;
extern func free(ptr: *void);

func Main() -> int {
    printf(c8"Hello %s\n", c8"world");
    return 0;
}
```

Variadic arguments are denoted by `...`.

### 6.5 Функции с атрибути / Attributed Functions

**BG:** Bux поддържа атрибути на компилатора, които модифицират поведението на функцията:

```bux
@[Checked]          // Активира borrow checking за тази функция
func Scale(val: &mut int) {
    *val = *val * 2;
}

const func Fact(n: int) -> int {   // Изпълнява се по време на компилация
    if n <= 1 { return 1; }
    return n * Fact(n - 1);
}

async func Compute() -> int {       // Асинхронна корутина
    bux_async_yield();
    return 42;
}
```

Налични атрибути: `@[Checked]`, `const func`, `async func`.

**EN:** Bux supports compiler attributes that modify function behavior:

```bux
@[Checked]          // Enables borrow checking for this function
func Scale(val: &mut int) {
    *val = *val * 2;
}

const func Fact(n: int) -> int {   // Executed at compile time
    if n <= 1 { return 1; }
    return n * Fact(n - 1);
}

async func Compute() -> int {       // Async coroutine
    bux_async_yield();
    return 42;
}
```

Available attributes: `@[Checked]`, `const func`, `async func`.

---

## Глава 7 / Chapter 7
## Структури от данни (Structs) / Data Structures (Structs)

### 7.1 Дефиниция на структура / Struct Definition

**BG:** Структурите в Bux са съставни типове, които обединяват няколко полета под едно име:

```bux
struct Rectangle {
    width: int;
    height: int;
}
```

Полетата се разделят с `;` (не със запетая). Всяко поле има изричен тип.

**EN:** Structs in Bux are composite types that group multiple fields under one name:

```bux
struct Rectangle {
    width: int;
    height: int;
}
```

Fields are separated by `;` (not commas). Each field has an explicit type.

### 7.2 Създаване и достъп / Creation and Access

**BG:** Структурите се създават чрез синтаксис с фигурни скоби:

```bux
func Main() -> int {
    let rect: Rectangle = Rectangle { width: 10, height: 5 };
    PrintInt(rect.width);   // Достъп до поле чрез точка
    PrintInt(rect.height);
    return 0;
}
```

**EN:** Structs are created using brace syntax:

```bux
func Main() -> int {
    let rect: Rectangle = Rectangle { width: 10, height: 5 };
    PrintInt(rect.width);   // Field access via dot
    PrintInt(rect.height);
    return 0;
}
```

### 7.3 Методи чрез extend / Methods via Extend

**BG:** Методите в Bux се дефинират чрез блок `extend`:

```bux
extend Rectangle {
    func Area(self: Rectangle) -> int {
        return self.width * self.height;
    }

    func Perimeter(self: Rectangle) -> int {
        return 2 * (self.width + self.height);
    }
}

func Main() -> int {
    let rect: Rectangle = Rectangle { width: 10, height: 5 };
    PrintInt(rect.Area());        // 50
    PrintInt(rect.Perimeter());   // 30
    return 0;
}
```

- `self: Rectangle` — първият параметър на метода е `self`, който получава екземпляра.
- Методите се извикват чрез точкова нотация: `instance.Method()`.

**EN:** Methods in Bux are defined via `extend` blocks:

```bux
extend Rectangle {
    func Area(self: Rectangle) -> int {
        return self.width * self.height;
    }

    func Perimeter(self: Rectangle) -> int {
        return 2 * (self.width + self.height);
    }
}

func Main() -> int {
    let rect: Rectangle = Rectangle { width: 10, height: 5 };
    PrintInt(rect.Area());        // 50
    PrintInt(rect.Perimeter());   // 30
    return 0;
}
```

- `self: Rectangle` — the first parameter of the method is `self`, which receives the instance.
- Methods are called via dot notation: `instance.Method()`.

---

## Глава 8 / Chapter 8
## Методи и интерфейси / Methods and Interfaces

### 8.1 Дефиниция на интерфейс / Interface Definition

**BG:** Интерфейсът дефинира набор от методи, които даден тип трябва да имплементира:

```bux
interface Drawable {
    func Draw(self: &Self);
}
```

- `Self` е специален тип, който се отнася до типа, имплементиращ интерфейса.

**EN:** An interface defines a set of methods that a type must implement:

```bux
interface Drawable {
    func Draw(self: &Self);
}
```

- `Self` is a special type referring to the type implementing the interface.

### 8.2 Имплементация на интерфейс / Interface Implementation

**BG:** Имплементацията се осъществява чрез `extend Type for Interface`:

```bux
struct Circle {
    radius: float64;
}

extend Circle for Drawable {
    func Draw(self: &Circle) {
        PrintLine("Drawing a circle");
    }
}
```

**EN:** Implementation is done via `extend Type for Interface`:

```bux
struct Circle {
    radius: float64;
}

extend Circle for Drawable {
    func Draw(self: &Circle) {
        PrintLine("Drawing a circle");
    }
}
```

### 8.3 Ограничения чрез типажи / Trait Bounds

**BG:** Генеричните функции могат да изискват типажите като ограничения:

```bux
func Render<T: Drawable>(obj: T) {
    obj.Draw();
}

func Main() -> int {
    let c: Circle = Circle { radius: 5.0 };
    Render(c);  // Извежда "Drawing a circle"
    return 0;
}
```

Синтаксисът `T: Drawable` означава "T трябва да имплементира интерфейса Drawable".

**EN:** Generic functions can require traits as bounds:

```bux
func Render<T: Drawable>(obj: T) {
    obj.Draw();
}

func Main() -> int {
    let c: Circle = Circle { radius: 5.0 };
    Render(c);  // Outputs "Drawing a circle"
    return 0;
}
```

The syntax `T: Drawable` means "T must implement the Drawable interface".

---

## Глава 9 / Chapter 9
## Изброими типове (Enums) / Enumerated Types (Enums)

### 9.1 Прости изброими типове / Simple Enums

**BG:** Простият enum дефинира краен набор от именувани константи:

```bux
enum Color {
    Red,
    Green,
    Blue
}

func Main() -> int {
    let c: Color = Color::Red;
    if c == Color::Red {
        PrintLine("червено");
    }
    return 0;
}
```

Елементите се достъпват чрез `EnumName::Variant`.

**EN:** A simple enum defines a finite set of named constants:

```bux
enum Color {
    Red,
    Green,
    Blue
}

func Main() -> int {
    let c: Color = Color::Red;
    if c == Color::Red {
        PrintLine("red");
    }
    return 0;
}
```

Variants are accessed via `EnumName::Variant`.

### 9.2 Алгебрични изброими типове / Algebraic Enums (Tagged Unions)

**BG:** Алгебричният enum (наричан още tagged union или sum type) позволява на вариантите да носят данни:

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

Това се превежда до C-структура с поле `tag` (коя вариантна) и `union` с полетата за данни:

```c
struct Result {
    uint tag;
    union {
        int Ok_0;
        String Err_0;
    } data;
};
```

**EN:** An algebraic enum (also called tagged union or sum type) allows variants to carry data:

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

This is lowered to a C struct with a `tag` field (which variant) and a `union` with the data fields:

```c
struct Result {
    uint tag;
    union {
        int Ok_0;
        String Err_0;
    } data;
};
```

### 9.3 Ръчна работа с алгебрични enum / Manual Algebraic Enum Usage

**BG:** На ниско ниво, алгебричните enum се манипулират чрез полетата `tag` и `data`:

```bux
func Main() -> int {
    let r: Result = Result { tag: Result_Ok };
    r.data.Ok_0 = 42;

    if r.tag == Result_Ok {
        PrintInt(r.data.Ok_0);   // 42
    }
    return 0;
}
```

В практиката обаче се предпочита съпоставянето на образци (Глава 10).

**EN:** At the low level, algebraic enums are manipulated via the `tag` and `data` fields:

```bux
func Main() -> int {
    let r: Result = Result { tag: Result_Ok };
    r.data.Ok_0 = 42;

    if r.tag == Result_Ok {
        PrintInt(r.data.Ok_0);   // 42
    }
    return 0;
}
```

In practice, however, pattern matching is preferred (Chapter 10).

---

## Глава 10 / Chapter 10
## Съпоставяне на образци / Pattern Matching

### 10.1 Конструкция match / The Match Construct

**BG:** `match` е мощен механизъм за разклоняване, който съпоставя стойност срещу множество образци (*patterns*):

```bux
match value {
    pattern1 => действие1,
    pattern2 => действие2,
    _ => действие_по_подразбиране
}
```

Всеки клон се състои от образец, стрелка `=>` и израз. Запетайката разделя клоновете.

**EN:** `match` is a powerful branching mechanism that matches a value against multiple patterns:

```bux
match value {
    pattern1 => action1,
    pattern2 => action2,
    _ => default_action
}
```

Each branch consists of a pattern, arrow `=>`, and an expression. Commas separate branches.

### 10.2 Видове образци / Pattern Types

**BG:** Bux поддържа следните видове образци:

| Образец / Pattern | Пример / Example | Описание / Description |
|:---|:---|:---|
| Заместващ (Wildcard) | `_` | Съвпада с всяка стойност |
| Литерал | `42`, `"hello"`, `true` | Съвпада с конкретна стойност |
| Идентификатор | `name` | Свързва стойността с име |
| Интервал (Range) | `1..9`, `1..=9` | Съвпада със стойност в интервал |
| Деструктуриране на enum | `Shape::Circle(r)` | Извлича данни от вариант на enum |
| Деструктуриране на struct | `Point { x: 0, y }` | Съвпада със структура, извлича полета |
| Кортеж (Tuple) | `(a, b, c)` | Съвпада с кортеж |
| Охранител (Guard) | `pat if условие` | Допълнително условие към образец |

**EN:** Bux supports the following pattern types:

| Pattern | Example | Description |
|:---|:---|:---|
| Wildcard | `_` | Matches any value |
| Literal | `42`, `"hello"`, `true` | Matches a specific value |
| Identifier | `name` | Binds the value to a name |
| Range | `1..9`, `1..=9` | Matches a value within a range |
| Enum destructuring | `Shape::Circle(r)` | Extracts data from an enum variant |
| Struct destructuring | `Point { x: 0, y }` | Matches a struct, extracts fields |
| Tuple | `(a, b, c)` | Matches a tuple |
| Guard | `pat if condition` | Additional condition on a pattern |

### 10.3 Примери за съпоставяне / Pattern Matching Examples

**BG:** Пример с Option enum:

```bux
match opt {
    Option::Some(value) => PrintInt(value),
    Option::None => PrintLine("няма стойност")
}
```

Пример с охранител (guard):

```bux
match x {
    n if n < 0 => PrintLine("отрицателно"),
    n if n > 0 => PrintLine("положително"),
    _ => PrintLine("нула")
}
```

**EN:** Example with Option enum:

```bux
match opt {
    Option::Some(value) => PrintInt(value),
    Option::None => PrintLine("no value")
}
```

Example with guard:

```bux
match x {
    n if n < 0 => PrintLine("negative"),
    n if n > 0 => PrintLine("positive"),
    _ => PrintLine("zero")
}
```

---

## Глава 11 / Chapter 11
## Генерични типове / Generics

### 11.1 Генерични функции / Generic Functions

**BG:** Генеричните функции се параметризират с типови променливи в ъглови скоби `<T>`:

```bux
func Max<T>(a: T, b: T) -> T {
    if a > b {
        return a;
    }
    return b;
}
```

Извикването може да бъде с изричен тип или с автоматично извеждане (*type inference*):

```bux
func Main() -> int {
    let m1: int = Max<int>(10, 20);    // Изричен тип
    let m2: int = Max(10, 20);         // Автоматично извеждане: T = int
    return 0;
}
```

Генеричните функции се **мономорфизират** — за всеки конкретен тип се генерира отделна функция по време на компилация. Няма разход по време на изпълнение.

**EN:** Generic functions are parameterized with type variables in angle brackets `<T>`:

```bux
func Max<T>(a: T, b: T) -> T {
    if a > b {
        return a;
    }
    return b;
}
```

Calls may be with explicit type or with automatic type inference:

```bux
func Main() -> int {
    let m1: int = Max<int>(10, 20);    // Explicit type
    let m2: int = Max(10, 20);         // Auto inference: T = int
    return 0;
}
```

Generic functions are **monomorphized** — a separate function is generated for each concrete type at compile time. There is no runtime overhead.

### 11.2 Генерични структури / Generic Structs

**BG:** Структурите също могат да бъдат параметризирани:

```bux
struct Box<T> {
    value: T,
}

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
    PrintInt(b.Get());   // 42
    b.Set(100);
    PrintInt(b.Get());   // 100
    return 0;
}
```

**Важно:** `extend Box<T>` изисква типовите параметри да бъдат указани след името на типа. Те се разпространяват автоматично към всеки метод в блока.

**EN:** Structs can also be parameterized:

```bux
struct Box<T> {
    value: T,
}

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
    PrintInt(b.Get());   // 42
    b.Set(100);
    PrintInt(b.Get());   // 100
    return 0;
}
```

**Important:** `extend Box<T>` requires type parameters to be specified after the type name. They are automatically propagated to each method in the block.

### 11.3 Ограничения на типовите параметри / Type Parameter Bounds

**BG:** Типовите параметри могат да бъдат ограничени чрез интерфейси:

```bux
func Render<T: Drawable>(obj: T) {
    obj.Draw();
}
```

Това гарантира, че типът `T` имплементира интерфейса `Drawable` и методът `Draw()` е наличен.

**EN:** Type parameters can be constrained via interfaces:

```bux
func Render<T: Drawable>(obj: T) {
    obj.Draw();
}
```

This guarantees that type `T` implements the `Drawable` interface and the `Draw()` method is available.

---

## Глава 12 / Chapter 12
## Постепенна собственост / Gradual Ownership

### 12.1 Философия / Philosophy

**BG:** Постепенната собственост (*gradual ownership*) е основната иновация на Bux. Тя позволява на програмиста да избере нивото на безопасност на паметта:

- **По подразбиране (без атрибути):** Пълен C-подобен достъп. Сурови указатели `*T`. Без проверки. Подходящо за прототипиране и производителност-критичен код.
- **С `@[Checked]`:** Активира borrow checker за конкретната функция. `&T` (споделено заемане, само за четене) и `&mut T` (изключително заемане, за четене и запис).

**EN:** Gradual ownership is Bux's primary innovation. It lets the programmer choose the level of memory safety:

- **Default (no attributes):** Full C-like access. Raw pointers `*T`. No checks. Suitable for prototyping and performance-critical code.
- **With `@[Checked]`:** Enables borrow checking for the specific function. `&T` (shared borrow, read-only) and `&mut T` (exclusive borrow, read-write).

### 12.2 Типове указатели / Pointer Types

**BG:**

| Тип / Type | Синтаксис / Syntax | Описание / Description |
|:---|:---|:---|
| Суров указател / Raw pointer | `*T` | C-подобен. Без проверки. Винаги позволен. |
| Споделена референция / Shared reference | `&T` | Заемане само за четене. В `@[Checked]` функции — не позволява мутация. |
| Променлива референция / Mutable reference | `&mut T` | Изключително заемане. Позволява четене и запис. |
| Прехвърляне на собственост / Owned | `own T` | Прехвърляне на собственост (синтаксисът е разпознат, но все още не се налага). |

**EN:**

| Type | Syntax | Description |
|:---|:---|:---|
| Raw pointer | `*T` | C-like. No checks. Always allowed. |
| Shared reference | `&T` | Read-only borrow. In `@[Checked]` functions — disallows mutation. |
| Mutable reference | `&mut T` | Exclusive borrow. Allows reading and writing. |
| Owned | `own T` | Ownership transfer (syntax parsed, not yet enforced). |

### 12.3 Режим по подразбиране / Default Mode

**BG:** В режим по подразбиране Bux работи като C — сурови указатели, без borrow checking:

```bux
func QuickSort(arr: *int, len: int) {
    for i in 0..len {
        arr[i] = arr[i] * 2;   // Напълно позволено
    }
}
```

**EN:** In default mode, Bux works like C — raw pointers, no borrow checking:

```bux
func QuickSort(arr: *int, len: int) {
    for i in 0..len {
        arr[i] = arr[i] * 2;   // Completely allowed
    }
}
```

### 12.4 Режим @[Checked] / @[Checked] Mode

**BG:** С атрибута `@[Checked]` borrow checker-ът проверява правилата за безопасност:

```bux
@[Checked]
func Scale(val: &mut int) {
    *val = *val * 2;    // OK: &mut T позволява мутация
}

@[Checked]
func Read(val: &int) -> int {
    return *val;         // OK: &T позволява четене
}

@[Checked]
func BadWrite(val: &int) {
    *val = 42;           // ГРЕШКА: не може да се пише през &T
}
```

**Правила в @[Checked] функции:**
- `&T` не може да мутира данните (грешка по време на компилация).
- `&mut T` позволява мутация.
- `*T` указателите са неограничени (escape hatch).
- `&mut T` може да се преобразува до `&T` и `*T`.

**EN:** With the `@[Checked]` attribute, the borrow checker enforces safety rules:

```bux
@[Checked]
func Scale(val: &mut int) {
    *val = *val * 2;    // OK: &mut T allows mutation
}

@[Checked]
func Read(val: &int) -> int {
    return *val;         // OK: &T allows reading
}

@[Checked]
func BadWrite(val: &int) {
    *val = 42;           // ERROR: cannot write through &T
}
```

**Rules in @[Checked] functions:**
- `&T` cannot mutate data (compile-time error).
- `&mut T` allows mutation.
- `*T` pointers are unrestricted (escape hatch).
- `&mut T` can be coerced to `&T` and `*T`.

---

## Глава 13 / Chapter 13
## Обработка на грешки / Error Handling

### 13.1 Типове Result и Option / Result and Option Types

**BG:** Bux използва алгебрични enum за обработка на грешки вместо изключения:

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

Това е типово-безопасен подход — компилаторът гарантира, че всеки случай е обработен.

**EN:** Bux uses algebraic enums for error handling instead of exceptions:

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

This is a type-safe approach — the compiler ensures that every case is handled.

### 13.2 Оператор ? (разпространение на грешка) / The ? Operator (Error Propagation)

**BG:** Операторът `?` автоматично разпространява грешки. Ако изразът е `Err` или `None`, текущата функция връща грешката незабавно:

```bux
func Divide(a: int, b: int) -> Result {
    if b == 0 {
        return Result_NewErr("деление на нула");
    }
    return Result_NewOk(a / b);
}

func Compute() -> Result {
    let x: int = Divide(10, 2)?;   // Ако е Err, Compute връща грешката
    let y: int = Divide(x, 5)?;
    return Result_NewOk(y);
}

func Main() -> int {
    match Compute() {
        Result::Ok(val) => PrintInt(val),
        Result::Err(msg) => PrintLine(msg)
    }
    return 0;
}
```

**Важно:** Функцията, използваща `?`, трябва да връща съвместим `Result` или `Option` тип.

**EN:** The `?` operator automatically propagates errors. If the expression is `Err` or `None`, the current function returns the error immediately:

```bux
func Divide(a: int, b: int) -> Result {
    if b == 0 {
        return Result_NewErr("division by zero");
    }
    return Result_NewOk(a / b);
}

func Compute() -> Result {
    let x: int = Divide(10, 2)?;   // If Err, Compute returns the error
    let y: int = Divide(x, 5)?;
    return Result_NewOk(y);
}

func Main() -> int {
    match Compute() {
        Result::Ok(val) => PrintInt(val),
        Result::Err(msg) => PrintLine(msg)
    }
    return 0;
}
```

**Important:** The function using `?` must return a compatible `Result` or `Option` type.

### 13.3 Оператор ! (разопаковане) / The ! Operator (Unwrap)

**BG:** Постфиксният оператор `!` разопакова стойност от `Result`/`Option` или предизвиква паника при грешка. Подходящ е за прототипиране или ситуации, в които грешката е невъзможна:

```bux
let val: int = Divide(10, 2)!;   // Разопакова Ok, паника при Err
```

**EN:** The postfix `!` operator unwraps a value from `Result`/`Option` or panics on error. It is suitable for prototyping or situations where the error is impossible:

```bux
let val: int = Divide(10, 2)!;   // Unwraps Ok, panics on Err
```

---

## Глава 14 / Chapter 14
## Модули, пакети и импорти / Modules, Packages, and Imports

### 14.1 Декларация на модул / Module Declaration

**BG:** Всеки `.bux` файл принадлежи към модул, деклариран в началото на файла:

```bux
module MyModule;

pub func PublicFunc() -> int {    // Публична — достъпна извън модула
    return 42;
}

func PrivateFunc() -> int {       // Частна — достъпна само в модула
    return 0;
}
```

- `pub` прави функцията достъпна за импортиране от други модули.
- Без `pub` функцията е частна за модула.

**EN:** Each `.bux` file belongs to a module declared at the top of the file:

```bux
module MyModule;

pub func PublicFunc() -> int {    // Public — accessible outside the module
    return 42;
}

func PrivateFunc() -> int {       // Private — accessible only within the module
    return 0;
}
```

- `pub` makes the function importable by other modules.
- Without `pub`, the function is private to the module.

### 14.2 Импортиране / Importing

**BG:** Импортирането се извършва с ключовата дума `import`:

```bux
// Единичен импорт
import Std::Io::PrintLine;

// Множествен импорт
import Std::Io::{PrintLine, PrintInt};

// Глобален импорт (всички публични имена)
import Std::Io::*;

// Импорт на цял модул
import Std::Io;
```

**EN:** Importing is done with the `import` keyword:

```bux
// Single import
import Std::Io::PrintLine;

// Multiple import
import Std::Io::{PrintLine, PrintInt};

// Wildcard import (all public names)
import Std::Io::*;

// Import entire module
import Std::Io;
```

### 14.3 Пакети (bux.toml) / Packages (bux.toml)

**BG:** Всеки проект на Bux съдържа манифест файл `bux.toml`:

```toml
[package]
Name = "myproject"
Version = "0.1.0"
Description = "My Bux project"

[dependencies]
# Примерни зависимости
```

Команди за управление на пакети:
```bash
./buxc new myproject    # Създава нов проект
./buxc add somelib      # Добавя зависимост
./buxc install          # Инсталира зависимостите
./buxc build            # Компилира проекта
./buxc run              # Компилира и изпълнява
```

**EN:** Every Bux project contains a manifest file `bux.toml`:

```toml
[package]
Name = "myproject"
Version = "0.1.0"
Description = "My Bux project"

[dependencies]
# Example dependencies
```

Package management commands:
```bash
./buxc new myproject    # Creates a new project
./buxc add somelib      # Adds a dependency
./buxc install          # Installs dependencies
./buxc build            # Compiles the project
./buxc run              # Compiles and runs
```

---

## Глава 15 / Chapter 15
## Стандартна библиотека / The Standard Library

### 15.1 Общ преглед / Overview

**BG:** Стандартната библиотека на Bux съдържа 11 модула, които се сливат във всяка компилация автоматично. Не е необходимо ръчно свързване.

| Модул / Module | Предназначение / Purpose |
|:---|:---|
| `Std::Io` | Вход/изход: печат, четене, файлове |
| `Std::String` | Низове: дължина, сравнение, изрязване, форматиране |
| `Std::StringBuilder` | Ефективно конструиране на низове |
| `Std::Array` | Генеричен динамичен масив `Array<T>` |
| `Std::Map` | Генерична хеш-таблица `Map<K,V>` |
| `Std::Set` | Генерично хеш-множество `Set<T>` |
| `Std::Mem` | Управление на паметта: алокация, освобождаване |
| `Std::Math` | Математически функции |
| `Std::Path` | Манипулация на файлови пътища |
| `Std::Fs` | Файлова система: директории |
| `Std::Task` / `Std::Channel` | Многонишковост (POSIX threads) |

**EN:** The Bux standard library contains 11 modules that are merged into every compilation automatically. No manual linking is required.

| Module | Purpose |
|:---|:---|
| `Std::Io` | Input/output: print, read, files |
| `Std::String` | Strings: length, comparison, slicing, formatting |
| `Std::StringBuilder` | Efficient string construction |
| `Std::Array` | Generic dynamic array `Array<T>` |
| `Std::Map` | Generic hash map `Map<K,V>` |
| `Std::Set` | Generic hash set `Set<T>` |
| `Std::Mem` | Memory management: allocation, deallocation |
| `Std::Math` | Mathematical functions |
| `Std::Path` | File path manipulation |
| `Std::Fs` | File system: directories |
| `Std::Task` / `Std::Channel` | Multithreading (POSIX threads) |

### 15.2 Std::Io — Вход/Изход / Input/Output

**BG:**

```bux
import Std::Io::{PrintLine, PrintInt, PrintFloat, PrintBool, ReadLine, ReadFile, WriteFile, FileExists};

func Main() -> int {
    PrintLine("Текст с нов ред");
    Print("Текст без нов ред");
    PrintInt(42);
    PrintFloat(3.14);
    PrintBool(true);

    let line: String = ReadLine();                          // Чете ред от stdin
    let content: String = ReadFile("/path/to/file.txt");    // Чете цял файл
    let ok: bool = WriteFile("/tmp/test.txt", "съдържание"); // Записва файл
    let exists: bool = FileExists("/tmp/test.txt");         // Проверява съществуване

    return 0;
}
```

**EN:**

```bux
import Std::Io::{PrintLine, PrintInt, PrintFloat, PrintBool, ReadLine, ReadFile, WriteFile, FileExists};

func Main() -> int {
    PrintLine("Text with newline");
    Print("Text without newline");
    PrintInt(42);
    PrintFloat(3.14);
    PrintBool(true);

    let line: String = ReadLine();                          // Reads a line from stdin
    let content: String = ReadFile("/path/to/file.txt");    // Reads entire file
    let ok: bool = WriteFile("/tmp/test.txt", "content");   // Writes file
    let exists: bool = FileExists("/tmp/test.txt");         // Checks existence

    return 0;
}
```

### 15.3 Std::Array — Динамичен масив / Dynamic Array

**BG:**

```bux
import Std::Array::{Array, Array_New, Array_Push, Array_Get, Array_Len, Array_Free};

func Main() -> int {
    let arr: Array<int> = Array_New<int>(4);    // Капацитет 4
    Array_Push<int>(&arr, 10);
    Array_Push<int>(&arr, 20);
    Array_Push<int>(&arr, 30);

    let len: uint = Array_Len<int>(&arr);        // 3
    let val: int = Array_Get<int>(&arr, 0);     // 10

    for i in 0..(len as int) {
        PrintInt(Array_Get<int>(&arr, i as uint));
    }

    Array_Free<int>(&arr);
    return 0;
}
```

**EN:**

```bux
import Std::Array::{Array, Array_New, Array_Push, Array_Get, Array_Len, Array_Free};

func Main() -> int {
    let arr: Array<int> = Array_New<int>(4);    // Capacity 4
    Array_Push<int>(&arr, 10);
    Array_Push<int>(&arr, 20);
    Array_Push<int>(&arr, 30);

    let len: uint = Array_Len<int>(&arr);        // 3
    let val: int = Array_Get<int>(&arr, 0);     // 10

    for i in 0..(len as int) {
        PrintInt(Array_Get<int>(&arr, i as uint));
    }

    Array_Free<int>(&arr);
    return 0;
}
```

### 15.4 Std::Map — Хеш-таблица / Hash Map

**BG:**

```bux
import Std::Map::{Map, Map_New, Map_Set, Map_Get, Map_Has, Map_Len, Map_Free};

func Main() -> int {
    let m: Map<int, String> = Map_New<int, String>(16);
    Map_Set<int, String>(&m, 1, "едно");
    Map_Set<int, String>(&m, 2, "две");

    if Map_Has<int, String>(&m, 1) {
        PrintLine(Map_Get<int, String>(&m, 1));   // "едно"
    }

    Map_Free<int, String>(&m);
    return 0;
}
```

За низови ключове се използва `StringMap<V>`.

**EN:**

```bux
import Std::Map::{Map, Map_New, Map_Set, Map_Get, Map_Has, Map_Len, Map_Free};

func Main() -> int {
    let m: Map<int, String> = Map_New<int, String>(16);
    Map_Set<int, String>(&m, 1, "one");
    Map_Set<int, String>(&m, 2, "two");

    if Map_Has<int, String>(&m, 1) {
        PrintLine(Map_Get<int, String>(&m, 1));   // "one"
    }

    Map_Free<int, String>(&m);
    return 0;
}
```

For string keys, use `StringMap<V>`.

### 15.5 Std::Math — Математика / Mathematics

**BG:**

| Функция / Function | Сигнатура / Signature | Описание / Description |
|:---|:---|:---|
| `Sqrt` | `func Sqrt(x: float64) -> float64` | Квадратен корен / Square root |
| `Pow` | `func Pow(base: float64, exp: float64) -> float64` | Степенуване / Power |
| `Abs` | `func Abs(x: int) -> int` | Абсолютна стойност (цели числа) / Absolute (int) |
| `AbsF` | `func AbsF(x: float64) -> float64` | Абсолютна стойност (дробни) / Absolute (float) |
| `Min` | `func Min(a: int, b: int) -> int` | Минимум / Minimum |
| `Max` | `func Max(a: int, b: int) -> int` | Максимум / Maximum |
| `MinF` | `func MinF(a: float64, b: float64) -> float64` | Минимум (float) / Min (float) |
| `MaxF` | `func MaxF(a: float64, b: float64) -> float64` | Максимум (float) / Max (float) |

**EN:** (see table above)

### 15.6 Std::String — Манипулация на низове / String Manipulation

**BG:** Пълен набор от функции за работа с низове:

| Функция / Function | Описание / Description |
|:---|:---|
| `String_Len(s)` | Дължина на низа |
| `String_Eq(a, b)` | Сравнение на низове |
| `String_Concat(a, b)` | Конкатенация (заделя памет) |
| `String_Copy(s)` | Копиране (заделя памет) |
| `String_Slice(s, start, len)` | Извлича подниз |
| `String_Contains(s, substr)` | Проверява дали съдържа подниз |
| `String_StartsWith(s, prefix)` | Проверява префикс |
| `String_EndsWith(s, suffix)` | Проверява суфикс |
| `String_Trim(s)` | Премахва интервали от двете страни |
| `String_SplitPart(s, delim, index)` | Връща n-та част при разделяне |
| `String_Replace(s, old, new)` | Заменя първо срещане |
| `String_FromInt(n)` | Цяло число → низ |
| `String_ToInt(s)` | Низ → цяло число |
| `String_Format2("{0} + {1}", a, b)` | Форматиране с 2 аргумента |

**EN:** Full set of string manipulation functions:

| Function | Description |
|:---|:---|
| `String_Len(s)` | String length |
| `String_Eq(a, b)` | String comparison |
| `String_Concat(a, b)` | Concatenation (allocates) |
| `String_Copy(s)` | Copy (allocates) |
| `String_Slice(s, start, len)` | Extract substring |
| `String_Contains(s, substr)` | Check if contains substring |
| `String_StartsWith(s, prefix)` | Check prefix |
| `String_EndsWith(s, suffix)` | Check suffix |
| `String_Trim(s)` | Trim whitespace from both sides |
| `String_SplitPart(s, delim, index)` | Return nth part when splitting |
| `String_Replace(s, old, new)` | Replace first occurrence |
| `String_FromInt(n)` | Integer → string |
| `String_ToInt(s)` | String → integer |
| `String_Format2("{0} + {1}", a, b)` | Format with 2 arguments |

---

## Глава 16 / Chapter 16
## Изпълнение по време на компилация (CTFE) / Compile-Time Function Execution

### 16.1 Концепция / Concept

**BG:** Bux позволява изпълнението на функции по време на компилация чрез ключовата дума `const func`. Това дава възможност за предварително изчисляване на константи, размери на масиви и метапрограмиране без външни инструменти.

**EN:** Bux allows functions to be executed at compile time via the `const func` keyword. This enables precomputation of constants, array sizes, and metaprogramming without external tools.

### 16.2 Синтаксис и пример / Syntax and Example

**BG:**

```bux
const func Factorial(n: int) -> int {
    if n <= 1 {
        return 1;
    }
    return n * Factorial(n - 1);       // Рекурсията е позволена!
}

const TABLE_SIZE = Factorial(10);       // 3 628 800 — изчислено при компилация

func Main() -> int {
    let arr: [TABLE_SIZE]int;           // Размер на масив от константа
    PrintInt(TABLE_SIZE);
    return 0;
}
```

**EN:**

```bux
const func Factorial(n: int) -> int {
    if n <= 1 {
        return 1;
    }
    return n * Factorial(n - 1);       // Recursion is allowed!
}

const TABLE_SIZE = Factorial(10);       // 3,628,800 — computed at compile time

func Main() -> int {
    let arr: [TABLE_SIZE]int;           // Array size from constant
    PrintInt(TABLE_SIZE);
    return 0;
}
```

### 16.3 Поддържани конструкции / Supported Constructs

**BG:** В CTFE функциите са позволени:
- Целочислени, булеви и низови литерали
- Аритметични операции (`+`, `-`, `*`, `/`, `%`)
- Операции за сравнение и логически операции
- Условни конструкции `if`/`else`
- Извиквания към други `const func` функции
- Рекурсия

**Не са позволени:**
- Цикли `while`/`for` (използвайте рекурсия)
- Променливи референции или алокация на памет
- Извиквания към не-`const` функции

**EN:** CTFE functions support:
- Integer, boolean, and string literals
- Arithmetic operations (`+`, `-`, `*`, `/`, `%`)
- Comparison and logical operations
- `if`/`else` conditionals
- Calls to other `const func` functions
- Recursion

**Not supported:**
- `while`/`for` loops (use recursion)
- Mutable references or heap allocation
- Calls to non-`const` functions

### 16.4 Вградени CTFE променливи / Built-in CTFE Variables

**BG:** Bux предоставя вградени променливи, достъпни по време на компилация:

| Променлива / Variable | Стойност / Value |
|:---|:---|
| `#line` | Текущ ред в изходния код |
| `#column` | Текуща колона |
| `#file` | Име на файла |
| `#function` | Име на текущата функция |
| `#date` | Дата на компилация |
| `#time` | Час на компилация |
| `#module` | Име на текущия модул |

**EN:** Bux provides built-in variables available at compile time:

| Variable | Value |
|:---|:---|
| `#line` | Current source line |
| `#column` | Current column |
| `#file` | File name |
| `#function` | Current function name |
| `#date` | Compilation date |
| `#time` | Compilation time |
| `#module` | Current module name |

---

## Глава 17 / Chapter 17
## Асинхронно програмиране / Asynchronous Programming

### 17.1 Концепция / Concept

**BG:** Bux поддържа стекови корутини (*stackful coroutines*) чрез ключовите думи `async`/`await` с round-robin планировчик. Това позволява кооперативна многозадачност без обратни извиквания (*callbacks*).

**EN:** Bux supports stackful coroutines via the `async`/`await` keywords with a round-robin scheduler. This enables cooperative multitasking without callbacks.

### 17.2 Дефиниция на асинхронна функция / Async Function Definition

**BG:**

```bux
async func Compute() -> int {
    PrintLine("стъпка 1");
    bux_async_yield();              // Отстъпва контрол на планировчика
    PrintLine("стъпка 2");
    return 42;
}
```

**EN:**

```bux
async func Compute() -> int {
    PrintLine("step 1");
    bux_async_yield();              // Yields control to the scheduler
    PrintLine("step 2");
    return 42;
}
```

### 17.3 Стартиране и изчакване / Spawning and Awaiting

**BG:**

```bux
func Main() -> int {
    let h = spawn Compute();        // Стартира корутина
    let r: int = h.await as int;    // Изчаква завършване и получава резултат
    PrintInt(r);                    // 42
    return 0;
}
```

- `spawn` — стартира асинхронна функция и връща handle.
- `.await` — блокира до завършване на корутината и връща резултата.
- `as Type` — указва типа на резултата.

**EN:**

```bux
func Main() -> int {
    let h = spawn Compute();        // Starts coroutine
    let r: int = h.await as int;    // Awaits completion and gets result
    PrintInt(r);                    // 42
    return 0;
}
```

- `spawn` — starts an async function and returns a handle.
- `.await` — blocks until coroutine completion and returns the result.
- `as Type` — specifies the result type.

### 17.4 Функции на изпълнителната среда / Runtime Functions

**BG:**

| Функция / Function | Описание / Description |
|:---|:---|
| `bux_async_yield()` | Отстъпва контрол на планировчика |
| `bux_async_spawn(fn)` | Създава нова корутина |
| `bux_async_await(handle)` | Изчаква завършване на корутина |
| `bux_async_run()` | Стартира планировчика (извиква се неявно от Main) |
| `bux_async_sleep(ms)` | Неблокиращо изчакване в милисекунди |
| `bux_async_return(value, size)` | Копира резултат в буфера на задачата |

**EN:**

| Function | Description |
|:---|:---|
| `bux_async_yield()` | Yields control to the scheduler |
| `bux_async_spawn(fn)` | Creates a new coroutine |
| `bux_async_await(handle)` | Awaits coroutine completion |
| `bux_async_run()` | Runs the scheduler (called implicitly from Main) |
| `bux_async_sleep(ms)` | Non-blocking sleep in milliseconds |
| `bux_async_return(value, size)` | Copies result into task buffer |

---

## Глава 18 / Chapter 18
## Инструментариум и работен процес / Toolchain and Workflow

### 18.1 Команди на buxc / buxc Commands

**BG:**

| Команда / Command | Описание / Description |
|:---|:---|
| `buxc new <name>` | Създава нов проект с шаблон |
| `buxc build [path]` | Компилира проекта до нативен изпълним файл |
| `buxc run [path]` | Компилира и изпълнява проекта |
| `buxc check [file]` | Проверява типовете без да компилира |
| `buxc clean` | Изтрива артефактите от компилацията |
| `buxc version` | Показва версията на компилатора |
| `buxc add <name>` | Добавя зависимост към проекта |
| `buxc install` | Разрешава зависимостите и генерира lockfile |

**EN:**

| Command | Description |
|:---|:---|
| `buxc new <name>` | Creates a new project from template |
| `buxc build [path]` | Compiles the project to a native executable |
| `buxc run [path]` | Compiles and runs the project |
| `buxc check [file]` | Type-checks without compiling |
| `buxc clean` | Removes build artifacts |
| `buxc version` | Shows compiler version |
| `buxc add <name>` | Adds a dependency to the project |
| `buxc install` | Resolves dependencies and generates lockfile |

### 18.2 Структура на проект / Project Structure

**BG:**

```
myproject/
├── bux.toml            # Манифест на пакета
├── bux.lock            # Фиксирани версии на зависимостите
├── src/
│   └── main.bux        # Входна точка на програмата
└── build/              # Артефакти от компилацията
```

**EN:**

```
myproject/
├── bux.toml            # Package manifest
├── bux.lock            # Locked dependency versions
├── src/
│   └── main.bux        # Program entry point
└── build/              # Build artifacts
```

### 18.3 Компилационен процес / Compilation Process

**BG:** Bux компилаторът следва следния процес:

1. **Лексиране (Lexing)** — Изходният код се разделя на токени.
2. **Парсиране (Parsing)** — Токените се преобразуват в AST (абстрактно синтактично дърво).
3. **Семантичен анализ (Sema)** — Проверка на типовете, области на видимост.
4. **HIR lowering** — AST се преобразува в HIR (high-level intermediate representation).
5. **Генериране на C код (C backend)** — HIR се транслира до C код.
6. **Компилация с GCC/Clang** — Генерираният C код се компилира до нативен машинен код.

**EN:** The Bux compiler follows this process:

1. **Lexing** — Source code is split into tokens.
2. **Parsing** — Tokens are converted into an AST (abstract syntax tree).
3. **Semantic analysis (Sema)** — Type checking, scoping.
4. **HIR lowering** — AST is converted to HIR (high-level intermediate representation).
5. **C code generation (C backend)** — HIR is translated to C code.
6. **GCC/Clang compilation** — The generated C code is compiled to native machine code.

---

## Глава 19 / Chapter 19
## Интероперативност с C / C Interoperability

### 19.1 Извикване на C функции / Calling C Functions

**BG:** Bux предлага директна C интероперативност чрез `extern func`:

```bux
extern func printf(fmt: *char8, ...);
extern func malloc(size: uint) -> *void;
extern func free(ptr: *void);
extern func strlen(s: *char8) -> uint;
```

**EN:** Bux offers direct C interoperability via `extern func`:

```bux
extern func printf(fmt: *char8, ...);
extern func malloc(size: uint) -> *void;
extern func free(ptr: *void);
extern func strlen(s: *char8) -> uint;
```

### 19.2 C типове низове / C String Types

**BG:** Bux поддържа специални низови литерали за C-съвместими низове:

```bux
let s: *char8 = c8"Hello, C world!";
```

**EN:** Bux supports special string literals for C-compatible strings:

```bux
let s: *char8 = c8"Hello, C world!";
```

### 19.3 Генериране на C код / C Code Generation

**BG:** Bux компилаторът генерира C код от HIR. Програмистът може да инспектира генерирания C код за дебъгване или за интеграция със съществуващи C проекти.

C бекендът е основният метод за компилация и осигурява:
- Преносимост между платформи (навсякъде, където работи GCC/Clang)
- Възползване от 30+ години C компилаторни оптимизации
- Лесна интеграция със съществуващ C код

**EN:** The Bux compiler generates C code from HIR. The programmer can inspect the generated C code for debugging or for integration with existing C projects.

The C backend is the primary compilation method and provides:
- Cross-platform portability (anywhere GCC/Clang works)
- Leveraging 30+ years of C compiler optimizations
- Easy integration with existing C code

---

## Приложение A / Appendix A
## Справочник на вградените типове / Built-in Types Reference

| Тип / Type | Категория / Category | Размер / Size | Описание / Description |
|:---|:---|:---|:---|
| `int8` | Знаков целочислен | 1 байт | -128 до 127 |
| `int16` | Знаков целочислен | 2 байта | -32 768 до 32 767 |
| `int32` | Знаков целочислен | 4 байта | ≈ -2.1×10⁹ до 2.1×10⁹ |
| `int64` | Знаков целочислен | 8 байта | ≈ -9.2×10¹⁸ до 9.2×10¹⁸ |
| `int` | Знаков целочислен | 4/8 байта | Архитектурно-зависим |
| `uint8` | Беззнаков целочислен | 1 байт | 0 до 255 |
| `uint16` | Беззнаков целочислен | 2 байта | 0 до 65 535 |
| `uint32` | Беззнаков целочислен | 4 байта | 0 до ≈ 4.3×10⁹ |
| `uint64` | Беззнаков целочислен | 8 байта | 0 до ≈ 1.8×10¹⁹ |
| `uint` | Беззнаков целочислен | 4/8 байта | Архитектурно-зависим |
| `float32` | Плаваща запетая | 4 байта | IEEE 754 единична точност |
| `float64` | Плаваща запетая | 8 байта | IEEE 754 двойна точност |
| `bool` | Булев | 1 байт | `true` или `false` |
| `char8` | Символ | 1 байт | 8-битов символ |
| `char16` | Символ | 2 байта | 16-битов символ (UTF-16) |
| `char32` | Символ | 4 байта | 32-битов символ (UTF-32) |
| `String` | Низ | sizeof(ptr) | C-съвместим низ (`const char*`) |
| `*T` | Указател | sizeof(ptr) | Суров указател към T |
| `&T` | Референция | sizeof(ptr) | Споделена референция |
| `&mut T` | Променлива референция | sizeof(ptr) | Изключителна референция |
| `T[]` | Срез | 2 × sizeof(ptr) | Непълен масив |
| `T[N]` | Масив | N × sizeof(T) | Масив с фиксиран размер |

---

## Приложение B / Appendix B
## Справочник на операторите / Operator Reference

| Приоритет / Prec. | Оператор / Operator | Асоциативност / Assoc. | Описание / Description |
|:---:|:---|:---:|:---|
| 1 | `a.b`, `a::b` | Лява / Left | Достъп до поле / път |
| 1 | `a[b]` | Лява / Left | Индексиране |
| 1 | `f(args)` | Лява / Left | Извикване на функция |
| 1 | `a?`, `a!` | Лява / Left | Разпространение / разопаковане |
| 2 | `-a`, `!a`, `~a`, `*a`, `&a` | Дясна / Right | Унарни оператори |
| 2 | `a as Type`, `a is Type` | Лява / Left | Преобразуване / проверка |
| 2 | `sizeof(Type)` | — | Размер на тип |
| 3 | `a ** b` | Дясна / Right | Степенуване |
| 4 | `a * b`, `a / b`, `a % b` | Лява / Left | Умножение, деление, остатък |
| 5 | `a + b`, `a - b` | Лява / Left | Събиране, изваждане |
| 6 | `a << b`, `a >> b` | Лява / Left | Побитово отместване |
| 7 | `a & b` | Лява / Left | Побитово И |
| 8 | `a ^ b` | Лява / Left | Побитово XOR |
| 9 | `a \| b` | Лява / Left | Побитово ИЛИ |
| 10 | `a..b`, `a..=b` | — | Интервал |
| 11 | `a == b`, `a != b`, `a < b`, `a <= b`, `a > b`, `a >= b` | Лява / Left | Сравнение |
| 12 | `a && b` | Лява / Left | Логическо И |
| 13 | `a \|\| b` | Лява / Left | Логическо ИЛИ |
| 14 | `=`, `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `\|=`, `^=`, `<<=`, `>>=` | Дясна / Right | Присвояване |

---

## Приложение C / Appendix C
## Пълен справочник на стандартната библиотека / Standard Library Full Reference

### Std::Io

| Функция | Сигнатура | Описание |
|:---|:---|:---|
| `PrintLine` | `func PrintLine(s: String)` | Печат с нов ред |
| `Print` | `func Print(s: String)` | Печат без нов ред |
| `PrintInt` | `func PrintInt(n: int)` | Печат на цяло число |
| `PrintFloat` | `func PrintFloat(f: float64)` | Печат на дробно число |
| `PrintBool` | `func PrintBool(b: bool)` | Печат на булева стойност |
| `ReadLine` | `func ReadLine() -> String` | Четене на ред от stdin |
| `ReadFile` | `func ReadFile(path: String) -> String` | Четене на цял файл |
| `WriteFile` | `func WriteFile(path: String, content: String) -> bool` | Запис на файл |
| `FileExists` | `func FileExists(path: String) -> bool` | Проверка за съществуване |

### Std::String

| Функция | Сигнатура | Описание |
|:---|:---|:---|
| `String_Len` | `func String_Len(s: String) -> uint` | Дължина |
| `String_Eq` | `func String_Eq(a: String, b: String) -> bool` | Равенство |
| `String_Concat` | `func String_Concat(a: String, b: String) -> String` | Конкатенация |
| `String_Copy` | `func String_Copy(s: String) -> String` | Копиране |
| `String_Slice` | `func String_Slice(s: String, start: uint, len: uint) -> String` | Подниз |
| `String_Contains` | `func String_Contains(s: String, substr: String) -> bool` | Съдържа |
| `String_StartsWith` | `func String_StartsWith(s: String, prefix: String) -> bool` | Започва с |
| `String_EndsWith` | `func String_EndsWith(s: String, suffix: String) -> bool` | Завършва с |
| `String_Trim` | `func String_Trim(s: String) -> String` | Изрязване |
| `String_TrimLeft` | `func String_TrimLeft(s: String) -> String` | Ляво изрязване |
| `String_TrimRight` | `func String_TrimRight(s: String) -> String` | Дясно изрязване |
| `String_SplitCount` | `func String_SplitCount(s: String, delim: String) -> uint` | Брой части |
| `String_SplitPart` | `func String_SplitPart(s: String, delim: String, index: uint) -> String` | N-та част |
| `String_Join2` | `func String_Join2(a: String, b: String, sep: String) -> String` | Съединяване |
| `String_Find` | `func String_Find(haystack: String, needle: String) -> String` | Търсене |
| `String_Replace` | `func String_Replace(s: String, old: String, new: String) -> String` | Замяна |
| `String_FromInt` | `func String_FromInt(n: int64) -> String` | Число → низ |
| `String_ToInt` | `func String_ToInt(s: String) -> int64` | Низ → число |
| `String_Format1` | `func String_Format1(pattern: String, a0: String) -> String` | Формат (1 арг.) |
| `String_Format2` | `func String_Format2(pattern: String, a0: String, a1: String) -> String` | Формат (2 арг.) |
| `String_Format3` | `func String_Format3(pattern: String, a0: String, a1: String, a2: String) -> String` | Формат (3 арг.) |

### Std::StringBuilder

| Функция | Сигнатура | Описание |
|:---|:---|:---|
| `StringBuilder_New` | `func StringBuilder_New() -> StringBuilder` | Създаване |
| `StringBuilder_NewCap` | `func StringBuilder_NewCap(cap: uint) -> StringBuilder` | С капацитет |
| `StringBuilder_Append` | `func StringBuilder_Append(sb: *StringBuilder, s: String)` | Добавяне на низ |
| `StringBuilder_AppendInt` | `func StringBuilder_AppendInt(sb: *StringBuilder, n: int64)` | Добавяне на число |
| `StringBuilder_AppendFloat` | `func StringBuilder_AppendFloat(sb: *StringBuilder, f: float64)` | Добавяне на float |
| `StringBuilder_AppendChar` | `func StringBuilder_AppendChar(sb: *StringBuilder, c: char8)` | Добавяне на символ |
| `StringBuilder_Build` | `func StringBuilder_Build(sb: *StringBuilder) -> String` | Краен резултат |
| `StringBuilder_Free` | `func StringBuilder_Free(sb: *StringBuilder)` | Освобождаване |

### Std::Array

| Функция | Сигнатура | Описание |
|:---|:---|:---|
| `Array_New<T>` | `func Array_New<T>(cap: uint) -> Array<T>` | Създаване |
| `Array_Push<T>` | `func Array_Push<T>(arr: *Array<T>, value: T)` | Добавяне |
| `Array_Get<T>` | `func Array_Get<T>(arr: *Array<T>, index: uint) -> T` | Достъп |
| `Array_Len<T>` | `func Array_Len<T>(arr: *Array<T>) -> uint` | Дължина |
| `Array_Free<T>` | `func Array_Free<T>(arr: *Array<T>)` | Освобождаване |

### Std::Map

| Функция | Сигнатура | Описание |
|:---|:---|:---|
| `Map_New<K,V>` | `func Map_New<K,V>(cap: uint) -> Map<K,V>` | Създаване |
| `Map_Set<K,V>` | `func Map_Set<K,V>(m: *Map<K,V>, key: K, value: V)` | Вмъкване |
| `Map_Get<K,V>` | `func Map_Get<K,V>(m: *Map<K,V>, key: K) -> V` | Достъп |
| `Map_Has<K,V>` | `func Map_Has<K,V>(m: *Map<K,V>, key: K) -> bool` | Проверка |
| `Map_Len<K,V>` | `func Map_Len<K,V>(m: *Map<K,V>) -> uint` | Брой |
| `Map_Free<K,V>` | `func Map_Free<K,V>(m: *Map<K,V>)` | Освобождаване |

### Std::Set

| Функция | Сигнатура | Описание |
|:---|:---|:---|
| `Set_New<T>` | `func Set_New<T>(cap: uint) -> Set<T>` | Създаване |
| `Set_Add<T>` | `func Set_Add<T>(s: *Set<T>, value: T)` | Добавяне |
| `Set_Has<T>` | `func Set_Has<T>(s: *Set<T>, value: T) -> bool` | Проверка |
| `Set_Len<T>` | `func Set_Len<T>(s: *Set<T>) -> uint` | Брой |
| `Set_Free<T>` | `func Set_Free<T>(s: *Set<T>)` | Освобождаване |

### Std::Mem

| Функция | Сигнатура | Описание |
|:---|:---|:---|
| `Alloc` | `func Alloc(size: uint) -> *void` | Заделя памет |
| `Realloc` | `func Realloc(ptr: *void, size: uint) -> *void` | Презаделя |
| `Free` | `func Free(ptr: *void)` | Освобождава |
| `MemEq` | `func MemEq(a: *void, b: *void, size: uint) -> bool` | Сравнение байт по байт |
| `New<T>` | `func New<T>() -> *T` | Типизирана алокация |

### Std::Math

| Функция | Сигнатура | Описание |
|:---|:---|:---|
| `Sqrt` | `func Sqrt(x: float64) -> float64` | Корен квадратен |
| `Pow` | `func Pow(base: float64, exp: float64) -> float64` | Степен |
| `Abs` | `func Abs(x: int) -> int` | Абсолютна стойност |
| `AbsF` | `func AbsF(x: float64) -> float64` | Абсолютна стойност (float) |
| `Min` | `func Min(a: int, b: int) -> int` | Минимум |
| `Max` | `func Max(a: int, b: int) -> int` | Максимум |
| `MinF` | `func MinF(a: float64, b: float64) -> float64` | Минимум (float) |
| `MaxF` | `func MaxF(a: float64, b: float64) -> float64` | Максимум (float) |

### Std::Path

| Функция | Сигнатура | Описание |
|:---|:---|:---|
| `Path_Join` | `func Path_Join(a: String, b: String) -> String` | Съединява пътища |
| `Path_Parent` | `func Path_Parent(path: String) -> String` | Родителска директория |
| `Path_Ext` | `func Path_Ext(path: String) -> String` | Файлово разширение |

### Std::Fs

| Функция | Сигнатура | Описание |
|:---|:---|:---|
| `DirExists` | `func DirExists(path: String) -> bool` | Проверка за директория |
| `Mkdir` | `func Mkdir(path: String) -> bool` | Създава директория |
| `ListDir` | `func ListDir(dir: String, ext: String, count: *int) -> *String` | Списък с файлове |

### Std::Task / Std::Channel

| Функция | Сигнатура | Описание |
|:---|:---|:---|
| `Task_Spawn` | `func Task_Spawn(fn: *void) -> TaskHandle` | Стартира нишка |
| `Task_Join` | `func Task_Join(handle: *TaskHandle) -> *void` | Изчаква нишка |
| `Channel_New<T>` | `func Channel_New<T>(cap: uint) -> Channel<T>` | Създава канал |
| `Channel_Send<T>` | `func Channel_Send<T>(ch: *Channel<T>, value: T)` | Изпраща |
| `Channel_Recv<T>` | `func Channel_Recv<T>(ch: *Channel<T>) -> T` | Получава |
| `Channel_Close<T>` | `func Channel_Close<T>(ch: *Channel<T>)` | Затваря |
| `Channel_Free<T>` | `func Channel_Free<T>(ch: *Channel<T>)` | Освобождава |

---

## Приложение D / Appendix D
## Ключови думи / Reserved Keywords

```
func        let         var         const       type
struct      enum        union       interface   extend
module      import      pub         extern      if
else        while       do          loop        for
in          break       continue    return      match
as          is          null        self        super
sizeof      async       await       spawn
```

---

## Приложение E / Appendix E
## Атрибути на компилатора / Compiler Attributes

| Атрибут / Attribute | Прилага се върху / Applies to | Описание / Description |
|:---|:---|:---|
| `@[Checked]` | Функция | Активира borrow checker за функцията |
| `const func` | Функция | Функцията се изпълнява по време на компилация |
| `async func` | Функция | Функцията е асинхронна корутина |
| `extern func` | Функция | Функцията е дефинирана в C код |

---

## Индекс / Index

### Азбучен индекс (български)

**А**
- Абсолютна стойност (Abs), Прил. C
- Алгебрични изброими типове, Гл. 9.2
- Аритметични оператори, Гл. 4.1
- Асинхронни функции, Гл. 17.2
- Атрибути, Прил. E

**Б**
- break (оператор), Гл. 5.4, 5.6
- bux.toml, Гл. 14.3

**В**
- Вход/изход (Std::Io), Гл. 15.2
- Външни функции (extern), Гл. 6.4

**Г**
- Генерични структури, Гл. 11.2
- Генерични функции, Гл. 11.1, 8.3
- Главна функция (Main), Гл. 6.2

**Д**
- Декларация на променливи, Гл. 3.1
- Динамичен масив (Array), Гл. 15.3
- do/while, Гл. 5.3

**Е**
- Етикетиран break/continue, Гл. 5.6

**З**
- Запазени думи, Гл. 2.3, Прил. D

**И**
- Изброими типове (Enums), Гл. 9
- Изрази, Гл. 4
- Импортиране, Гл. 14.2
- Интервали (.. и ..=), Гл. 5.5, 4.6
- Интерфейси, Гл. 8.1
- Инсталация, Гл. 1.4

**К**
- Ключови думи, Гл. 2.3, Прил. D
- Коментари, Гл. 2.1
- Компилационен процес, Гл. 18.3
- Константи (const), Гл. 3.1
- Кортежи (Tuples), Гл. 3.3

**Л**
- Лексикална структура, Гл. 2
- Логически оператори, Гл. 4.3

**М**
- Масиви (T[N]), Гл. 3.3
- Математика (Math), Гл. 15.5
- Методи (extend), Гл. 7.3
- Модули, Гл. 14.1
- Мономорфизация, Гл. 11.1

**Н**
- Низове (String), Гл. 3.2, 15.6
- Низови литерали, Гл. 2.4

**О**
- Обработка на грешки, Гл. 13
- Образци (patterns), Гл. 10.2
- Оператори, Гл. 4, Прил. B
- Охранител (guard), Гл. 10.3

**П**
- Пакети, Гл. 14.3
- Побитови оператори, Гл. 4.4
- Постепенна собственост, Гл. 12
- Предварителна декларация (forward), Гл. 6.3
- Преобразуване (as), Гл. 4.6
- Променливи (var), Гл. 3.1

**Р**
- Разопаковане (!), Гл. 13.3
- Разпространение на грешка (?), Гл. 13.2
- Рекурсия, Гл. 16.2

**С**
- Сравнение (оператори), Гл. 4.2
- Стандартна библиотека, Гл. 15, Прил. C
- Структури (Structs), Гл. 7
- Съпоставяне на образци (match), Гл. 10

**Т**
- Типове данни, Гл. 3.2–3.3, Прил. A
- Типови ограничения, Гл. 11.3

**У**
- Указатели (*T), Гл. 12.2
- Условен оператор (if/else), Гл. 5.1

**Ф**
- Функции, Гл. 6
- Функционален тип, Гл. 3.3

**Х**
- Хеш-таблица (Map), Гл. 15.4

**Ц**
- Цикли, Гл. 5.2–5.6

**Ч**
- Числови литерали, Гл. 2.5

**C**
- CTFE, Гл. 16
- C интероперативност, Гл. 19

---

### Alphabetical Index (English)

**A**
- Algebraic enums, Ch. 9.2
- Arithmetic operators, Ch. 4.1
- Array (dynamic), Ch. 15.3
- Assignment operators, Ch. 4.5
- Async/await, Ch. 17
- Attributes (compiler), App. E

**B**
- Bitwise operators, Ch. 4.4
- Blocks and scope, Ch. 3.4
- Boolean type (bool), Ch. 3.2
- Borrow checker, Ch. 12.4
- break/continue, Ch. 5.4, 5.6
- Built-in types, Ch. 3.2, App. A

**C**
- C backend, Ch. 18.3, 19.3
- C interoperability, Ch. 19
- C string types, Ch. 2.4, 19.2
- Cast (as), Ch. 4.6
- Character types (char8/16/32), Ch. 3.2
- Command-line tool (buxc), Ch. 18.1
- Comments, Ch. 2.1
- Comparison operators, Ch. 4.2
- Compile-time execution (CTFE), Ch. 16
- Composite types, Ch. 3.3
- Constants (const), Ch. 3.1, 16.2
- Control flow, Ch. 5

**D**
- Data types, Ch. 3, App. A
- do/while loop, Ch. 5.3

**E**
- Enums, Ch. 9
- Error handling, Ch. 13
- Error propagation (?), Ch. 13.2
- Exclusive range (..=), Ch. 4.6, 5.5
- Exponentiation (**), Ch. 4.1
- Extend blocks, Ch. 7.3
- External functions (extern), Ch. 6.4

**F**
- Floating-point types, Ch. 3.2
- for loop, Ch. 5.5
- Forward declaration, Ch. 6.3
- Functions, Ch. 6
- Function type, Ch. 3.3

**G**
- Generics, Ch. 11
- Gradual ownership, Ch. 12
- Guard (match), Ch. 10.3

**H**
- Hash map (Map), Ch. 15.4
- Hash set (Set), Ch. 15.6

**I**
- Identifiers, Ch. 2.2
- if/else, Ch. 5.1
- Imports, Ch. 14.2
- Inclusive range (..=), Ch. 4.6, 5.5
- Installation, Ch. 1.4
- Integer types, Ch. 3.2
- Interfaces, Ch. 8.1
- Interface implementation, Ch. 8.2

**K**
- Keywords, Ch. 2.3, App. D

**L**
- Labeled break/continue, Ch. 5.6
- Lexical structure, Ch. 2
- Logical operators, Ch. 4.3
- loop (infinite), Ch. 5.4

**M**
- Main function, Ch. 6.2
- Map (hash map), Ch. 15.4
- match expression, Ch. 10
- Math library, Ch. 15.5
- Memory management, Ch. 12, 15.6
- Methods, Ch. 7.3, 8
- Modules, Ch. 14.1
- Monomorphization, Ch. 11.1

**N**
- Number literals, Ch. 2.5

**O**
- Operand precedence, Ch. 4.7, App. B
- Operators, Ch. 4, App. B
- Option type, Ch. 9.2, 13.1
- Ownership, Ch. 12

**P**
- Packages, Ch. 14.3
- Pattern matching, Ch. 10
- Path manipulation, Ch. 15.9
- Philosophy (language), Ch. 1.2
- Pointers (*T), Ch. 12.2
- Primitive types, Ch. 3.2
- Project structure, Ch. 18.2

**R**
- Ranges (.. and ..=), Ch. 4.6, 5.5
- References (&T, &mut T), Ch. 12.2, 12.4
- Result type, Ch. 9.2, 13.1
- return statement, Ch. 6.1

**S**
- Scope, Ch. 3.4
- Self-hosting, Ch. 1.1
- Set (hash set), Ch. 15.6
- Slice type (T[]), Ch. 3.3
- Standard library, Ch. 15, App. C
- String literals, Ch. 2.4
- String manipulation, Ch. 15.6
- StringBuilder, Ch. 15.3
- Structs, Ch. 7

**T**
- Trait bounds, Ch. 8.3, 11.3
- Tuples, Ch. 3.3
- Type annotation, Ch. 3.1
- Type cast (as), Ch. 4.6
- Type inference (generics), Ch. 11.1

**U**
- Unwrap operator (!), Ch. 13.3

**V**
- Variables, Ch. 3.1

**W**
- while loop, Ch. 5.2
- Wildcard pattern (_), Ch. 10.2

---

## Библиография / Bibliography

1. Kernighan, B. W., & Ritchie, D. M. (1988). *The C Programming Language* (2nd ed.). Prentice Hall.
2. Klabnik, S., & Nichols, C. (2019). *The Rust Programming Language*. No Starch Press.
3. Rumpf, A. (2023). *Nim Language Specification*. nim-lang.org.
4. Pierce, B. C. (2002). *Types and Programming Languages*. MIT Press.
5. Nystrom, R. (2021). *Crafting Interpreters*. Genever Benning.
6. Aho, A. V., Lam, M. S., Sethi, R., & Ullman, J. D. (2006). *Compilers: Principles, Techniques, and Tools* (2nd ed.). Addison-Wesley.
7. Bux Team. (2026). *Bux Language Reference v0.2.0*. bux-lang.org.
8. Bux Team. (2026). *Bux Standard Library Documentation v0.2.0*. bux-lang.org.

---

> **Лиценз / License:** Този учебник се разпространява под лиценз Creative Commons Attribution-ShareAlike 4.0 International (CC BY-SA 4.0).
> This textbook is distributed under the Creative Commons Attribution-ShareAlike 4.0 International license (CC BY-SA 4.0).

> **За авторите / About the authors:** Този учебник е създаден от екипа на проекта Bux. За актуална информация, посетете хранилището на проекта.
> This textbook was created by the Bux project team. For up-to-date information, visit the project repository.
