# Фаза 8 — Стратегия: Как Bux печели, без да бие пряко Rust/Nim/Zig

> **Дата:** 2026-05-31 | **Статус:** Фаза 8.1 ✅, 8.2-8.6 🔄
> **Правило #1:** Не се биеш с някого там, където той е най-силен.

---

## 1. Проблемът с "да бием Rust"

Ако целта е "по-добър Rust", Bux губи още преди да започне. Rust има:
- 10+ години ecosystem (crates.io → 150,000+ пакета)
- Corporate backing (Amazon, Google, Microsoft, Mozilla)
- LLVM backend с 30 години оптимизации
- Стотици хиляди програмисти, които вече са преживели borrow checker-a

**Опитът да биеш Rust по безопасност е самоубийство.**

---

## 2. Умната стратегия: Не бий конкурентите — бий празното място между тях

Картата на пазара изглежда така:

```
                    Безопасност
                    ▲
                    │
      Rust ─────────┼───────── ■■■■■■■■■■■ (висока, но трябва да платиш за нея)
                    │
      Bux ──────────┼──── ■■■■■■□□□□□□ (gradual — по избор)
                    │
      Nim ──────────┼────── ■■■■■■□□□□ (GC — "достатъчно" безопасен)
                    │
      C / Zig ──────┼── ■■■□□□□□□□□□ (ти си отговорен)
                    │
                    └─────────────────────> Скорост на писане
```

**Никой не стои между "C-скорост на писане" и "Rust-безопасност" с опцията да избираш.**

Bux е единственият език, който позволява:
- Да пишеш като C (raw pointers, без checks) за MVP
- Да добавяш `@[Checked]` после, където е критично
- Да имаш `Result`/`Option`/`?` без lifetime annotations в 90% от кода

**Това е нишата.** Не "по-добър Rust", ами "Rust-лекота, когато искаш; C-свобода, когато бързаш".

---

## 3. Какво означава това за фаза 8 — конкретно

### 3.1 Фаза 8.2 — Gradual Ownership (The Killer Feature)

**Статус сега:** Синтаксисът е парсен, но borrow checker-ът не работи.

**Защо е критично:** Без работещ `@[Checked]`, Bux е просто "C с модерен синтаксис". С него — ставаме единствени на пазара.

**Как да го имплементираме умно (не като Rust):**

```bux
// Ниво 1: Без проверки — като C
func ParseJson(data: *char8) -> *Value { ... }

// Ниво 2: Bounds checking, но без ownership
func SafeAccess(arr: *int, len: int, idx: int) -> int { ... }

// Ниво 3: Пълен borrow checker — само където си решил
@[Checked]
func MergeSorted(a: &[int], b: &[int]) -> Vec<int> { ... }
```

**Ключова разлика от Rust:**
- Rust: `&T` е *всичко*. Ако искаш pointer, се бориш с компилатора.
- Bux: `*T` е default. `&T` е upgrade.

**Имплементационен план (прагматичен):**

| Етап | Фичър | За какво е | Priority |
|------|-------|-----------|----------|
| 8.2.1 | `@[Checked]` атрибут — вкл/изкл на checker | Да знаем кога да проверяваме | **P0 — критично** |
| 8.2.2 | `&T` shared reference + lifetime elision | Basic borrow без annotations | **P0** |
| 8.2.3 | `&mut T` exclusive mutable | Да няма data races | **P0** |
| 8.2.4 | Bounds checking на slices | Да няма buffer overflows | **P1** |
| 8.2.5 | Explicit lifetimes `'a` | Само за сложни случаи | **P2** |
| 8.2.6 | `own T` + move semantics | RAII без GC | **P2** |

