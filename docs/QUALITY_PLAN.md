# Bux — План към „добър“ език (v0.5 → **v1.0.0** ✅)

> **Дата:** 2026-07-27  
> **Текущо:** **v1.0.0** — language freeze (session 88 / release)  
> **Цел:** Език, с който се пишат реални проекти комфортно, безопасно (по избор) и с надежден toolchain.  
> **Платформен фокус:** **Linux** (primary) · **cloud-native** (servers, containers, HTTP) · **embedded** (cross, freestanding-ish, CTFE).  
> **Не-цел:** MS Windows като product platform (исторически CI/hello smoke остават; няма roadmap investment).  
> **Release notes:** `docs/RELEASE_v1.0.0.md` · **Semver:** `docs/SEMVER.md` (active).

---

## Диагноза (къде сме)

| Слой | Състояние | Оценка |
|------|-----------|--------|
| Frontend (lex/parse) | Пълен Pratt parser, recovery | ★★★★☆ |
| Sema / generics | Monomorphization, trait bounds basic | ★★★★☆ |
| HIR → C | Tuples + fat `func` ABI в bootstrap **и** selfhost | ★★★★☆ |
| Selfhost (`src/`) | ~12k LOC, binary-identical loop, closures+tuples | ★★★★★ |
| Gradual ownership | `@[Checked]`, move, Drop, elision, **field-move + remaining-field Drop** | ★★★★★ |
| Concurrency | M:N tasks + channels + async | ★★★★☆ |
| Stdlib | Array/Map/Set/String/Iter HOF разширени | ★★★★☆ |
| Tooling | LSP 0.5 hover/def/outline/**refs/rename** + fmt/test/doc | ★★★★★ |
| Ecosystem / registry | path+git + file **+ HTTP** index (`bux search/add`) | ★★★★☆ |
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
6. **Целеви среди** — Linux servers/containers, cloud HTTP services, embedded/cross (ARM/RISC-V), не desktop Windows.

Не целим „по-добър Rust“. Целим **единствения език с gradual safety + Go-стил concurrency без GC**, удобен за **cloud + systems на Linux**.

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
| B.3c | Match arm guards (`p if cond => …`) | Bindings visible in guard; sequential found-flag lower | ✅ bootstrap + selfhost |
| B.4 | Closures multi-instance | Fat `BuxFn` + heap env | ✅ bootstrap + selfhost |
| B.4b | Closures: `\|\|` empty params + loop/return body | Lexer `\|\|` vs empty closure; while/break/return | ✅ bootstrap + selfhost |
| B.5 | По-добри diagnostics (snippet + hint) | DX #1 за нови потребители | ✅ |
| B.6 | Bootstrap ↔ selfhost feature parity | empty `\|\|`, match-as-expr, **string interp `f"..."`** bootstrap+selfhost | ✅ |

### C — Gradual Ownership 2.0 (P1)

| # | Задача | Защо | Статус |
|---|--------|------|--------|
| C.1 | Lifetime elision за common cases | Без `'a` в 90% от API-тата | ✅ bootstrap + selfhost |
| C.2 | Exclusive `&mut` vs shared `&` data-flow | По-малко false negatives | ✅ let-bound + use-while + call conflict |
| C.3 | Auto-drop edge cases (early return, branches) | RAII да е надежден | ✅ bootstrap + selfhost |
| C.4 | `@[Release]` zero-cost path документация + golden tests | Killer story: safe default, free hot path | ✅ full (docs + Release wins + tests + example) |

### D — Tooling (P1)

| # | Задача | Защо | Статус |
|---|--------|------|--------|
| D.1 | LSP: hover, go-to-def, diagnostics | IDE = adoption | ✅ v0.11.0: + **interface dispatch hierarchy** |
| D.2 | `bux fmt` стабилен + CI check | Единен style | ✅ full-tree format + `make fmt-check` enforce |
| D.3 | `bux test` с `--filter`, exit codes, summary table | CI-friendly | ✅ `--filter` / summary / exit 0\|1 |
| D.4 | `bux doc` от `///` comments | Самодокументиращ се stdlib | ✅ bootstrap+selfhost + `make docs` |
| D.5 | Golden tests за stdlib modules | Регресии без изненади | ✅ `tests/stdlib_golden/` + `make test-stdlib` |

### E — Ecosystem & v1.0 (P2)

| # | Задача | Защо | Статус |
|---|--------|------|--------|
| E.1 | Package registry protocol (git/HTTP) | `bux add foo` без path hacks | ✅ local index + **HTTP(S) URL** cache + file/git + `search` |
| E.2 | 3–5 production-quality apps в `apps/` | Showcase | ✅ 4 apps + `make test-apps` smoke (build + CLI) |
| E.3 | Language freeze + semver policy | Trust | ✅ **v1.0.0** + active `docs/SEMVER.md` |
| E.4 | Debugger/DWARF basics | Systems audience | ✅ `#line`→`.bux` + `-g` / `--release`; `make test-dwarf` |
| E.5 | Benchmarks vs C/Zig/Nim (micro + nexus) | Marketing + regression | ✅ micro + C/Nim/Zig twins + `make bench-nexus` (wrk) |

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

## Acceptance criteria за „добър v1.0“ — **met; tagged v1.0.0**

- [x] Всички examples + apps + selfhost smoke на CI (`make test` via `.github/workflows/ci.yml`); selfhost-loop optional
- [x] Array/Map/String/Test API покрива 90% от ежедневните нужди (+ Insert/Remove/Clone/case/GetOr)
- [x] `@[Checked]` хваща use-after-move + double `&mut` + dangling return / elision fail
- [x] `bux test` + `bux fmt` + `bux check` са default developer loop (`--filter` / `--check` shipped)
- [x] LanguageRef синхронизиран с компилатора (incl. C.1 elision)
- [x] Поне един външен/temp проект build-ва с registry dep (`tools/smoke_registry.sh` + HTTP)
- [x] Version strings + SEMVER active + `docs/RELEASE_v1.0.0.md` (session 88)

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

## Сесия 17 (deeper nested patterns + multi-field enum layout)

1. **Multi-field payload type:** nested struct `Enum_Variant_Payload` (suffix avoids clash with tag `Enum_Variant`)
2. Bootstrap: full `resolveTypeExpr` for enum field types (tuples/pointers); sema synthetic field lookup on payload types; `data.Two.Two_0` construction
3. LIR C backend: emit tuple typedefs **before** enums that embed them; topo deps for `*_Payload`
4. Selfhost: enum variants parse full types (`parserParseType`) — fixes `Val((int,int))`; store `fieldTypeName*`; structs before enums (e.g. `Dot(Point)`)
5. Patterns: `Pair::Two(a, b)`, `Box::Val((a, c))`, `Shape::Dot(Point { x, y })` + block arms
6. Example: `examples/nested_patterns.bux`
7. Verified: bootstrap + **buxc2** + selfhost-loop IDENTICAL ✓

---

## Сесия 18 (match arm guards — B.3c)

1. **Syntax:** `p if cond => body` (also after ranges: `1..10 if x % 2 == 0`)
2. **Parser fix (critical):** `isTypeArgListAhead` treated `x < 0` as generic when a later `x > 0` existed in another arm → infinite parse. Stop lookahead on `=>`, keywords, literals, arithmetic, comparisons.
3. **Sema:** bind inner pattern first; type-check guard as bool in arm scope
4. **HIR lower:** sequential `found` flag (no shared if-else DAG):
   ```
   if (!found) { if (inner_cond) { binds; if (guard) { result = body; found = true; } } }
   ```
   Bindings are in scope for the guard expression.
5. **Selfhost:** `pkGuarded` + `patGuardExpr`; same lower strategy; fix `return match {…}` to expand yield block before return
6. Example: `examples/match_guards.bux` (ident/literal/range/enum payload guards)
7. Verified: bootstrap + **buxc2** + all examples + error goldens + **selfhost-loop IDENTICAL ✓**

---

## Сесия 19 (generic HOF type inference)

1. **Bootstrap `inferTypeArgs`:** structural unify of param TypeExpr vs arg Type
   - `*Iter<T>` / `*Array<T>` → extract T from pointee type args or mangled `Array_int`
   - `func(T)->U` → bind T/U from function-value type (not whole func as T)
   - bare `Acc` from init; multi-param `Iter_Fold<T,Acc>`
2. **Selfhost:** improved `Sema_InferGenericArgs` + return-type subst after inference
   - Fix: `ekCast` must type-check operand (was skipping → no inference under `as`)
   - HIR fallback mono from first *Array/*Iter arg when count=0
3. Works without explicit type args:
   - `Array_Push(&nums, 1)`, `Array_Get`, `Array_Len`, `Array_Iter`
   - `Iter_Map(&it, f)`, `Iter_Filter`, `Iter_Fold`, `Iter_Any` (int↔String)
4. Example: `examples/generic_infer_hof.bux`
5. Verified: bootstrap + **buxc2** + all examples + **selfhost-loop IDENTICAL ✓**

---

## Сесия 20 (LSP hover from real sema — D.1)

1. **`bux-lsp` 0.3.0** links bootstrap (`--path:../bootstrap`) and runs `analyzeFull` on open/save
2. **typeIndex:** global scope (stdlib + file) → hover signatures with real types
3. **File-local priority:** user decls override stdlib name collisions (`Max<T>` vs `Math.Max`)
4. **Locals:** walk function bodies for `let`/`var` with explicit type annotations
5. **didChange:** fast lightweight rescan; keeps previous typeIndex until save/hover refresh
6. Hover shows ```bux signature``` + `_kind_ · sema`
7. Smoke: `Main() -> int`, `PrintLine(String) -> void`, `Max<T>(a: T, b: T) -> T`

---

## Сесия 21 (pattern binding shadowing)

1. **Problem:** C/LIR function-scoped locals — nested `Some(n) => match … Some(n)` emitted store before `int n`, and `let v` + pattern `v` caused redeclaration.
2. **Bootstrap:** every pattern binding → unique C name `__pN_src` via `patternRenames` map; body/guard idents rewritten; **binds before body lower** inside `lowerMatch`.
3. **Selfhost:** same model — `Lcx_BindPatIdent` + `patMapFrom/To` rename table; arm-scoped push/pop of map.
4. Semantics: nested pattern name shadows correctly; outer `let v` survives after match that binds `v`.
5. Example: `examples/pattern_shadow.bux`
6. Verified: bootstrap + **buxc2** + all examples + **selfhost-loop IDENTICAL ✓**

---

## Сесия 22 (Ownership 2.0 — C.2 + C.4 + *p= fix)

1. **C.2 Exclusive &mut data-flow** (`@[Checked]`):
   - Track long-lived let-bound borrows (`activeMutBorrows` / `activeSharedBorrows`)
   - Reject: second `&mut x`, use/assign of `x` while mutably borrowed, `&x` while `&mut` live
   - Call-site temps conflict with existing let-bound borrows
2. **C.4 Golden tests:**
   - `tests/error_golden/exclusive_mut_let/`
   - `tests/error_golden/use_while_mut_borrow/`
3. **Bugfix:** `*p = expr` now stores through the pointer (was assigning to a temp) — ownership examples finally mutate correctly
4. Example: `examples/ownership_checked.bux` (unchecked zero-cost + checked OK path)
5. Verified: 7 error goldens + borrow_test + all examples + selfhost-loop

---

## Сесия 23 (Ownership 2.0 — C.3 auto-drop early return / branches)

1. **Bootstrap auto-drop for `@[Drop]` + collections:**
   - Parser: `@[Drop]` / `@[Release]` on structs and funcs (`declAttrs`)
   - `autoDropFuncName` + monomorphize `Array_Drop`/`Free` (etc.) so stdlib links
   - Inject `Type_Drop(&x)` on `let` via `deferStmts`
2. **Early return / multi-path:**
   - Every `return` snapshots the full live defer stack (no clear-after-first-return)
   - Materialize return value **before** Drop (`return a.id` is not use-after-drop)
   - Move-on-return: skip Drop for a local returned by value (`return out`)
3. **Branch / loop scopes:**
   - Bootstrap: `lowerBlock` scopes `deferStmts` — branch-local drops at block exit; siblings do not see each other
   - Selfhost C backend: `CBE_EmitDefers` keeps stack for multi-return; `CBE_EmitAndPopDefersFrom` pops branch/loop locals after `if`/`while`/`loop`
4. **Selfhost fixes:** null-safe ret type; temp name counter; use function `retTypeName` for `__retdrop_N`
5. Example: `examples/drop_early_return.bux` (Early + Branched + Scoped → 5 drops)
6. Verified: bootstrap + **buxc2** drop tests, 7 error goldens, key examples, **selfhost-loop IDENTICAL ✓**

---

## Сесия 24 (tooling — D.2 fmt --check + D.3 test --filter)

1. **Bootstrap `bux fmt`** (`bootstrap/fmt.nim`):
   - Indent-by-brace-depth formatter (parity with `src/fmt.bux`)
   - `bux fmt [path...]` writes; `bux fmt --check` exits 1 if any file would change
   - Collects single file or recursive `.bux` under directories
2. **Bootstrap `bux test --filter`**:
   - `--filter <s>` / `--filter=<s>` — only run `tests/*.bux` whose name contains `s`
   - Summary table (`PASS` / `FAIL[:code]`) + `Results: N passed, M failed, T total`
   - Exit `0` all pass, `1` failures or no match
3. **Selfhost parity** (`src/cli.bux`, `src/fmt.bux`):
   - `Fmt_WouldChange` / `Fmt_CheckFile`; `Cli_Fmt(dir, checkOnly)`
   - `Cli_Test(dir, filter)` with summary + skip count; filter skips Main package run
4. **CI hooks:** `make fmt-check` smoke (clean→0, dirty→1); full-tree enforce deferred
   until a one-shot format pass on `lib/`/`examples/`
5. **Idempotence fix:** drop trailing split-empty so re-format is a no-op
6. Verified: unit suite + `./buxc test --filter first _test_runner` + selfhost `buxc2`
   fmt/test parity

---

## Сесия 25 (Ownership 2.0 — C.1 lifetime elision)

1. **Elision rules** in `@[Checked]` (`bootstrap/sema.nim`):
   - Each elided input `&`/`&mut` → distinct `#elidedN`
   - One input lifetime → assigned to elided return
   - First param `self`/`Self` preferred when multiple inputs
   - Multiple inputs + elided return → `lifetime elision failed` (need `'a`)
2. **Return checks:**
   - `cannot return reference to local variable` (`return &local` / let-bound local ref)
   - `no input reference to borrow from` (return ref with zero input refs)
   - Explicit `'a` mismatch between return and value
3. **Body check for lifetime-only generics** (`func F<'a>(...)`) — no longer skipped
4. **Diagnostics hints** for elision / dangling / mismatch
5. **Tests:** 8 new borrow_test cases; goldens `return_local_ref`, `elision_multi_input`
6. **Example:** `examples/lifetime_elision.bux` (Identity / explicit / ViaLet / self)
7. LanguageRef + QUALITY_PLAN updated
8. Verified: borrow_test 24/24, 9 error goldens, example runs

## Сесия 26 (C.1 selfhost parity)

1. **Lexer** (`src/lexer.bux` + `tkLifetime=111`): `'a` vs char `'x'` (same heuristic as bootstrap)
2. **Parser:**
   - `&'a T` / `&'a mut T` → `TypeExpr.refLifetime`
   - `func F<'a, T>(…)` — lifetime params accepted and **skipped** for mono slots
3. **Sema** lifetime elision (fixed 8-slot maps, same rules as bootstrap):
   - single-input elision, `self` preference, multi-input fail
   - return-local / no-input-ref / explicit mismatch
   - let-bound ref lifetime propagation
4. Fixed `checkFunc` else-branch that wiped `checkedFunc` when retType was void
5. Verified: `buxc2 run lifetime_elision` PASS; goldens on buxc2 show same errors;
   bootstrap still green; **selfhost-loop** expected IDENTICAL

---

## Сесия 27 (tooling — D.4 bux doc + D.5 stdlib goldens)

1. **D.5 Stdlib goldens** (`tests/stdlib_golden/`):
   - Packages: `array`, `string`, `collections` (Map/Set/Result/Option)
   - `run.sh` builds via `buxc run` and matches expected PASS lines
   - `make test-stdlib` wired into `make test`
2. **D.4 `bux doc`**:
   - Bootstrap: `bootstrap/docgen.nim` — `///` + adjacent `/* */`
   - Selfhost: `Cli_Doc` line scanner for `///`
   - `bux doc [--out file] [path]` (default path `lib/`)
   - `make docs` → `docs/api/stdlib.md`
