# Bux — План към „добър“ език (v0.5 → v1.0)

> **Дата:** 2026-07-15  
> **Текущо:** v0.5.0 — selfhost loop, gradual ownership, green threads, 26+ examples ✅  
> **Цел:** Език, с който се пишат реални проекти комфортно, безопасно (по избор) и с надежден toolchain.

---

## Диагноза (къде сме)

| Слой | Състояние | Оценка |
|------|-----------|--------|
| Frontend (lex/parse) | Пълен Pratt parser, recovery | ★★★★☆ |
| Sema / generics | Monomorphization, trait bounds basic | ★★★★☆ |
| HIR → C | Работи; tuples/func-ptr half-baked в bootstrap | ★★★☆☆ |
| Selfhost (`src/`) | ~12k LOC, binary-identical loop | ★★★★★ |
| Gradual ownership | `@[Checked]`, `&`/`&mut`, move, Drop | ★★★☆☆ (basic) |
| Concurrency | M:N tasks + channels + async | ★★★★☆ |
| Stdlib | 25+ модула, но колекциите са минимални | ★★★☆☆ |
| Tooling | `new/build/run/test/fmt`, LSP prototype, VSCode | ★★☆☆☆ |
| Ecosystem / registry | path+git deps; няма централен registry | ★☆☆☆☆ |
| Документация | Има, но drift (PLAN vs README версии) | ★★★☆☆ |

**Силна ниша:** gradual ownership (C-скорост на писане + opt-in Rust-safety).  
**Слабо място:** ergonomics на stdlib + maturity на tooling + пълнота на borrow checker.

---

## Какво значи „добър“ за Bux

1. **Ежедневен DX** — колекции, string, assert, грешки, които разбираш за секунди.
2. **Предвидима безопасност** — `@[Checked]` да хваща 80% от UAF/double-borrow без lifetime hell.
3. **Selfhost като dogfood** — компилаторът и apps (`nexus`, `boko`) са proof.
4. **Инструменти** — fmt, test, LSP, package install без ръчна магия.
5. **Стабилна спецификация** — LanguageRef = реалното поведение.

Не целим „по-добър Rust“. Целим **единствения език с gradual safety + Go-стил concurrency без GC**.

---

## Фази

### A — Ergonomics & Stdlib (P0, сега) 🔄

| # | Задача | Защо | Статус |
|---|--------|------|--------|
| A.1 | Array: Pop, Clear, IsEmpty, First, Last, Cap, Reserve | Без това колекциите са неудобни | ✅ (тази сесия) |
| A.2 | String: IsEmpty, ReplaceAll | Чести операции; само first-replace досега | ✅ (тази сесия) |
| A.3 | Os_Exit + Test_AssertEqString / richer asserts | Тестове и CLI без raw `bux_exit` | ✅ (тази сесия) |
| A.4 | Map_Remove / Set polish | Completeness на колекциите | ✅ (тази сесия) |
| A.5 | Iter: map/filter/fold върху closures | Higher-order без boilerplate | ✅ Iter_Map/Filter/FoldInt |
| A.6 | Result helpers: Expect, UnwrapErr, Or | По-малко match boilerplate | ✅ (тази сесия) |

### B — Compiler Correctness (P0)

| # | Задача | Защо | Статус |
|---|--------|------|--------|
| B.1 | Proper tuple types в C backend | `(T,U)` → `Tuple_T_U` struct + `.0`/`.1` | ✅ bootstrap + selfhost |
| B.2 | Function pointer types | `func(T)->U` fat ABI | ✅ bootstrap + selfhost |
| B.3 | Match expression до край в C (не `return "0"`) | Expression-context match |
| B.4 | Closures: multi-instance + loop/return в body | Реални higher-order callbacks |
| B.5 | По-добри diagnostics (snippet + hint) | DX #1 за нови потребители | ✅ |
| B.6 | Bootstrap ↔ selfhost feature parity | Operator overloading, string interp и в selfhost |

### C — Gradual Ownership 2.0 (P1)

| # | Задача | Защо |
|---|--------|------|
| C.1 | Lifetime elision за common cases | Без `'a` в 90% от API-тата |
| C.2 | Exclusive `&mut` vs shared `&` data-flow | По-малко false negatives |
| C.3 | Auto-drop edge cases (early return, branches) | RAII да е надежден |
| C.4 | `@[Release]` zero-cost path документация + golden tests | Killer story: safe default, free hot path |

### D — Tooling (P1)