**Какво ПРОПУСКАМЕ (за да не стане Rust #2):**
- ❌ Няма да правим lifetime annotations задължителни
- ❌ Няма да имаме `borrowck` грешки във всяка функция
- ❌ Няма да правим NLL (non-lexical lifetimes) в първата версия

**Правило:** Първият `@[Checked]` да хване 80% от бъговете с 20% от сложността на Rust.

---

### 3.2 Фаза 8.3 — Concurrency

**Конкуренция:**
- Go → goroutines + channels (прости, но с GC runtime)
- Rust → async/await (сложен, но zero-cost)
- Zig → няма built-in runtime (ти си го пишеш)

**Bux стратегия:** "Go-простота, но без GC"

```bux
import Std::Task;
import Std::Channel;

// Go-style, но compile-time проверка за Send/Sync
func Worker(rx: Channel<int>) {
    for msg in rx {
        Process(msg);
    }
}

func Main() -> int {
    let (tx, rx) = Channel::New<int>();
    Task::Spawn(Worker, rx);  // Зелени нишки (M:N scheduler)
    tx.Send(42);
    return 0;
}
```

**Защо това печели:**
- Програмистите харесват Go concurrency, но мразят GC паузите
- Rust async е прекалено сложен за средния екип
- Bux дава goroutines без GC → уникална позиция

**Приоритет:** P1 (важно за привличане на Go екипи, но не спира shipping)

---

### 3.3 Фаза 8.4 — CTFE (Compile-Time Function Execution)

**Конкуренция:**
- Zig → `comptime` е best-in-class
- Nim → има CTFE, но с ограничения
- Rust → `const fn` е силно ограничен (no loops, no heap)

**Bux стратегия:** "Nim-лесен синтаксис, Zig-мощност"

```bux
const func Fib(n: int) -> int {
    if n <= 1 { return n; }
    return Fib(n-1) + Fib(n-2);
}

const TABLE_SIZE = Fib(20);  // Computed at compile time

// Use case: embedded / kernel development
const func CrcTable() -> [256]uint32 { ... }
const CRC_TABLE = CrcTable();  // Precomputed, zero runtime cost
```

**Защо това печели:**
- Embedded програмистите (където Rust доминира) обичат precomputed tables
- Nim програмистите вече знаят този модел
- Rust не може да го прави пълноценно

**Приоритет:** P1 — спира Rust програмисти, които се оплакват от `const fn` ограниченията.

---

### 3.4 Фаза 8.5 — Trait System

**Сега имаме:** `interface` + `extend` (като Go interfaces / basic Rust traits)

**Какво трябва:**
- Trait bounds: `func Sort<T: Comparable>(arr: &mut Array<T>)`
- Associated types: `type Output` inside trait
- Blanket impls: `impl<T: Display> Printable for T`

**Защо е важно:** Без trait bounds, generics са ограничени. Не можеш да напишеш `Max<T: Ord>`.

**Но:** Да не правим Haskell. Само това, което Rust има и се ползва всеки ден.

**Приоритет:** P1 — без това stdlib-ът е куц.

---

### 3.5 Фаза 8.6 — Metaprogramming

**Конкуренция:**
- Rust → proc macros са мощни, но болезнени (syn, quote crates)
- Nim → макросите са лесни, но са на Nim-AST (труден за научаване модел)
- Zig → `comptime` е мощен, но изисква да мислиш като компилатор

**Bux стратегия:** Два слоя:

**Слой 1 — Declarative macros (easy):**
```bux
macro! vec {
    [$($item:expr),*] => {
        {
            let mut arr = Array_New();
            $(Array_Push(&mut arr, $item);)*
            arr
        }
    }
}

let v = vec![1, 2, 3];  // Expands at compile time
```

**Слой 2 — Derive macros (medium):**
```bux
#[derive(Clone, Debug)]
struct Point { x: int, y: int }
// Auto-generates Clone_Point and Debug_Point
```

**Защо не procedural macros (като Rust)?**
Защото трябва да пишеш parser. Declarative + derive са 95% от use case-овете.

**Приоритет:** P2 (добре е за ecosystem, но не блокира v1.0)

---

## 4. Стратегическа матрица: Кого целим и с какво

### 4.1 Primary Target: Програмисти, които мразят borrow checker-a, но искат safety

| Те казват | Bux отговаря |
|-----------|-------------|
| "Rust е страхотен, но 6 месеца за MVP е смешно" | `*T` по default, `&T` само където искаш |
| "Не искам да се бия с компилатора за linked list" | Без borrow checker за прототипи |
| "Искам safety, но само на критичните 20% от кода" | `@[Checked]` на точните функции |

**Това са програмисти от:**
- Game dev (Unity → custom engine, C++ → нещо по-добро)
- Embedded (C → Rust опитали се, отказали се)
- Startups (Go → искат performance без GC)

### 4.2 Secondary Target: Nim програмисти, които искат по-добър tooling

Nim е страхотен, но:
- Няма algebraic enums (трябват макроси)
- Exception-based error handling е остарял модел
- Ecosystem е фрагментиран

Bux предлага:
- Същата скорост на компилация
- Същият C backend
- Algebraic enums + Result/Option
- Без GC (за системно програмиране)

### 4.3 Tertiary Target: C програмисти, които искат модерен език без отказ от контрол

Zig е пряк конкурент тук. Но Zig е *твърде* минималистичен.

Bux дава на C програмиста:
- Generics (без `#define` магии)
- Pattern matching
- Modules (без header guards)
- Но пак има `*T` и може да прави `*(int*)0x1234 = 42` ако иска

---

## 5. Какво НЕ правим (убийствено важно)

### ❌ Не правим LLVM backend сега
C transpiler-ът е предимство, не слабост:
- Компилира за <1 секунда
- Работи навсякъде (gcc, clang, msvc)
- Cross-compilation е безплатен (`--target` чрез C компилатора)

LLVM може да дойде Phase 10+ като опция.

### ❌ Не правим perfect borrow checker
Rust-ският borrow checker е титаничен труд (10 години, стотици хора).
Нашият цели 80% от ползата с 20% от кода:
- Само `&T` и `&mut T`
- Lifetime elision по default (без annotations в 90% от случаите)
- Без higher-ranked lifetime traits (HRTB) — твърде сложно

### ❌ Не се конкурираме с Rust по ecosystem
Crates.io е непреодолимо предимство. Ние се конкурираме с:
- Лесен FFI към C (всички C библиотеки са твои)
- По-малки програми, които не се нуждаят от 1000 dependencies

### ❌ Не правим ООП
Няма класове, inheritance, virtual functions. Interface-ите са за trait-like поведение, не за ООП.

---

## 6. Пътна карта за победа (реалистична)

### Milestone A: "Използваем за CLI tools" (2-3 седмици)
- ✅ Generics, Result/Option, pattern matching — готово
- 🔄 Fix `buxc2` bootstrap loop (14/14 modules)
- 🔄 File I/O, path ops, process spawn в stdlib
- 🎯 Target: Можеш да напишеш `bux` package manager на Bux

### Milestone B: "Използваем за systems programming" (2 месеца)
- 🔄 Working `@[Checked]` с basic borrow checking
- 🔄 CTFE за precomputed tables
- 🔄 Trait bounds (`T: Comparable`)
- 🎯 Target: Можеш да напишеш game engine или embedded firmware

### Milestone C: "Екосистема" (6 месеца)
- 🔄 Package manager (`bux add`, registry)
- 🔄 LSP (autocomplete, hover)
- 🔄 Formatter (`bux fmt`)
- 🔄 Green threads + channels
- 🎯 Target: Екип от 3 човека може да продуцира shipping продукт

### Milestone D: "Критична маса" (1-2 години)
- 🔄 1000+ пакета в registry
- 🔄 Първи corporate user (startup или game studio)
- 🔄 Self-hosted compiler стабилен
- 🎯 Target: "Знаеш ли Rust? Пробвай Bux ако трябва бързо."

---

## 7. Пазарно позициониране — как да говорим за Bux

### Грешно (никога не казваме това):
- "Bux е по-добър Rust" → хората се смеят и затварят таба
- "Bux е по-бърз от C" → лъжа, C backend сме
- "Bux е новият C++" → твърде голяма хапка

### Правилно (казваме това):
- "Bux е C с модерни типове и безопасност по избор"
- "Пиши като Go, контролирай като C, проверявай като Rust — когато решиш"
- "Единственият език, където safety е opt-in, не tax"

### Едно изречение:
> "Bux gives you Rust's safety when you want it, C's freedom when you need it, and Go's simplicity all the time."

---

## 8. Заключение

Bux не печели като бие Rust, Nim или Zig.
Bux печели като **запълва празното място между тях**.

| Ако искаш... | Избираш |
|--------------|---------|
| Максимална безопасност на всяка цена | Rust |
| Максимална скорост на прототипиране с GC | Nim |
| Максимален контрол и прозрачност | Zig |
| **Баланс — бързо писане + безопасност по избор** | **Bux** |

**Фаза 8 е оръжейната:** Gradual ownership + CTFE + Traits + Concurrency.
Ако имплементираме 8.2 (ownership) правилно — като opt-in upgrade, не като данък — Bux става единствен на пазара.

Ако го объркаме и стане "Rust-lite" — сме мъртви.
