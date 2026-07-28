# Bux — План за подобрения (post-v1.0.0)

> **Дата:** 2026-07-28  
> **Статус:** Всички приоритетни задачи изпълнени ✅ · follow-up DX/correctness shipped

---

## Сесия 4 — Try payload type + LSP formatting (2026-07-28)

| # | Задача | Файлове |
|---|--------|---------|
| F.5 | `?` / `!` вече връщат **Ok/Some payload type** (не винаги `int`) | `bootstrap/sema.nim`, `bootstrap/hir_lower.nim` |
| F.6 | Example `try_generic` — `Result<String, String>` + `?` | `examples/try_generic.bux` |
| D.6 | LSP **v0.18** `textDocument/formatting` (+ range) = `bux fmt` | `tools/lsp_server.nim`, `tools/smoke_lsp_formatting.sh` |
| D.7 | VS Code format-on-save default; docs | `vscode/package.json`, `docs/LSP.md` |

**Verified:** `try_generic` prints `hello` / `empty name`; `try_operator` still OK; formatting smoke PASS.

## Сесия 5 — Post-1.0 backlog: macros + freestanding (2026-07-28)

| # | Задача | Файлове |
|---|--------|---------|
| M.1 | Generics in `$t:type` + `$t` in `Array_New<$t>` | `bootstrap/macroexpand.nim`, `src/macroexpand.bux` |
| M.2 | Operators-only `:tt` paste (`$op($a,$b)` + juxta binary split) | `bootstrap/parser.nim`, `bootstrap/macroexpand.nim` |
| M.3 | Examples `macro_type_generic`, `macro_op_paste` | `examples/` |
| R.1 | `rt/runtime_freestanding.c` + `BUX_RUNTIME=freestanding` | `rt/`, `bootstrap/cli.nim`, `src/cli.bux` |
| R.2 | `make test-freestanding` smoke | `tools/smoke_freestanding.sh` |

**Verified:** both macro examples PASS; freestanding `-ffreestanding -c` + package exit 42.

---

## Свършено (3 сесии, 13 файла, +608/-96 реда)

### Сесия 1 — Критични бъгове
| # | Задача | Файлове |
|---|--------|---------|
| B.1 | Грешки при хардкоднати лимити (>8 param/variant/capture) | `src/parser.bux` |
| B.2 | `is` оператор — lowering + codegen | `src/hir_lower.bux`, `src/c_backend.bux` |
| B.3 | Enum type param парсване (`enum Result<T,E>`) | `src/parser.bux` |
| B.4 | `Type_Eq` структурно сравнение | `src/types.bux` |
| B.6 | `Iter<T>` safety документация | `lib/Iter.bux` |
| B.8 | Generic enum lowering (selfhost) | `src/hir_lower.bux` |
| B.9 | Generic enum lowering (Nim bootstrap) | `bootstrap/ast.nim`, `bootstrap/parser.nim`, `bootstrap/hir_lower.nim` |

### Сесия 2 — Tag/type манглинг
| # | Задача | Файлове |
|---|--------|---------|
| B.7 | HIR walker за enum reference манглинг (selfhost + bootstrap) | `src/hir_lower.bux`, `bootstrap/hir_lower.nim` |
| — | generic_enum example + test | `examples/generic_enum.bux`, `Makefile` |

### Сесия 3 — Data field достъп + Stdlib
| # | Задача | Файлове |
|---|--------|---------|
| B.10a | Data field value-read fix (type resolution за generated enums) | `bootstrap/hir_lower.nim` |
| B.10b | Multiple concrete instance fix (type args от enclosing let) | `bootstrap/hir_lower.nim` |
| B.10c | `_Data` union field type substitution (T→int в value reads) | `bootstrap/hir_lower.nim` |
| B.11 | `Result<T,E>` и `Option<T>` генерични | `lib/Result.bux`, `lib/Option.bux`, `examples/map_remove.bux`, `tests/stdlib_golden/collections/src/Main.bux` |

---

## Follow-up fixes (post DeepSeek session)

| # | Бъг | Фикс |
|---|-----|------|
| F.1 | `is` → LIR `unhandled hIs` / always false | Desugar to `==` / `.tag ==` in bootstrap + selfhost |
| F.2 | `?` + `Result<T,E>` → `Result_Tag` C error | Concrete monomorphized typeName + `_Tag`/`_Data` mangling |
| F.3 | `Unwrap` panic continues with garbage | `bux_exit(1)` after panic in Result/Option |
| F.4 | Regression example | `examples/is_operator.bux` |

## Резултат

- **Всички тестове: 0 FAIL, 0 error**
- **Selfhost loop: детерминистичен (C + ELF identical)**
- **Generic enum-ите работят end-to-end:**
  - Парсване с type параметри
  - Tag проверки (`p.tag == Pair_First`)
  - Data field достъп (`p.data.First_0` като l-value и r-value)
  - Множество конкретни инстанции в един файл
  - `Result<T,E>` и `Option<T>` в stdlib
  - `is` operator (simple + algebraic enums)
  - `?` try operator with monomorphized `Result<T,E>`

## Пример който работи

```bux
enum Pair<T, U> {
    First(T), Second(U),
}

func Main() -> int {
    let p: Pair<int, String> = Pair_MakeFirst<int, String>(42);
    if p.tag == Pair_First {
        PrintInt(p.data.First_0 as int64);  // → 42
    }
    let s: Pair<String, int> = Pair_MakeSecond<String, int>(99);
    if s.tag == Pair_Second {
        PrintInt(s.data.Second_0 as int64); // → 99
    }
    return 0;
}
```