3. **Stdlib docs:** `///` on Array / String / Test public helpers
4. Verified: `make test-stdlib`, `./buxc doc lib/Array.bux | head`, selfhost build

---

## Сесия 28 (LSP v0.4.0 — position-sensitive locals + inferred lets)

1. **`LocalBinding`** with scope range (`scopeStartLine`…`scopeEndLine`) per let/param
2. **Sema-backed inference** (`checkExprForLsp` / `resolveType`):
   - `let x = 42` → hover `let x: int` · inferred
   - `let s: String = "…"` → annotated, not inferred
   - params: `param a: int` visible for whole function
3. **Position-sensitive** hover / go-to-def / completion (innermost scope wins on shadowing)
4. Nested scopes: if/while/for/match/block arms
5. Version **bux-lsp 0.4.0**; tests: `tools/test_lsp_locals.nim`, `tools/smoke_lsp_hover.sh`
6. Verified: hover shows `let sum: int · inferred`, `param a: int`, `let n: int · inferred`

---

## Сесия 29 (full-tree `bux fmt` + CI enforce)

1. **One-shot format** of `lib/` (33), `examples/` (23), `src/` (15), `tests/` (8), `apps/` (12)
2. **Idempotent:** second `--check` → 0 would reformat on all trees
3. **CI:** `make fmt-check` enforces full tree + dirty-path smoke (exit 1)
4. **`make fmt`** helper to reformat the same roots
5. Verified: `test-stdlib`, key examples, **selfhost + selfhost-loop IDENTICAL ✓**

---

## Сесия 30 (E.1 package registry + E.3 semver draft)

1. **Registry index** (`config/registry.toml`, `$BUX_REGISTRY`, `~/.bux/registry.toml`)
   - `[[package]]` with `name` / `version` / `source` / `description`
   - `file:` / `path:` (relative to index) or git URL
2. **CLI:** `bux search [q]`, `bux add <name>` resolves registry, `bux install` locks path/git
3. **Demo package:** `registry/packages/greet` (`Greet_Hello`, `Greet_Version`)
4. **Smoke:** `tools/smoke_registry.sh` / `make test-registry` — temp app outside tree
5. **Semver policy:** `docs/SEMVER.md` (0.x vs 1.0, registry version match)
6. Packages.md updated