| # | Задача | Защо |
|---|--------|------|
| D.1 | LSP: hover, go-to-def, diagnostics (wire към sema) | IDE = adoption |
| D.2 | `bux fmt` стабилен + CI check | Единен style |
| D.3 | `bux test` с `--filter`, exit codes, summary table | CI-friendly |
| D.4 | `bux doc` от `///` comments | Самодокументиращ се stdlib |
| D.5 | Golden tests за stdlib modules | Регресии без изненади |

### E — Ecosystem & v1.0 (P2)

| # | Задача | Защо |
|---|--------|------|
| E.1 | Package registry protocol (git/HTTP) | `bux add foo` без path hacks |
| E.2 | 3–5 production-quality apps в `apps/` | Showcase |
| E.3 | Language freeze + semver policy | Trust |
| E.4 | Debugger/DWARF basics | Systems audience |
| E.5 | Benchmarks vs C/Zig/Nim (micro + nexus) | Marketing + regression |

---

## Препоръчан ред на работа

```
A (stdlib ergonomics)  →  B (compiler holes)  →  C (ownership depth)
        ↓                        ↓
   D (tooling)  ←──────────  dogfood apps
        ↓
   E (v1.0 ecosystem)
```

**Правило:** всяка сесия ship-ва нещо runnable (stdlib API, fix, example), не само docs.

---

## Acceptance criteria за „добър v1.0“

- [ ] Всички examples + selfhost-loop + 3 apps минават на CI
- [ ] Array/Map/String/Test API покрива 90% от ежедневните нужди
- [ ] `@[Checked]` хваща use-after-move + double `&mut` в documented subset
- [ ] `bux test` + `bux fmt` + `bux check` са default developer loop
- [ ] LanguageRef синхронизиран с компилатора
- [ ] Поне един външен проект (не в monorepo) build-ва с git dep

---

## Сесия 1 (stdlib ergonomics)

1. `Array_Pop`, `Array_Clear`, `Array_IsEmpty`, `Array_First`, `Array_Last`, `Array_Cap`, `Array_Reserve`
2. `String_IsEmpty`, `String_ReplaceAll`
3. `Os_Exit`
4. `Test_AssertEqString`, `Test_AssertNeqInt`, `Test_AssertEqBool`
5. Example + docs update

## Сесия 2 (collections + tuples)

1. `Map_Remove` / `Map_Clear` / `Map_IsEmpty` (+ StringMap)
2. `Set_Remove` / `Set_Clear` / `Set_IsEmpty`
3. `Result_Expect` / `Result_UnwrapErr` / `Result_Or`
4. `Option_Expect` / `Option_Or`
5. **Tuples:** `(T, U)` → `typedef struct { T _0; U _1; } Tuple_T_U` + field access `.0`/`.1`
6. Examples: `tuples`, `func_ptr`, `map_remove`

## Сесия 3 (diagnostics + collections)

1. **Rust-style errors** in bootstrap CLI: `--> file:line:col`, source snippet, `^` caret, `= help:` hints
2. `SourceLocation.file` propagated from lexer
3. Better caret for type-mismatch on `let` (points at initializer)
4. `Array_Contains` / `Array_IndexOf` / `Array_Extend`
5. `Iter_AnyEq` / `Iter_AllEq` / `Iter_Collect`
6. Selfhost `Diagnostic_Hint` for common messages

## Сесия 4 (diagnostics depth + LSP + strings)

1. **Multi-char underlines** (`^^^^^^^` under tokens/strings/idents)
2. Quoted-name highlighting for `undeclared identifier 'x'`
3. **Golden error tests** (`tests/error_golden/`, `make test-errors`)
4. **LSP** runs `buxc check` and publishes real diagnostics
5. `String_IsBlank` / `String_Repeat`

## Сесия 5 (multi-instance closures)

1. **Fat function pointers** for all `func(...)` types: `BuxFn { code(env, args...), env }`
2. Capturing closures: heap-allocate env per creation site (independent instances)
3. Capture-less closures + named funcs: adapters with `env = NULL`
4. Calls through func values: `f.code(f.env, args...)`
5. Example `multi_closure.bux` — MakeAdder(10)/MakeAdder(20) yield 11 and 21
6. **Selfhost parity:** same fat ABI in `src/hir_lower.bux` + `src/c_backend.bux` (makers, adapters)

## Сесия 6 (selfhost tuples)

1. Parser: `(T, U)` types, `(a, b)` exprs, field access `.0`/`.1`
2. Sema: tekTuple / ekTuple
3. HIR lower → `hStructInit` of `Tuple_int_int`
4. C backend: `typedef struct Tuple_int_int { int _0; int _1; }`
5. Verified with `buxc2` on `examples/tuples.bux`
```