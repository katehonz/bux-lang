# Bux — План към „добър“ език (v0.5 → v1.0)

> **Дата:** 2026-07-18  
> **Текущо:** v0.5.x — selfhost loop, gradual ownership, green threads, **41+ examples**, match + pattern bindings + **`f"..."` interp** bootstrap+selfhost ✅  
> **Цел:** Език, с който се пишат реални проекти комфортно, безопасно (по избор) и с надежден toolchain.

---

## Диагноза (къде сме)

| Слой | Състояние | Оценка |
|------|-----------|--------|
| Frontend (lex/parse) | Пълен Pratt parser, recovery | ★★★★☆ |
| Sema / generics | Monomorphization, trait bounds basic | ★★★★☆ |
| HIR → C | Tuples + fat `func` ABI в bootstrap **и** selfhost | ★★★★☆ |
| Selfhost (`src/`) | ~12k LOC, binary-identical loop, closures+tuples | ★★★★★ |
| Gradual ownership | `@[Checked]`, `&`/`&mut`, move, Drop | ★★★☆☆ (basic) |
| Concurrency | M:N tasks + channels + async | ★★★★☆ |
| Stdlib | Array/Map/Set/String/Iter HOF разширени | ★★★★☆ |
| Tooling | `test-errors`, LSP diagnostics + hover/def/outline | ★★★★☆ |
| Ecosystem / registry | path+git deps; няма централен registry | ★☆☆☆☆ |
| Документация | README + QUALITY_PLAN синхронизирани (2026-07-15) | ★★★★☆ |

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

### A — Ergonomics & Stdlib (P0) ✅ (core done)

| # | Задача | Защо | Статус |
|---|--------|------|--------|
| A.1 | Array: Pop, Clear, IsEmpty, First, Last, Cap, Reserve | Без това колекциите са неудобни | ✅ (тази сесия) |
| A.2 | String: IsEmpty, ReplaceAll | Чести операции; само first-replace досега | ✅ (тази сесия) |
| A.3 | Os_Exit + Test_AssertEqString / richer asserts | Тестове и CLI без raw `bux_exit` | ✅ (тази сесия) |
| A.4 | Map_Remove / Set polish | Completeness на колекциите | ✅ (тази сесия) |
| A.5 | Iter: map/filter/fold върху closures | Higher-order без boilerplate | ✅ generic `Iter_Map`/`Filter`/`Fold` + Int aliases |
| A.6 | Result helpers: Expect, UnwrapErr, Or | По-малко match boilerplate | ✅ (тази сесия) |

### B — Compiler Correctness (P0)

| # | Задача | Защо | Статус |
|---|--------|------|--------|
| B.1 | Proper tuple types в C backend | `(T,U)` → `Tuple_T_U` struct + `.0`/`.1` | ✅ bootstrap + selfhost |
| B.2 | Function pointer types | `func(T)->U` fat ABI | ✅ bootstrap + selfhost |
| B.3 | Match expression lowering (literals, ranges, enums) | Expression-context match → if-else | ✅ bootstrap + selfhost |
| B.3b | Pattern bindings (`Some(value) => value`) | Payload idents bound in arm body | ✅ bootstrap + selfhost |
| B.4 | Closures multi-instance | Fat `BuxFn` + heap env | ✅ bootstrap + selfhost |
| B.4b | Closures: `\|\|` empty params + loop/return body | Lexer `\|\|` vs empty closure; while/break/return | ✅ bootstrap + selfhost |
| B.5 | По-добри diagnostics (snippet + hint) | DX #1 за нови потребители | ✅ |
| B.6 | Bootstrap ↔ selfhost feature parity | empty `\|\|`, match-as-expr, **string interp `f"..."`** bootstrap+selfhost | ✅ |

### C — Gradual Ownership 2.0 (P1)

| # | Задача | Защо |
|---|--------|------|
| C.1 | Lifetime elision за common cases | Без `'a` в 90% от API-тата |
| C.2 | Exclusive `&mut` vs shared `&` data-flow | По-малко false negatives |
| C.3 | Auto-drop edge cases (early return, branches) | RAII да е надежден |
| C.4 | `@[Release]` zero-cost path документация + golden tests | Killer story: safe default, free hot path |

### D — Tooling (P1)