---

## Сесия 31 (E.1b HTTP registry + E.2 apps smoke + E.5 micro-bench)

1. **HTTP registry index** (`bootstrap/registry.nim`):
   - `$BUX_REGISTRY` accepts `http://` / `https://` URLs
   - Fetch via `curl` (fallback `wget`) → `~/.bux/cache/registry_http.toml`
   - `BUX_REGISTRY_REFRESH=1` forces re-download; cache keyed by URL meta file
   - `bux search` shows URL + cached path; clear errors on fetch failure
2. **Smoke:** `tools/smoke_registry.sh` — local path flow **+** python `http.server` HTTP search
3. **E.2 apps smoke** (`tools/smoke_apps.sh` / `make test-apps`):
   - Build `simpledb`, `jwt-pitbul`, `nexus`, `boko-framework`
   - simpledb set/get/has/count/del; jwt-pitbul sign/verify/decode
   - Removed obsolete JWT-disable workaround from simpledb README
4. **E.5 micro-benchmarks** (`benches/micro`, `benches/c`, `make bench`):
   - Bux: `int_loop`, `fib30`, `string_concat`, `array_push`
   - C refs (`gcc -O2`): `fib30`, `int_loop` for relative comparison
5. Docs: `Packages.md`, `config/registry.toml`, `benches/README.md`
6. Verified: `make test-registry`, `tools/smoke_apps.sh`, `tools/bench.sh`

---

## Сесия 32 (E.5 nexus throughput + language twins)

1. **Nexus env config** (`apps/nexus/src/Main.bux`):
   - `NEXUS_PORT`, `NEXUS_WORKERS`, `NEXUS_BIND`, `NEXUS_PUBLIC`
2. **Throughput harness** (`tools/bench_nexus.sh` / `make bench-nexus`):
   - Start nexus on `:18080`, `wrk -t4 -c64 -d5s` → `/api/health`
   - Sample (this machine): **~44.5k req/s**, p50 ~0.94 ms (Connection: close)
3. **Language twins** for micro kernels:
   - `benches/nim/` fib + int_loop (`nim c -d:release`)
   - `benches/zig/` sources (built when `zig` is on PATH)
   - `make bench` runs Bux + C + Nim (+ Zig if present)
4. Docs: `benches/README.md`, nexus README, BuildAndTest
5. Verified: `tools/bench.sh`, `tools/bench_nexus.sh`

---

## Сесия 33 (E.4 Debugger / DWARF basics)

1. **Source map:** HIR `loc` → LIR `locLine`/`locFile` on every stmt/expr (`setSourceLoc`)
2. **C backend:** emit `#line N "path.bux"` when location changes; force map at each func entry
3. **Build modes:**
   - default: `cc -O0 -g` + `#line` maps
   - `--release` / `build --release`: `-O2 -DNDEBUG`, no `#line`, no `-g`
   - `BUX_CFLAGS` appended for custom flags
4. **Smoke:** `tools/smoke_dwarf.sh` / `make test-dwarf`
   - `#line` for stdlib + user `Main.bux`
   - `.debug_info` present in debug binary
   - `gdb list Main` shows real Bux source
5. Verified: smoke PASS; `gdb list Main` → hello.bux body

---

## Сесия 34 (LSP refs/rename + CI wiring)

1. **bux-lsp 0.5.0** (`tools/lsp_server.nim`):
   - `textDocument/references` — scoped locals (same binding via `lookupLocalAt`) + workspace globals
   - `textDocument/prepareRename` + `rename` → `WorkspaceEdit.changes`
   - Ident scan skips strings/comments; keyword rename rejected
2. **Smoke:** `tools/smoke_lsp_rename.sh` (sum→total ≥2 edits); wired into `make test-lsp`
3. **CI:** `make test` now runs `test-registry` + `test-dwarf` + `test-apps` after stdlib goldens
4. Verified: rename/hover smokes PASS

---

## Сесия 35 (Nexus HTTP/1.1 keep-alive)

1. **Server loop** (`apps/nexus/src/Server.bux`):
   - `HandleConnection` serves up to 1000 requests per TCP fd
   - `BuildResponse(..., keepAlive)` → `Connection: keep-alive` + `Keep-Alive:` or `close`
2. **Policy** (`RawRequest_WantsKeepAlive` on raw bytes):
   - HTTP/1.1 default keep-alive; `Connection: close` forces close
   - HTTP/1.0 needs explicit keep-alive
   - (Avoided fragile `Array<HeaderEntry>` walk — keys corrupted under for-in/Get)
3. **Bench:** ~**81k req/s** vs ~45k with close-only (`wrk -t4 -c64 -d5s /api/health`)
4. Version banner **0.3.0**; README / benches notes updated
5. Verified: curl headers + `make bench-nexus`

---

## Сесия 36 (header ownership + selfhost flags + LSP workspace/symbol)

1. **Root cause (Nexus headers UAF):** auto-drop of local `headers` after
   shallow-copy into `HttpRequest` / `ParseResult` freed the buffer while still
   referenced. Not Array ABI — **move-out-of-field not tracked**.
2. **Fix** (`apps/nexus/src/Parser.bux`): after embedding, zero
   `headers.data/len/cap` so auto-drop is a no-op; `Request_WantsKeepAlive`
   again uses `RequestHeader_Get` safely. Bench still ~76–80k RPS.
