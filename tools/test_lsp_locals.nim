## Smoke test for position-sensitive locals + inferred let types.
## Run: nim r --path:../bootstrap tools/test_lsp_locals.nim
import std/[os, strutils, tables, unittest]
import lexer, parser, ast, sema, types, scope

# Minimal mirror of LSP collect (keeps the test free of JSON-RPC)

proc typeOfLet(sema: var Sema, stmt: Stmt, sc: Scope): tuple[t: Type, inferred: bool] =
  result.inferred = false
  result.t = makeUnknown()
  if stmt.stmtLetType != nil:
    result.t = sema.resolveType(stmt.stmtLetType)
  if (result.t == nil or result.t.isUnknown) and stmt.stmtLetInit != nil:
    result.t = sema.checkExprForLsp(stmt.stmtLetInit, sc)
    result.inferred = true
  elif stmt.stmtLetType == nil and stmt.stmtLetInit != nil:
    result.t = sema.checkExprForLsp(stmt.stmtLetInit, sc)
    result.inferred = true

suite "LSP locals / inference":
  test "inferred let int from literal":
    let src = """
func Main() -> int {
  let x = 42;
  return x;
}
"""
    let lexRes = tokenize(src, "t.bux")
    check(not lexRes.hasErrors)
    let parseRes = parse(lexRes.tokens, "t.bux")
    check(parseRes.diagnostics.len == 0)
    var (res, semaCtx) = analyzeFull(parseRes.module)
    discard res
    var found = false
    for d in parseRes.module.items:
      if d.kind != dkFunc: continue
      var sc = newScope(semaCtx.globalScope)
      for stmt in d.declFuncBody.stmts:
        if stmt.kind == skLet and stmt.stmtLetName == "x":
          let (t, inf) = typeOfLet(semaCtx, stmt, sc)
          check(inf)
          check(t.toString == "int" or t.kind == tkInt)
          found = true
    check(found)

  test "explicit type not marked inferred":
    let src = """
func Main() -> int {
  let s: String = "hi";
  return 0;
}
"""
    let lexRes = tokenize(src, "t.bux")
    let parseRes = parse(lexRes.tokens, "t.bux")
    var (res, semaCtx) = analyzeFull(parseRes.module)
    discard res
    for d in parseRes.module.items:
      if d.kind != dkFunc: continue
      var sc = newScope(semaCtx.globalScope)
      for stmt in d.declFuncBody.stmts:
        if stmt.kind == skLet and stmt.stmtLetName == "s":
          let (t, inf) = typeOfLet(semaCtx, stmt, sc)
          check(not inf)
          check(t.toString == "String" or t.kind == tkStr)

  test "shadowed local: outer then inner":
    let src = """
func Main() -> int {
  let x = 1;
  if true {
    let x = 2;
    return x;
  }
  return x;
}
"""
    let lexRes = tokenize(src, "t.bux")
    let parseRes = parse(lexRes.tokens, "t.bux")
    check(parseRes.diagnostics.len == 0)
    # Both lets parse; inner is nested under if
    var outer, inner: bool
    for d in parseRes.module.items:
      if d.kind != dkFunc: continue
      for stmt in d.declFuncBody.stmts:
        if stmt.kind == skLet and stmt.stmtLetName == "x":
          outer = true
        if stmt.kind == skIf:
          for s2 in stmt.stmtIfThen.stmts:
            if s2.kind == skLet and s2.stmtLetName == "x":
              inner = true
    check(outer and inner)

echo "LSP locals unit checks done"