| # | Задача | Защо | Статус |
|---|--------|------|--------|
| D.1 | LSP: hover, go-to-def, diagnostics | IDE = adoption | ✅ hover/def/outline + `buxc` diags (lightweight index; full sema later) |
| D.2 | `bux fmt` стабилен + CI check | Единен style | ⏳ |
| D.3 | `bux test` с `--filter`, exit codes, summary table | CI-friendly | ⏳ partial (`bux test` exists) |
| D.4 | `bux doc` от `///` comments | Самодокументиращ се stdlib | ⏳ |
| D.5 | Golden tests за stdlib modules | Регресии без изненади | ⏳ |

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

## Сесия 7 (Iter HOF)

1. `Iter_MapInt` / `FilterInt` / `FoldInt` / `ForEachInt` / `AnyInt` / `AllInt` / `SumInt`
2. Named funcs + capturing closures (fat ABI)
3. Example `iter_hof.bux` (sum=15, product=120)
4. Selfhost fix: pointer `->` field access; no bogus bounds check on `arr.data[len]` (Push)

## Сесия 8 (match expression + error goldens)

1. **Match expression lowering** (B.3): `pkLiteral`, `pkRange` (`a..b` / `a..=b`), enum tags, wildcard
   - Bugfix: literal arms were always-true (`else` branch) → `match 1 { 1=>10, 2=>20 }` returned 10 for all
   - `skMatch` now also lowers via `lowerMatch` (void result)
2. Expanded `examples/pattern_matching.bux` (enums + classify ranges + string arms)
3. **Error golden cases** (`tests/error_golden/`):
   - `parse_error` — incomplete `let x = ;`
   - `use_after_move` — `@[Checked]` + `own String`
   - `double_mut_borrow` — two `&mut` of same var
4. `run.sh` normalize: absolute paths in "parse errors in …" lines

## Сесия 9 (selfhost match — B.6 parity)

1. **AST:** `MatchArm` linked list; `Pattern.patChild1/2` for ranges; `Expr.matchArms`
2. **Parser:** full `parserParsePattern` / `parserParseMatchExpr` (was skip-arms stub)
   - literals, `_`, ident, `Enum::Variant` / `Enum::Variant(...)`, ranges
   - statement `match` → `skExpr` + `ekMatch`
3. **Sema:** type-check subject + arms; propagate first-arm type to `expr.refType`
4. **HIR lower:** `Lcx_LowerMatch` → alloca result + if-else stores (enum `.tag` / simple / literal / range)
5. **Last-expr return:** `Lcx_LowerBlock` converts final `skExpr` into `return` (needed for `func F() -> T { match ... }`)
6. Verified: `pattern_matching` via **buxc2**; simple enum + ranges; **selfhost-loop IDENTICAL ✓**

## Сесия 10 (pattern bindings — B.3b)

1. **Bootstrap sema:** `extractPatternBindings` resolves enum payload field types from variant decl
2. **Bootstrap HIR:** `matchPatternBindings` → `alloca name; name = subject.data.Variant_i` before arm body
3. **Match result type:** fall back to `currentFuncRetType` when arm bodies only use bindings
4. **Multi-field enum layout:** positional `fields.len > 1` → nested struct in `_Data` union (no overlay)
5. **Selfhost:** parse `patArgs` linked list; `Sema_BindPattern`; `Lcx_PatternBindings` in match arms
6. **Example:** `pattern_matching.bux` uses `Option::Some(value) => value` (real binding, not `opt.data.Some_0`)
7. Verified: bootstrap + **buxc2** + all examples + error goldens + **selfhost-loop IDENTICAL ✓**

## Сесия 11 (empty `||` closures + match-as-expr — B.4b)

1. **Bug:** `|| -> int { ... }` lexed as `tkPipePipe` (logical-or), not two `tkPipe` → empty-param closures failed to parse
2. **Fix bootstrap:** primary `of tkPipePipe:` → zero-param `ekClosure`
3. **Fix selfhost:** `parserParseEmptyClosure` for `tkPipePipe`
4. **Match-as-expr:** expression-form match now skips newlines (same as statement form) → `let x = match n { ... }` works
5. **Verified control-flow in closure body:** while/break, early return from loop, multi-return if-chain
6. **Pattern bind reuse:** one alloca per binding name per function (`patternBoundNames`) so two matches can both use `v`
7. **Selfhost match-as-expr:** let-init + binary operands expand yield blocks (`Lcx_IsMatchYield` / `__binop_N`)
8. Examples: `closure_control.bux`, `match_let.bux`
9. Verified: bootstrap + **buxc2** + all examples + error goldens + **selfhost-loop IDENTICAL ✓**

## Сесия 12 (string interpolation selfhost — B.6)