3. **Selfhost compile flags** (`src/cli.bux`):
   - default **`-O0 -g`** (was always `-O2`)
   - `--release` → **`-O2 -DNDEBUG`** (was `-O3 -flto`)
   - `BUX_CFLAGS` appended via `bux_getenv`
   - `#line` maps remain bootstrap-only (selfhost C backend has no LIR #line yet)
4. **LSP 0.6.0:** `workspace/symbol` over open docs + workspace index (cap 200);
   `tools/smoke_lsp_workspace.sh` + `make test-lsp`
5. Verified: nexus keep-alive + header Get; `make lsp` + workspace smoke

---

## Сесия 37 (compiler: field-move skip auto-Drop)

1. **Root cause (formal):** auto-Drop of locals that were **moved by value** into
   a struct field / let / return still ran → UAF (Nexus `headers` in `HttpRequest`).
2. **`bootstrap/hir_lower.nim`:**
   - `movedOutLocals: HashSet[string]`
   - `markMovedOutFromAst` on `ekStructInit` fields, `let` init, `return` value
   - `shouldSkipDrop` at return / block exit / function tail
3. **Nexus:** removed zeroing workaround; error path still Drops; success path
   transfers ownership; `HandleConnection` Drops `req.headers` after response
4. **Example:** `examples/move_field.bux` (Array into `Box { items }`)
5. Verified: move_field PASS; ParseRequest C has Drop only on error path;
   `bench-nexus` ~88k RPS; drop_early_return still 5 drops

---

## Сесия 38 (selfhost field-move + #line)

1. **Field-move Drop** (`src/c_backend.bux`):
   - `CBE_MarkMovedFromNode` on `hStructInit` / return values (nested fields)
   - Already skipped Drop via `CBE_IsMoved` in defer emit
2. **Struct emit fix** (`src/hir_lower.bux`):
   - Field types `Array<int>` → `Array_int` (etc.) so parent structs are not
     skipped as “generic” (was incomplete `typedef struct Box Box` only)
3. **#line maps** (selfhost C backend):
   - Emit `#line N "file"` on statements when `node.line > 0`
   - `BUX_DEBUG_FILE` sets the path; `BUX_NO_LINE=1` disables
4. Verified: selfhost `move_field` PASS; Make() has **no** `Array_Drop(&items)`
   after field move; `#line` points at `.bux` sources

---

## Сесия 39 (LSP 0.7 deeper rename)

1. **Member index** in `analyzeFile`:
   - struct/union/interface fields (`name: Type`)
   - enum variants (`Name` / `Name(...)`)
2. **Access classification** for each hit:
   - bare / `.member` / `::Variant` / `name:` field-init
3. **Rename targets**:
   - **local** — same binding only (shadowing-safe)
   - **member** — decl + `.x` + `::Red` + `{ x: }` — **not** bare locals named `x`
   - **global** — bare + `::` paths; skips `.member` false positives
4. Smoke: `tools/smoke_lsp_rename_deep.sh` (x→px ≥3, Red→Crimson ≥2, local x→xx =2)
5. Version **bux-lsp 0.7.0**; wired into `make test-lsp`

---

## Сесия 40 (LSP 0.8 call hierarchy)

1. **Providers:**
   - `textDocument/prepareCallHierarchy`
   - `callHierarchy/incomingCalls` — who calls F
   - `callHierarchy/outgoingCalls` — what F calls
2. **Graph:** textual scan of known `func` symbols + `Name(` call sites;
   enclosing function via nearest prior `func` decl line
3. Skips the declaration itself; workspace disk scan for other `.bux` files
4. Smoke: `tools/smoke_lsp_call_hierarchy.sh` (Add ← Compute; Compute → Add/Mul)
5. Version **bux-lsp 0.8.0**; `make test-lsp`

---

## Сесия 41 (selfhost multi-file #line paths)

1. **`Decl.sourceFile`** stamped when parsing/merging each `.bux` file
   (`Cli_StampSourceFile` / `Cli_MergeFileInto` / project `src/` loop)
2. **`HirFunc.sourceFile`** copied in `Lcx_LowerFunc`
3. **C backend:** before each function, set `currentFile` from `sourceFile`
   and emit `#line 1 "path"` + per-stmt `#line N "path"`
4. **No env required** — stdlib + user multi-file paths appear automatically
   (`lib/Fs.bux`, `./src/Util.bux`, `./src/Main.bux`, …)
5. Overrides: `BUX_DEBUG_FILE` (force one path), `BUX_NO_LINE=1` (disable)
6. Verified: multi-file project runs; `#line` paths distinct per source

---

## Сесия 42 (selfhost CI smoke)

1. **`tools/smoke_selfhost.sh`:**
   - build/use `buxc2` (`make selfhost`)
   - **move_field**: run PASS + no `Array_Drop(&items)` after field move
   - **multi-file #line**: Util.bux + Main.bux + `lib/*.bux` paths in `main.c`
2. **`make test-selfhost-smoke`** depends on `selfhost`
3. Wired into default **`make test`**
4. Verified: smoke script PASS

---

## Сесия 43 (LSP 0.9 method call hierarchy)

1. **Index methods** in `analyzeFile`:
   - Track `extend Type` / `impl Type` brace body
   - `func` inside → kind `method`, container `Type`, detail `Type.func …`
2. **Call graph** includes methods as callables
   - `.Method(` sites (iaDot) + free `Func(` calls
   - CallHierarchyItem: SymbolKind.Method (6), display `Type.Method`
   - `data` field keeps bare name for graph match
3. Smoke: `tools/smoke_lsp_method_hierarchy.sh`
   - `Scale` → `Len`; `Main` → `Scale`; prepare on method
4. Version **bux-lsp 0.9.0**; `make test-lsp`

---

## Сесия 44 (LSP 0.10 method + type + receiver rename)

1. **`rtkMethod`**: rename method decl + `.Method(` + bare `Method(`
   - (previous global path skipped `iaDot` → broke method rename)
2. **Type rename** (`isType`): `struct`/`extend Type`/`self: Type`/ctors; skip `.field`
3. **`self` receiver**: synthetic local when sema omits method params; clip to
   enclosing `func` body via textual bounds (sibling methods safe)
4. Smoke: `tools/smoke_lsp_rename_method.sh`
   - Len→Length ≥2, Point→Vec2 ≥4, self→this =3 (one method only)
5. Version **bux-lsp 0.10.0**; `make test-lsp`

---

## Сесия 45 (LSP 0.11 interface dispatch hierarchy)

1. **Index:**
   - `interface I { func M… }` → iface methods + symbol
   - `extend Type for I` → `impls` relation + implementor methods
2. **Call hierarchy:**
   - prepare on interface method → item with `data: "I#M"`, kind Interface
   - **outgoing** on iface method → implementor methods (dispatch targets)
   - **incoming** on iface method → callers of `.M(`
3. Smoke: `tools/smoke_lsp_iface_hierarchy.sh`
   - Drawable.Draw → Circle implementor; Render → Draw
4. Version **bux-lsp 0.11.0**

---

## Сесия 46 (LSP 0.12 module-path segment rename)

1. **Index** `import A::B::C` / `import A::B::{…}` path segments (`PathSegInfo`)
2. **`rtkPathSeg` rename** with left-prefix match:
   - `Std::Io` → only segments under prefix `Std` (not `Foo::Io`, not bare `Io`)
   - path head `Std` only when followed by `::` (not bare locals)
   - does not clobber enum `Color::Red` (member path still wins on variants)
3. Last import segment that is also a known symbol falls through to global rename
4. Workspace scan for unopened `.bux` files
5. Smoke: `tools/smoke_lsp_rename_path.sh`
   - Io→Net ≥2 (Main+Util), not Foo::Io; Std→Core ≥2; Red→Crimson ≥2
6. Version **bux-lsp 0.12.0**; `make test-lsp`

---

## Сесия 47 (HirNode-level sourceFile / mid-function #line)

1. **`HirNode.sourceFile`** — per-statement path for `#line` (rare multi-file spans)
2. **`Lcx_StampSourceFile`**: after lowering a func/closure body, fill empty
   node paths from `Decl.sourceFile` / `HirFunc.sourceFile` (keeps pre-set paths)
3. **`LowerCtx.currentSourceFile`** + closures inherit enclosing file
4. **C backend:** `lastDebugFile` + prefer `node.sourceFile` over func
   `currentFile`; re-emit `#line` when **line or file** changes mid-function
5. `BUX_DEBUG_FILE` truly forces one path (no longer overwritten by per-func)
6. Smoke: `tools/smoke_selfhost.sh` — Util_Double body `#line` → Util.bux only
7. `make test-selfhost-smoke` / rebuild selfhost

---

## Сесия 48 (optional CI: selfhost-loop)

1. **`tools/selfhost_loop.sh`**: bootstrap determinism (buxc × 2)
   - path-normalized `#line` C compare (abs path / build-dir noise stripped)
   - stripped ELF compare; **fails** on real C or ELF mismatch
2. **Lexer:** `maxTokens` 32k → 131k (hir_lower was at the ceiling for buxc2 parse)
3. **Optional fixed-point** `BUX_SELFHOST_FIXED_POINT=1`: buxc2 → buxc3
   - experimental; selfhost still diverges on full compiler C emit
4. **GitHub Actions** `.github/workflows/selfhost-loop.yml`
   - `workflow_dispatch` (+ optional fixed_point input)
   - weekly cron (Sunday 06:00 UTC)
   - push to `main` when `src/` / `lib/` / loop script change
   - **not** on every PR / not in default `make test`
5. Verified: `make selfhost-loop` PASS (determinism)

---

## Сесия 49 (LSP 0.13 textDocument/implementation)

1. **`implementationProvider`** + `textDocument/implementation`
2. **Interface type** under cursor → locations of implementing types
   (`extend Type for Iface` / type decl)
3. **Interface method** under cursor → implementor method decls
   (reuses `collectImplementorFuncs` + `workspaceImpls`)
4. Also: call-site / shared method name matching known iface methods;
   implementor method → sibling implementors of same iface method
5. Smoke: `tools/smoke_lsp_implementation.sh`
   - Drawable → ≥2 types; Draw → ≥2 methods (Circle + Square)
6. Version **bux-lsp 0.13.0**; `make test-lsp`

---

## Сесия 50 (LSP 0.14 workspace import path index)

1. **`workspaceImportPaths`**: URI → full import paths (`["Std","Io"]`)
2. **`registerWorkspaceImports`** at end of `analyzeFile` (scan + open/edit)
3. **`isKnownImportPathPrefix`** uses workspace index first — no open doc required
4. Path segment snapshot fix (no shared seq mutation across segments)
5. Smoke: `tools/smoke_lsp_workspace_imports.sh`
   - only Main opened; Util closed on disk via `rootUri` scan
   - Io→Net ≥2 edits including `Util.bux` in WorkspaceEdit
6. Version **bux-lsp 0.14.0**; `make test-lsp`

---

## Сесия 51 (Expr/Stmt sourceFile for multi-file / macros)

1. **`Expr.sourceFile` / `Stmt.sourceFile` / `Block.sourceFile`**
2. **`Ast_StampExprFile` / `Ast_StampStmtFile` / `Ast_StampBlockFile` /
   `Ast_StampPatternFile`** — fill empty slots only (grafted nodes keep path)
3. **`Cli_StampSourceFile`** stamps decl body + const init + default params
4. **Lower:** `Lcx_SetNodeLoc` / `Lcx_SourceFileFor` prefer AST file, else
   `currentSourceFile`; `Lcx_StampSourceFile` still fills empties at func end
5. Smoke: Main body `#line` → Main.bux only (no Util leak); Util isolation kept
6. Rebuild selfhost; `make test-selfhost-smoke`

---

## Сесия 52 (selfhost fixed-point buxc2→buxc3→buxc4 green)

1. **Sema global scope:** allocate via `Scope_New` (8192), not 1024 — heap
   overflow on ~1200 decls crashed buxc2 in `Scope_Lookup`
2. **HIR buffers:** funcs 512→4096, structs 64→512, enums/consts/gen* raised
3. **`CBE_FuncParam`:** avoid nested `.paramN.name` on `*HirParam` (wrong `.` vs `->`)
4. **Adapters:** `__fat_env` not `env` (no clash with `CtfeEnv* env`)
5. **Unary `!`:** parenthesize operand so `!(a && b)` ≠ `!a && b`
6. **Fat typedef skip-void:** rewritten without nested `!` for older gens
7. **Fixed-point loop:** compare gen2 vs gen3 (same CBE), not bootstrap vs selfhost
8. Verified: `BUX_SELFHOST_FIXED_POINT=1 make selfhost-loop` — C+ELF IDENTICAL

---

## Сесия 53 (main CI workflow — `make test`)

1. **`.github/workflows/ci.yml`**
   - triggers: `pull_request`, `push` to `main`, `workflow_dispatch`
   - job: install Nim 2.0.x + gcc/make/ssl → **`make test`**
   - timeout 90m; concurrency cancel-in-progress
   - failure artifact: selfhost `main.c` (best-effort)
2. **selfhost-loop.yml** remains optional (not on every PR)
3. Docs: README / BuildAndTest / QUALITY_PLAN point to ci vs selfhost-loop

---

## Сесия 54 (LSP 0.15 type hierarchy)

1. **`typeHierarchyProvider`** + prepare / supertypes / subtypes
2. **prepare** on `struct` / `enum` / `interface` / `type` → TypeHierarchyItem
3. **subtypes** of interface → types with `extend T for I` (Circle, Square)
4. **supertypes** of type → interfaces it implements
5. Uses open-doc `impls` + `workspaceImpls` + symbol resolve
6. Smoke: `tools/smoke_lsp_type_hierarchy.sh`
7. Version **bux-lsp 0.15.0**; `make test-lsp`

---

## Сесия 55 (macro / quote hygiene foundation)

1. **AST graft API** (force overwrite): `Ast_GraftExpr/Stmt/Block/PatternFile`
2. **Clone**: `Ast_CloneExpr/Stmt/Block/Pattern` (+ list / match arms)
3. **Quote policies**:
   - `Ast_QuoteDefSite` — clone, keep `sourceFile` (macro body / template)
   - `Ast_QuoteCallSite` / `Ast_QuoteStmtCallSite` — clone + graft call-site path
4. **Helpers**: `Ast_SetExprLoc` / `Ast_ExprSourceFile`
5. **HIR**: `Lcx_GraftSourceFile`; mono instances force-graft `genDecl.sourceFile`
6. Smoke: `tools/smoke_graft_hygiene.sh` (Array mono → lib; Main no leak)
7. Wired into `make test-selfhost-smoke`

---

## Сесия 56 (CBE binary parentheses — C precedence safety)

1. **Bug (selfhost):** tree HIR→C emitted nested binaries **without** parens.
   - `return (a + b) * c` → C `return a + b * c;` → **7** instead of **9**
   - `return (a - b) / c` → `a - b / c` → **8** instead of **3**
2. **Fix selfhost** (`src/c_backend.bux`):
   - `hBinary` always emits `(left op right)` (same policy as bootstrap HIR CBE)
   - Unary operand parens (session 52) kept: `!(a && b)`
3. **Bootstrap LIR** (`bootstrap/lir_c_backend.nim`): defensive parens on
   arith/bitwise and unary `!`/`-`/`~` (operands are temps today; future-proof)
4. **Example:** `examples/c_precedence.bux` — MulSum/SubDiv/ShiftSum/Mix
5. **Smoke:** `tools/smoke_selfhost.sh` checks run values **and** generated C
   contains `(a + b) * c` / `(a - b) / c`
6. Wired into `EXAMPLES` + `make test-selfhost-smoke`
7. Verified: bootstrap + **buxc2** → `9/3/6/7` + `PASS c_precedence`;
   smoke PASS

---

## Сесия 57 (CI split jobs + macOS smoke)

1. **`.github/workflows/ci.yml`** — no longer one 90m monolithic `make test`:
   - **`build`** (ubuntu): `make build` → artifact `buxc-linux`
   - **Parallel** (reuse artifact, `BUX_SKIP_BUILD=1`):
     - `unit` — `fmt-check` + `test-unit`
     - `examples` — `test-examples`
     - `goldens` — errors + stdlib + registry + dwarf
     - `apps` — `test-apps`
     - `selfhost` — `test-selfhost-smoke`
   - **`macos`**: Homebrew OpenSSL + rebuild + fmt/unit/examples
   - **`ci-gate`**: single required status (all of the above must succeed)
2. **Makefile:**
   - `test-unit` extracted from `test`
   - `ensure-buxc` + `BUX_SKIP_BUILD=1` for CI artifact reuse
   - `$(OUT)` rebuild only when `bootstrap/*.nim` changes
   - portable examples runner (optional `timeout`; macOS without coreutils OK)
3. **macOS / non-GNU ld:**
   - bootstrap: `-Wl,--build-id=none` only `when defined(linux)`
   - selfhost: `bux_cc_ld_stable()` in `rt/runtime.c` (Linux-only build-id)
   - CI sets `BUX_CFLAGS=-I… -L…` for Homebrew `libcrypto`
4. Docs: BuildAndTest + README CI table; local `make test` still full sequential
5. Verified locally: `BUX_SKIP_BUILD=1 make fmt-check test-unit test-errors`

---

## Сесия 58 (LSP 0.16 workspace type hierarchy index)

1. **Gap:** type hierarchy subtypes/supertypes only saw open-doc `impls` or
   method-keyed `workspaceImpls`. Closed files with **empty**
   `extend T for I {}` (no methods) returned **[]**.
2. **`workspaceTypeRels`** (`tools/lsp_server.nim`):
   - URI → `seq[(typeName, iface, line)]` from every `analyzeFile`
   - `registerWorkspaceTypeRels` replaces per-URI (re-open / re-scan safe)
   - filled on `scanWorkspace` + open/edit — **no open doc required**
3. **Consumers:**
   - `collectSubtypeItems` / `collectSupertypeItems` prefer type-rel index
   - `collectTypeImplementorLocs` (textDocument/implementation) same
4. **Smoke:** `tools/smoke_lsp_type_hierarchy_ws.sh`
   - open only Main; Drawable.bux + Shapes.bux closed
   - empty extends → Drawable subtypes Circle+Square; Circle supers Drawable+Named
5. Version **bux-lsp 0.16.0**; wired into `make test-lsp`
6. Verified: single-file hierarchy + workspace smoke PASS

---

## Сесия 59 (user-facing `macro!` / `quote!` — declarative MVP)

1. **Syntax (bootstrap):**
   - `macro! name { ($x:expr, …) => { template } }`
   - Invoke: `name!(args…)` — distinct from unwrap `expr!` via following `(`
   - Built-in **`quote!(e)`** — identity expand + call-site graft
2. **Lexer:** keyword `macro`; `$ident` fragment tokens (`$x`)
3. **AST:** `dkMacro` + `MacroRule`/`MacroFragment`; `ekMacroCall`
4. **Expansion** (`bootstrap/macroexpand.nim`) before sema:
   - Collect macro decls; match rule by arity
   - Deep clone + substitute `$frags` + graft call-site `SourceLocation`
   - Nested expand (depth ≤ 32)
5. **CLI:** `build` / `check` / `run` call `expandMacros` after merge
6. **Example:** `examples/macro_twice.bux` → 42 / 42 / 43 + PASS
7. **LanguageRef:** Macros section (limits documented)
8. Verified: `./buxc run macro_twice`; hello + lexer/parser tests green
9. **Not yet:** selfhost expand parity; `$(…)*` repetition; more frag kinds

---

## Сесия 60 (selfhost `macro!` / `quote!` expand parity)

1. **Lexer/token:** `tkMacro`, keyword `macro`, `$ident` fragments
2. **AST:** `dkMacro` (rules in `childDecl1` chain), `ekMacroCall`
3. **Parser:** `macro! name { ($x:expr) => {…} }`, invoke `name!(…)`
4. **`src/macroexpand.bux`:**
   - collect macros → match rule by arity → clone+subst `$frags`
   - call-site graft (line/col/`sourceFile`)
   - built-in `quote!(e)`
5. **CLI:** expand before sema (project / check / compile paths)
6. **Sema fixes** (needed for block templates):
   - `ekBlock` value = last `skExpr` type (was always `tyVoid`)
   - `let x: T = …` sets `sym.typeKind` from annotation (not only init)
7. **Smoke:** `tools/smoke_selfhost.sh` runs `examples/macro_twice.bux` via buxc2
8. Verified: **buxc2** + bootstrap → `42/42/43` + `PASS macro_twice`

---

## Сесия 61 (macro `$(…)*` + `ident`/`tt` fragments)

1. **Fragment kinds:** `expr` | `ident` | `tt` (tt ≡ expr for now)
2. **Pattern rep (trailing):** `$( $x:expr ),*` / `$( $x:expr )*`
3. **Template rep:** `$( stmts… )*` → `skMacroRep`, expanded per list item
4. **Lexer:** bare `tkDollar` for `$(…)` (vs `$ident`)
5. **Bootstrap** `macroexpand.nim`: list bindings, match rules, gensym locals
6. **Selfhost** parity: `useNames` encodes kinds/`rep:`, `Subst_Block_Flat`, gensym
7. **Sema:** block-as-expr checks last value **inside** child scope (no UAF of locals)
8. **Example:** `examples/macro_repeat.bux` — sum_n / empty / call0 / id_tt
9. Verified: bootstrap + **buxc2** → `6/0/42/7` + `PASS macro_repeat`

---

## Сесия 62 (C.4 `@[Release]` polish + Checked docs)

1. **Three-tier model** documented in LanguageRef:
   - default (no checks) → `@[Checked]` → `@[Release]` (force off)
2. **Bootstrap:** `releaseFunc`; `checkedFunc = Checked ∧ ¬Release`
3. **Selfhost:** same rule; **stacked attrs** loop (`@[Checked]` + `@[Release]`)
4. **Parser:** multi-line stacked `@[…]` (skip newlines between attrs)
5. **Tests** (`borrow_test`): Release alone; Checked+Release wins; Checked still errors
6. **Example:** `examples/ownership_release.bux` — Unchecked / Safe / Hot / HotDangle
7. Verified: 27/27 borrow tests; example PASS

---

## Сесия 63 (nested `$(…)*` / multi-rep / compound zip)

1. **Bootstrap** (`macroexpand.nim` + parser):
   - Compound rep: `$( $a:expr, $b:expr ),*` → parallel lists, zip in template
   - Multi-rep: `$(…)* ; $(…)*` with call-site `;` groups (`exprMacroGroupLens`)
   - Nested template: outer binds list → inner `$(…)*` expands once (no list names left)
   - `MacroFragment.names` / `.kinds` for multi-name frags
2. **Selfhost** parity (`src/macroexpand.bux`, `parser.bux`):
   - Two named rep lists + zip in `Subst_Block_Flat`
   - Kinds encoding `rep:expr+expr,@2` / multi-seg `rep:…;rep:…`
   - Macro call `;` groups → `genericCallee` group-length string
3. **Example:** `examples/macro_nested.bux`
   - `add_pairs` → 33, `sum_groups` → 63, `double_each_sum` → 14, `named_sum` → 18
4. **LanguageRef:** multi-rep / compound / nested docs; limits updated
5. Verified: bootstrap + **buxc2** → PASS macro_nested / macro_repeat / macro_twice

---

## Сесия 64 (CI Nim cache + faster macOS)

1. **Nim pin + toolchain cache:**
   - `NIM_VERSION: 2.0.8` (stable cache keys; was `2.0.x`)
   - Cache `.nim_runtime` on `build` / `unit` / `macos` / `selfhost-loop`
   - Skip `setup-nim-action` on cache hit; restore `PATH` only
2. **`nimcache` project-local:**
   - `Makefile` `NIMFLAGS ?= --nimcache:nimcache` for bootstrap + unit tests
   - `actions/cache` keyed on `bootstrap/**/*.nim` (+ tests for unit)
3. **Leaner macOS job:**
   - Runner `macos-14`; timeout 35m
   - `make test-unit` + `make test-examples-smoke` (not full EXAMPLES / not fmt)
   - `EXAMPLES_SMOKE`: hello, ownership*, strings, map, c_precedence, macro_*
   - OpenSSL: install only if missing (`brew list`)
4. **Docs:** BuildAndTest CI table; `.gitignore` `.nim_runtime/`
5. Verified locally: `make build` uses `nimcache/`; `test-examples-smoke` PASS

---

## Сесия 65 (Drop / RAII docs — field-move story)

1. **LanguageRef — Drop and RAII** (under Gradual Ownership):
   - `@[Drop]` vs `extend T for Drop` (static `Type_Drop`, no vtable)
   - When auto-drop runs (block end, early return, branches) — not gated on Checked
   - **Field-move skip Drop** with `MakeBox` + simplified C (no `Array_Drop(&items)`)
   - Move-on-return, assignment, call-arg transfers; error-path still Drops
   - Limits: whole-local moves, static dispatch, manual free pitfalls
2. **TOC** links Ownership + Drop; **Stdlib** `Array_Drop` + `Std::Drop` section
3. **README** Drop line mentions field-move
4. Cross-refs: `examples/move_field.bux`, `examples/drop_early_return.bux`,
   selfhost smoke
5. Verified: `move_field` C has no `Array_Drop` on moved `items`; example PASS

---

## Сесия 66 (macro hygiene + frag kinds `literal` / `block`)

1. **Fragment kinds** (bootstrap + selfhost):
   - `literal` / `lit` — only `ekLiteral` (rejects `1 + 2`)
   - `block` — only `ekBlock` `{ … }`
   - Shared `fragMatches` / `Macro_FragMatches` at match time
2. **Hygiene gensym:**
   - Bootstrap: also rename **`for` binders**; walk for bodies in collect
   - Selfhost: gensym `skFor` + recurse if/while/for/MacroRep bodies
   - CBE: two `with_acc!` → `__m1_n` / `__m2_n` (no collision)
3. **Example:** `examples/macro_hygiene.bux` → 11/21/7/3/42 + PASS
4. **LanguageRef:** kind table + hygiene layers (graft + gensym)
5. **Makefile:** `macro_hygiene` in EXAMPLES + EXAMPLES_SMOKE
6. Verified: bootstrap + **buxc2**; negative `only_lit!(1+2)` → no matching rule

---

## Сесия 67 (CI Windows smoke)

1. **`.github/workflows/ci.yml` — `windows` job** (`windows-latest`, bash shell):
   - Cache Nim **2.0.8** (prebuilt zip — fast) + `nimcache`
   - `nim c -o:buxc.exe` bootstrap
   - Pure Nim unit tests: lexer / parser / sema / hir / borrow
   - CLI smoke: `buxc.exe new` + `--version`
2. **Scope (honest):** no `bux run` examples on Windows yet —
   `rt/runtime.c` is POSIX (`ucontext`, `pthread`, sockets, OpenSSL link).
   Job still gates bootstrap regressions on Win.
3. **`ci-gate`:** `windows` is a required job
4. **Docs:** BuildAndTest CI table + Windows note
5. Locally: YAML validated; full Win run is on GHA only

---

## Сесия 68 (partial field moves + Drop goldens)

1. **Bug:** `return bag.items` still ran `Bag_Drop(&bag)` → double-free /
   corrupt Array (ASSERT fail). Also dead double-Drop after terminal `return`.
2. **Bootstrap** (`hir_lower.nim`):
   - `markMovedOutFromAst` handles `ekField` when **field type is droppable**
     (`autoDropFuncName`) — not for `return a.id` (int)
   - Scope exit: skip re-emitting drops when last stmt always-returns; pop defers
3. **Selfhost** (`c_backend.bux`):
   - `CBE_MarkMovedFromNodeHint` + droppable type check; return uses `currentRetType`
   - Store/let rhs walks field access for partial moves
4. **Example + golden smoke:**
   - `examples/move_field_partial.bux`
   - `tools/smoke_drop_move.sh` + `make test-drop-move` (CI goldens job)
5. Verified: partial PASS; `TakeItems` has **no** `Bag_Drop`; drop_early_return 5;
   move_field PASS

---

## Сесия 69 (macro unhygienic binders)

1. **Problem:** gensym renamed *all* template `let`/`var` binders, so
   `var $name: int = …` with `$name:ident` could not introduce a call-site name.
2. **Bootstrap** (`macroexpand.nim`):
   - `binderIdentFromFrag` + `expandUnhygienic` set
   - `substStmt`: rewrite `skLet`/`skFor` binder when name is `$frag` → ekIdent
   - `collectLetNames` skips unhygienic names
3. **Selfhost** (`macroexpand.bux`):
   - `Env_AddUnhy` / `Env_IsUnhy` / `Env_BinderFromFrag`
   - `Subst_Stmt` rewrites binders; `Macro_GensymBlock(ex, body, env)` skips them
4. **Example:** `examples/macro_unhygienic.bux` → 11/21/6/10/1 + PASS
   - C: `counter` / `other` / `n` kept; `acc` / `scratch` → `__mN_*`
5. **LanguageRef:** unhygienic binder table; EXAMPLES + EXAMPLES_SMOKE
6. Verified: bootstrap + **buxc2**; macro_hygiene still PASS

---

## Сесия 70 (per-field Drop + mono defer restore)

1. **Bug (critical):** `lowerFunc` restored `deferStmts` / `movedOutLocals` only
   when the *inner* mono function still had pending defers. Nested
   `generateMethodInstance` → `lowerFunc` (e.g. `Array_Len` inside
   `PeekTagAndTake`) wiped the caller's Drop stack → leaked moved Arrays.
2. **Fix bootstrap:** always restore `deferStmts` / `movedOutLocals` /
   `partialMovedFields` after lowering a function body.
3. **Per-field Drop after partial move:**
   - Track `partialMovedFields: local → {field names}`
   - Skip parent `Type_Drop`; emit Drop for **remaining** droppable fields
   - `emitDropOrPartial` at return / block exit / function tail
4. **Selfhost CBE** (`c_backend.bux`):
   - partial (var, field) slots + local type registry on `hAlloca`
   - `CBE_EmitRemainingFieldDrops` when skipping moved parent Drop
5. **Example + smoke:**
   - `examples/move_field_remaining.bux` (PairBag left move → Tracked_Drop right)
   - `tools/smoke_drop_move.sh` checks PeekTag Array_Drop + remaining Tracked_Drop
6. **LanguageRef:** remaining-field rule; limits updated
7. Verified: bootstrap + **buxc2** remaining/partial/move_field; smoke; EXAMPLES

---

## Сесия 71 (Windows MinGW + `hello` smoke)

1. **`rt/runtime_win.c`** — minimal runtime without pthread / ucontext / sockets /
   OpenSSL. Real alloc, strings, files, time, env; stubs for tasks/crypto/net.
2. **Bootstrap CLI** (`bootstrap/cli.nim`):
   - Windows (or `BUX_RUNTIME=win`) copies `runtime_win.c` instead of `runtime.c`
   - Link: `-ffunction-sections -Wl,--gc-sections -lm` (no `-pthread` / `-lcrypto`)
   - Host `gcc` on Windows; `.exe` suffix on build/run
   - Fixed: `-l` libs **after** `.c` inputs (GNU ld order)
3. **CI** (`.github/workflows/ci.yml` windows job):
   - MinGW via `msys2/setup-msys2` (`mingw-w64-x86_64-gcc`)
   - `tools/smoke_windows_hello.sh` after unit/CLI smoke
4. **Docs:** BuildAndTest CI table + `rt/` tree
5. Verified locally: normal `hello` + `BUX_RUNTIME=win` smoke PASS

---

## Сесия 72 (macro `stmt` / `pat` fragments)

1. **Kinds:** `mfkStmt` / `mfkPat` (+ aliases `pattern`, `lit` already)
2. **AST wrappers:** `ekMacroStmt` / `ekMacroPat` (expand-only)
3. **Call-site parse:**
   - stmt keywords → `parseStmt` → MacroStmt
   - `_` → `parsePattern` → MacroPat
   - else expr; `pat` coerces via `exprToPattern` (ident/lit/path/call/tuple/struct/range)
4. **Expand:**
   - `coerceArg` at match; store normalized MacroStmt/MacroPat
   - `$s` as skExpr splices MacroStmt into the statement list
   - `$p` as pkIdent pattern substitutes bound MacroPat
5. **Selfhost:** same kinds, coerce, splice, pattern subst
6. **Example:** `examples/macro_stmt_pat.bux` — setup/do_twice/matches/if_let_like
7. LanguageRef kind table + docs
8. Verified: bootstrap + **buxc2** `macro_stmt_pat` PASS

---

## Сесия 73 (nested `a.b.c` field-move Drop)

1. **Bootstrap** (`hir_lower.nim`):
   - `fieldPathFromAst` → base local + path `@["inner","items"]`
   - `partialMovedFields` stores **dotted paths** (`"inner.items"`)
   - `remainingDropsAt` recursive: exact path = skip; prefix = recurse;
     other droppable fields → `Type_Drop(&(base.a.b))`
   - Typed intermediate `hFieldAccess` so LIR/C keep `Inner` not `int`
2. **Selfhost CBE:** full dotted path on mark; recursive `CBE_EmitRemainingAt`
3. **Example:** `examples/move_field_nested.bux` — `outer.inner.items` → 2 Tracked drops
4. Smoke + EXAMPLES; LanguageRef nested path section
5. Selfhost: recursive remaining drops + skip Drop when `HasPartialMoved`
   (struct emit multi-pass topo for Outer{Inner})
6. Verified: bootstrap + **buxc2** `nested_drops=4` PASS; full `test-drop-move`

---

## Сесия 74 (field moves through pointers)

1. **Pointer aliases:** `let p = &bag` / `p = &bag` → `ptrAliases[p] = bag`
2. **fieldPathFromAst:** peel `(*p)` (ekUnary tkStar); resolve alias to owner
3. **`p.field`** (auto-deref) and **`(*p).field`** mark owner + path
4. Nested via ptr: `p.inner.items` → owner + `"inner.items"`
5. Selfhost CBE: alias slots + resolve in `CBE_BaseVarName`; record on store/assign
6. **Example:** `examples/move_field_ptr.bux` → `ptr_drops=5`
7. Smoke + LanguageRef; limits: local aliases only (not cross-function params)
8. Selfhost: unary C parens fix `(*p).field`; alias slots + BaseVar resolve
9. Verified: bootstrap + **buxc2** `ptr_drops=5` PASS; full `test-drop-move`

---

## Платформен фокус (v0.5 → v1.0 ✅)

| Ниша | Какво значи за Bux | Статус / посока |
|------|--------------------|-----------------|
| **Linux** | Host + CI + full `rt/runtime.c` (pthread, ucontext, sockets, OpenSSL) | ✅ primary; macOS secondary smoke only |
| **Cloud-native** | HTTP/HTTPS, registry (lock+HTTPS), containers, musl docs | ✅ sessions 75–79 |
| **Embedded** | Cross (`--target`), CTFE tables, **thin runtime**, no-GC story | ✅ minimal + aarch64 + riscv64 smoke (85) + freestanding notes; bare-metal still spike |
| **Windows** | Не е product target | ⛔ no further investment (existing MinGW hello = historical) |

**Правило:** нов runtime / stdlib / CI effort отива към Linux + cloud + embedded. Windows-only work не влиза в следващи сесии.

---

## Сесия 75 (Linux / cloud / embedded foundation)

1. **`rt/runtime_minimal.c`** — thin runtime (no pthread / ucontext / sockets / OpenSSL);
   same feature surface as historical `runtime_win.c`, documented for Linux static/embed.
2. **Bootstrap CLI** (`bootstrap/cli.nim`):
   - `BUX_RUNTIME=full|minimal|thin|embed|win`
   - `--static` / `BUX_STATIC=1` → fully-static link; defaults to minimal runtime
   - `--target <triple>` → prefers `<triple>-gcc`, else `clang -target`; defaults minimal
   - `BUX_CC` override; thin link uses `-ffunction-sections -Wl,--gc-sections -lm`
3. **CTFE bitwise + hex** (`bootstrap/sema.nim`):
   - `^` `&` `|` `<<` `>>` in const eval
   - `0x` / `0b` / `0o` integer literals in CTFE
4. **Example** `examples/ctfe_crc.bux` — recursive CRC-8 table cells + `Pow2(8)` size
5. **Smoke** `tools/smoke_linux_targets.sh` / `make test-linux-targets`:
   - minimal hello run
   - `--static --release` + `file` statically linked
   - `--target aarch64-linux-gnu` when cross-gcc present
   - ctfe_crc under minimal
6. **Container** `examples/docker/Dockerfile.static` + `tools/build_static_hello.sh`
7. **CI** goldens job installs `gcc-aarch64-linux-gnu` and runs `test-linux-targets`
8. Docs: BuildAndTest + QUALITY_PLAN platform section

**Verified:** smoke 4/4 PASS; CRC_1=`#define 7`; aarch64 static ELF.

---

## Сесия 76 (P0: ownership + macros + selfhost parity)

1. **Cross-function pointer ownership** (`bootstrap/hir_lower.nim`):
   - `TakeItems(&bag)` where callee does `return p.items` / `let x = p.items`
   - Call site marks owner `bag` + partial path `items`; remaining fields still Drop
   - Example `examples/move_cross_fn.bux` + smoke in `test-drop-move`
2. **Macro `$x:tt`** — broader than `expr`: any single call-site AST fragment
   (bootstrap + selfhost); example `examples/macro_tt.bux`
3. **Selfhost link parity** (`src/cli.bux`):
   - `--static`, `--target`, `BUX_RUNTIME`, `BUX_CC`, `BUX_STATIC`
   - `Cli_LinkProgram` shared by single-file + project builds
   - Thin runtime → no pthread/OpenSSL; full → POSIX as before
4. Docs: LanguageRef tt + QUALITY_PLAN

**Verified:** move_cross_fn PASS; macro_tt PASS; smoke_drop_move; buxc2 `--static project` → static ELF + `Hello, Bux!`.

---

## Сесия 77 (selfhost cross-fn + Nexus production polish)

1. **Selfhost cross-fn ownership** (`src/c_backend.bux`):
   - `CBE_MarkCrossFuncFromCall` scans callee HIR for `p.field` moves
   - Call site `TakeItems(&bag)` → partial move on `bag` (no double-free)
   - Verified: `buxc2 run move_cross_fn` → `cross_fn_drops=2` PASS
2. **Runtime stop handlers** (`rt/runtime.c`):
   - `bux_install_stop_handlers` / `bux_should_stop` / `bux_set_stop_listen_fd`
   - SIGINT/SIGTERM set flag + close listen fd (unblock accept)
   - Thin/win runtimes: no-op stubs
3. **Stdlib** `Os_InstallStopHandlers` / `Os_ShouldStop` / `Os_SetStopListenFd`
4. **Nexus 0.4.0**:
   - Graceful stop: main=acceptor; poison workers (`fd=-1`); exit on SIGTERM
   - Access log: `METHOD path status ms` (`NEXUS_ACCESS_LOG`)
   - Max body: `NEXUS_MAX_BODY` (default 1 MiB) → 413
   - Config fields + `/api/health` version 0.4.0
5. TLS deferred (needs SSL context in runtime — not this session)

**Verified:** SIGTERM exits nexus; health JSON 0.4.0; access log lines; selfhost cross_fn.

---

## Сесия 78 (Nexus TLS + container story)

1. **Runtime TLS** (`rt/runtime.c` + OpenSSL `libssl`):
   - `bux_tls_server_ctx` / `accept` / `send` / `recv` / `close` / `error`
   - Thin/win: stubs; full POSIX links **`-lssl -lcrypto`**
2. **Stdlib** `Std::Net` — `Tls_ServerCtx`, `Tls_Accept`, `Tls_Send`, `Tls_Recv`, …
3. **Nexus 0.5.0**:
   - `NEXUS_TLS=1` + `NEXUS_TLS_CERT` / `NEXUS_TLS_KEY` (PEM)
   - `ConnectionTask.tls` handle; `ConnRecv`/`ConnSend` dual plain/TLS
   - Banner `https://` when TLS; SIGTERM still graceful
4. **Smoke** `tools/smoke_nexus_tls.sh` / `make test-nexus-tls` (openssl self-signed + curl -k)
5. **Containers**:
   - `examples/docker/Dockerfile.nexus` (debian-slim + libssl3)
   - `examples/http_health.bux` + `Dockerfile.health` + `tools/build_health_bin.sh`
6. CLI link flags bootstrap + selfhost: `-lssl -lcrypto`

**Verified:** `curl -k https://…/api/health` → 0.5.0; SIGTERM exit; health binary HTTP.

---

## Сесия 79 (registry lock/HTTPS + musl path)

1. **`bux install` lock checksums** — sha1 of sorted `*.bux` sources per package
2. **`bux install --locked`** — CI mode: verify paths + checksums; no re-resolve
3. **`BUX_REGISTRY_INSECURE=1`** — self-signed HTTPS registry fetch (`curl -k`)
4. **Smoke** `tools/smoke_registry.sh`:
   - lock deterministic (diff two installs)
   - `--locked` ok / missing fail / checksum mismatch fail
   - HTTP + **HTTPS** self-signed index
5. **musl path** `tools/smoke_musl_static.sh` / `make test-musl-static`
   - `BUX_CC=musl-gcc` or zig musl wrapper + `BUX_RUNTIME=minimal --static`
   - SKIP when toolchain absent (documented)
6. Docs: Packages.md lock section; BuildAndTest musl; Dockerfile.alpine-health

**Verified:** registry smoke full PASS; musl SKIP (no toolchain on host).

---

## Сесия 80 (selfhost install --locked + Nexus mTLS)

1. **Selfhost `install` / `install --locked`** (`src/cli.bux`):
   - Write `bux.lock` with sha1 checksums (shell `sha1sum` of sorted `*.bux`)
   - `--locked` verifies paths + checksums (CI parity with bootstrap session 79)
   - Manifest: parse `[Dependencies]` + `{ Path = "..." }` inline tables
2. **mTLS** (`rt/runtime.c` `bux_tls_server_ctx_ex`):
   - Optional client CA → `SSL_VERIFY_PEER | FAIL_IF_NO_PEER_CERT`
   - `Tls_ServerCtxMtls` in `Std::Net`
   - Nexus `NEXUS_TLS_CLIENT_CA` → require client certs (v0.6.0)
3. **Smokes**: `tools/smoke_selfhost_install.sh`, `tools/smoke_nexus_mtls.sh`
   - `make test-selfhost-install` / `make test-nexus-mtls`

**Verified:** selfhost lock/locked/mismatch; mTLS reject without cert + accept with cert.

---

## Сесия 81 (selfhost full registry)

1. **`src/registry.bux`** — load index from `$BUX_REGISTRY` / `~/.bux` / `config/registry.toml`
   - HTTP(S) fetch via curl/wget → `~/.bux/cache/registry_http.toml`
   - `BUX_REGISTRY_REFRESH`, `BUX_REGISTRY_INSECURE` (parity with bootstrap)
2. **CLI** `search` / `add <name>` / `add <name> <version|url>`
3. **Build path deps** — merge `depUrl` absolute/relative package `src/` (not only `deps/`)
4. **Runtime discovery** — `BUX_STDLIB/../rt` when building outside the monorepo tree
5. **Smoke** `tools/smoke_selfhost_registry.sh` / `make test-selfhost-registry`

**Verified:** search greet; add+install+run Hello, Bux!; HTTP registry search.

---

## Сесия 82 (CI cloud/selfhost smokes + polish)

1. **CI apps job** — `test-nexus-tls` + `test-nexus-mtls` (openssl + curl)
2. **CI selfhost job** — `test-selfhost-install` + `test-selfhost-registry`
3. **Registry paths** — `expandFilename` for file:/path: sources (no `..` in lock)
4. Docs already cover sessions 75–81 platform stack

**Verified:** local smokes previously green; CI wiring ready for GHA.

---

## Сесия 83 (stdlib daily API — collections_extra)

1. **Array** (`lib/Array.bux`):
   - `Array_RemoveAt` — shift-left remove, returns value
   - `Array_Insert` — insert at `0..=len` (append at end)
   - `Array_SwapRemove` — O(1) unordered remove
   - `Array_Clone` — shallow value clone into new buffer
2. **String** (`lib/String.bux`):
   - `String_Cmp` — `strcmp` wrapper
   - `String_IndexOf` — byte index or `-1`
   - `String_ToUpper` / `String_ToLower` — ASCII only via StringBuilder
3. **Map** (`lib/Map.bux`):
   - `Map_GetOr` / `StringMap_GetOr` — default when key missing
4. **Example** `examples/collections_extra.bux` + Makefile `EXAMPLES`
5. **Goldens** `tests/stdlib_golden/{array,string}` extended
6. **Docs** `docs/Stdlib.md` tables updated

**Verified:** `collections_extra` PASS; `make test-stdlib` 3/3 PASS.

---

## Сесия 84 (macro raw `tt` groups + expression-level `$(…),*`)

1. **Delimiter-balanced `:tt` groups** (bootstrap + selfhost):
   - `$args:tt` that is a multi-element tuple `(a, b)` is wrapped as `ekMacroTt` with group flag
   - Splice `$f($args)` flattens to `f(a, b)` (not `f((a, b))`)
   - Value-position splice unwraps to the inner tuple / fragment
   - Contrast `:expr` keeps the tuple as one argument
2. **Expression-level rep in templates:**
   - Parse `$( expr ),*` / `$( expr )*` inside **call argument lists** when `macroTemplateMode`
   - `ekMacroRep` expands to N call args (zip list fragments)
   - Example: `apply_rep!(Add3, 1, 2, 3)` → `Add3(1, 2, 3)`
3. **Example** `examples/macro_tt_raw.bux` + Makefile EXAMPLES / EXAMPLES_SMOKE
4. **Docs** LanguageRef tt + expression-level rep + limits
5. **Hardening:** `CBE_NormalizeTypeName` / `String_StartsWith` null-safe
   (fixed selfhost segfault on `if_let_like` + enum field-move path)

**Verified:** bootstrap + **buxc2** `macro_tt_raw` PASS; `macro_stmt_pat` PASS; macro regressions OK.

---

## Сесия 85 (riscv64 cross smoke + freestanding notes + slice `:tt`)

1. **riscv64 cross smoke** (`tools/smoke_linux_targets.sh`):
   - Shared `try_cross` helper for aarch64 + riscv64
   - `PASS` when `${triple}-gcc` present; **SKIP** otherwise (no false fail)
   - Documented: clang `-target` alone needs a sysroot
2. **Freestanding / bare-metal research** (`docs/BuildAndTest.md`):
   - Table: thin/static/cross ✅ vs true freestanding / Cortex-M 🔬
   - Clarifies `runtime_minimal` still uses libc (not no-libc)
3. **Delimiter-balanced `:tt` + slice lit** (session 84 extension):
   - `[a, b]` slice groups flatten like tuples in `$f($args)`
   - Selfhost parser: primary `[a, b, …]` → `ekSlice` (parity with bootstrap)
   - `examples/macro_tt_raw.bux` case `apply_tt!(Add, [8, 9])` → 17
4. Docs: LanguageRef, BuildAndTest, Makefile target blurb

**Verified:** `make test-linux-targets` — minimal/static/aarch64/ctfe PASS; riscv64 SKIP;
bootstrap + **buxc2** `macro_tt_raw` (incl. slice) PASS.

---

## Сесия 86 (free-form juxta `:tt` paste)

1. **Pattern juxtaposition:** `$f:ident $args:tt` without comma between fragments
   (bootstrap + selfhost parser continue on next `$…`)
2. **Expand-time call split:** when rule is exactly two fixed frags `ident` + `tt`
   and the call site has **one** arg that is `ekCall` with ident callee:
   - bind `$f` → callee
   - bind `$args` → MacroTt group of the call’s arguments
   - `$f($args)` flattens as before → `f(a, b)`
3. **Example** `apply_juxta!(Add(2, 5))` / `apply_juxta!(Add3(1, 2, 4))` in
   `examples/macro_tt_raw.bux`
4. LanguageRef juxta section; comma form still works

**Verified:** bootstrap + **buxc2** `macro_tt_raw` (h=7, i=7) PASS; macro regressions OK.

---

## Сесия 87 (`:type` fragments + Array_Reverse / Test_AssertNeqString)

1. **Macro `$t:type`** (bootstrap + selfhost):
   - Fragment kind `type` (`type` is a keyword — special-cased in parsers)
   - Call-site coerce: `int` → named; `*int` → pointer
   - Subst into `sizeof($t)`, `as $t`, `let x: $t`
2. **Example** `examples/macro_type.bux` — size_of / cast_zero + reverse/neq
3. **Stdlib:** `Array_Reverse`, `Test_AssertNeqString`
4. Docs: LanguageRef type table; Stdlib Array_Reverse

**Verified:** bootstrap + **buxc2** `macro_type` PASS (sizeof int=4, *int=8).

---

## Сесия 88 (v1.0.0 language freeze)

1. Version banners: bootstrap + selfhost CLI → **1.0.0**; root `bux.toml` → 1.0.0
2. `docs/SEMVER.md` — **Active** (post-1.0 MAJOR = breaking)
3. `docs/RELEASE_v1.0.0.md` — freeze notes + verify commands
4. README / QUALITY_PLAN / ROADMAP status → v1.0.0
5. Tag `v1.0.0` after `make test` gate

**Post-1.0 backlog (MINOR, not freeze blockers):**
- ~~Generics in `:type` (`Array<int>`); operators-only tt paste~~ ✅ session 5
- ~~`runtime_freestanding.c`~~ ✅ session 5 (Cortex-M / board BSP still research)
- LSP / IDE versioning independent of language MAJOR

### Follow-up (2026-07-28)

1. **`?` / `!` payload types** — bootstrap no longer hardcodes `int`; Ok/Some type
   from `Result<T,E>` / enum fields (`bootstrap/sema.nim`, `hir_lower.nim`).
2. **Example** `try_generic` — String Result propagation.
3. **LSP 0.18** — `textDocument/formatting` (+ range) via `formatSource` / `bux fmt`;
   VS Code format-on-save default; `tools/smoke_lsp_formatting.sh`.
4. **Macros:** generic `:type` + `Array_New<$t>`; operators-only `$op($a,$b)` /
   juxta binary split (`examples/macro_type_generic`, `macro_op_paste`).
5. **Freestanding:** `rt/runtime_freestanding.c`, `BUX_RUNTIME=freestanding`,
   `make test-freestanding`.

### Изрично **не** правим

- Повече Windows examples / Win OpenSSL / Win sockets
- Windows като required CI gate за product features (остава optional historical smoke ако CI вече го има)
- Desktop GUI / Win32 APIs
