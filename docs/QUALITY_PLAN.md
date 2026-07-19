# Bux — План към „добър“ език (v0.5 → v1.0)

> **Дата:** 2026-07-19  
> **Текущо:** v0.5.x — **LSP 0.13 implementation**, HirNode sourceFile, optional selfhost-loop CI  
> **Цел:** Език, с който се пишат реални проекти комфортно, безопасно (по избор) и с надежден toolchain.

---

## Диагноза (къде сме)

| Слой | Състояние | Оценка |
|------|-----------|--------|
| Frontend (lex/parse) | Пълен Pratt parser, recovery | ★★★★☆ |
| Sema / generics | Monomorphization, trait bounds basic | ★★★★☆ |
| HIR → C | Tuples + fat `func` ABI в bootstrap **и** selfhost | ★★★★☆ |
| Selfhost (`src/`) | ~12k LOC, binary-identical loop, closures+tuples | ★★★★★ |
| Gradual ownership | `@[Checked]`, move, Drop, elision, **field-move skip Drop** | ★★★★★ |
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
| C.4 | `@[Release]` zero-cost path документация + golden tests | Killer story: safe default, free hot path | ✅ partial (unchecked path + goldens) |

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
| E.3 | Language freeze + semver policy | Trust | ✅ draft `docs/SEMVER.md` |
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

## Acceptance criteria за „добър v1.0“

- [ ] Всички examples + selfhost-loop + 3 apps минават на CI (apps: `make test-apps` ready)
- [ ] Array/Map/String/Test API покрива 90% от ежедневните нужди
- [x] `@[Checked]` хваща use-after-move + double `&mut` + dangling return / elision fail
- [x] `bux test` + `bux fmt` + `bux check` са default developer loop (`--filter` / `--check` shipped)
- [x] LanguageRef синхронизиран с компилатора (incl. C.1 elision)
- [x] Поне един външен/temp проект build-ва с registry dep (`tools/smoke_registry.sh` + HTTP)

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

## Следващи стъпки

1. Workspace-wide import path index without open documents (optional polish)
2. Expr/Stmt-level sourceFile if macros / cross-file inlining land
3. Fix selfhost C backend so buxc2→buxc3 fixed-point is green
4. Main PR CI workflow (`make test`) beyond optional selfhost-loop