1. **Selfhost parser:** `parserParseStringInterp` — interleaved lit/expr parts in `callArgs`, nested fragment parse via `Lexer_Tokenize` + sub-parser
2. **Selfhost sema/HIR:** `ekStringInterp` → `String_Concat` + `String_FromInt`/`FromBool`/`FromFloat`
3. **Bootstrap fix:** `f"plain"` no longer keeps the `f` prefix in the literal; `\{`/`\}` preserved by lexer and unescaped by interp parser
4. **Lexer:** `\{` / `\}` allowed (bootstrap + selfhost) so LanguageRef escape rules work
5. **Compiler hygiene:** original dense `&&`/`||` in the large interp loop caused bootstrap OOM (~27 GB) when compiling `parser.bux` — rewrite with simpler control flow
6. Example: `examples/string_interp.bux` (name/int/bool/plain/escaped braces)
7. Verified: bootstrap + **buxc2** + all 41 examples + error goldens + **selfhost-loop IDENTICAL ✓**

## Сесия 13 (LSP hover / go-to-def / outline — D.1)

1. **Richer symbol index:** `func` signatures (`params` + `-> Ret`), `let`/`var`/`const` with types, `struct`/`enum`/`union`/`interface`/`type`/`module`
2. **Skip comments/strings** during scan (no false `func` hits)
3. **Hover:** markdown ```bux signature``` + kind; accurate word range
4. **Go-to-definition:** current file + workspace index (scan `.bux` under rootUri)
5. **Document symbols** (outline) via `textDocument/documentSymbol`
6. **didChange** refreshes symbols immediately; **didSave/didOpen** still run `buxc check` diagnostics
7. **Fix:** responses write to **stdout** (was writing to stdin stream → broken pipe)
8. Version `bux-lsp` **0.2.0**; smoke-tested via JSON-RPC

---

## Сесия 14 (generic Iter map/filter/fold)

1. **`Iter_Map<T,U>` / `Filter<T>` / `Fold<T,Acc>` / `Any` / `All` / `ForEach`** — fat `func` params + monomorphization
2. **Int aliases** keep working: `Iter_MapInt` → `Iter_Map<int,int>`, …
3. **Bootstrap fixes:**
   - call return type for local fat-func (`f: func(T)->U`) after mono (was always `int` → String map truncated pointers)
   - generic call `Foo<T>(…)` now type-checks args (closures get capture analysis)
4. **Selfhost fixes:**
   - `Lcx_SubstituteType` recurses into `tekFunc` (was leaving `BuxFn_U_T`)
   - fat typedef emit covers cstr shapes + `#ifndef` guards
5. Example: `examples/iter_generic.bux` (int↔String map, filter, fold, closures)
6. Verified: bootstrap + **buxc2** + selfhost-loop IDENTICAL ✓

---

## Сесия 15 (struct/tuple patterns)

1. **Tuple patterns:** `match t { (a, b) => a + b }` — bind `subject._0` / `._1`
2. **Struct patterns:** `Point { x: px, y: py }` + shorthand `Point { x, y }`
3. Bootstrap: `matchPatternBindings` for pkTuple/pkStruct; field types from struct decl; range registration of local tuple typedefs
4. Selfhost: parse `()` / `Name { … }` patterns; `Sema_BindPattern` + `Lcx_PatternBindings` with Scope_Define
5. Fix: operator-overload path treated `String_Eq(null, "")` as non-empty → crash on `a + b` after pattern bind
6. Example: `examples/struct_tuple_pat.bux`
7. Verified: bootstrap + **buxc2** + selfhost-loop IDENTICAL ✓

---

## Сесия 16 (match block arms + block expressions)

1. **Block-as-expression:** `let r = { let x = 1; x + 2 }` — last skExpr is the value
2. **Multi-stmt match arms:** `1 => { PrintLine("…"); let a = 10; a + 1 }`
3. Bootstrap: `lowerBlock(..., asExpr)` promotes last expression; nested enum/struct pattern bindings
4. Selfhost: parse `{ … }` as `ekBlock`; yield temps `__blk_N`; fix `IsMatchYield` null-strValue false positive; retTypeKind `-2` for expr blocks
5. Nested: `Shape::Dot(Point { x, y })` works on bootstrap; selfhost covers struct/tuple/enum + block arms
6. Example: `examples/match_block.bux`
7. Verified: bootstrap + **buxc2** + selfhost-loop IDENTICAL ✓

---

## Следващи стъпки

1. Deeper nested patterns (`Some((a, b))` with multi-field enum layout ergonomics)
2. LSP: wire hover types from real sema
3. Generic type inference for `Iter_Map` without explicit `<T,U>`
4. Match arm guards (`p if cond => …`)
