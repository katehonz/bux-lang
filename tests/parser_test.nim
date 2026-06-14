import std/[unittest, os]
import ../bootstrap/[lexer, parser, ast, token]

proc parseSource(source: string): ParseResult =
  let lexRes = tokenize(source, "<test>")
  check not lexRes.hasErrors
  result = parse(lexRes.tokens, "<test>")

suite "Parser":
  test "empty module":
    let res = parseSource("")
    check res.diagnostics.len == 0
    check res.module.items.len == 0

  test "simple function":
    let res = parseSource("func Main() -> int { return 0; }")
    check res.diagnostics.len == 0
    check res.module.items.len == 1
    check res.module.items[0].kind == dkFunc
    check res.module.items[0].declFuncName == "Main"

  test "function with parameters":
    let res = parseSource("func Add(a: int32, b: int32) -> int32 { return a + b; }")
    check res.diagnostics.len == 0
    check res.module.items[0].declFuncParams.len == 2
    check res.module.items[0].declFuncParams[0].name == "a"
    check res.module.items[0].declFuncParams[1].name == "b"

  test "struct declaration":
    let res = parseSource("struct Point { x: float64; y: float64; }")
    check res.diagnostics.len == 0
    check res.module.items[0].kind == dkStruct
    check res.module.items[0].declStructName == "Point"
    check res.module.items[0].declStructFields.len == 2

  test "enum declaration":
    let res = parseSource("enum Color { Red, Green, Blue }")
    check res.diagnostics.len == 0
    check res.module.items[0].kind == dkEnum
    check res.module.items[0].declEnumName == "Color"
    check res.module.items[0].declEnumVariants.len == 3

  test "import declaration":
    let res = parseSource("import Std::Io::PrintLine;")
    check res.diagnostics.len == 0
    check res.module.items[0].kind == dkUse
    check res.module.items[0].declUsePath == @["Std", "Io", "PrintLine"]

  test "const declaration":
    let res = parseSource("const PI: float64 = 3.14;")
    check res.diagnostics.len == 0
    check res.module.items[0].kind == dkConst
    check res.module.items[0].declConstName == "PI"

  test "type alias":
    let res = parseSource("type MyInt = int32;")
    check res.diagnostics.len == 0
    check res.module.items[0].kind == dkTypeAlias
    check res.module.items[0].declAliasName == "MyInt"

  test "let statement in function":
    let res = parseSource("func Main() -> int { let x: int32 = 42; return x; }")
    check res.diagnostics.len == 0
    check res.module.items[0].declFuncBody.stmts.len == 2
    check res.module.items[0].declFuncBody.stmts[0].kind == skLet
    check res.module.items[0].declFuncBody.stmts[0].stmtLetName == "x"

  test "if statement":
    let res = parseSource("func Main() -> int { if true { return 1; } else { return 0; } }")
    check res.diagnostics.len == 0
    let body = res.module.items[0].declFuncBody
    check body.stmts[0].kind == skIf
    check body.stmts[0].stmtIfThen.stmts.len == 1
    check body.stmts[0].stmtIfElse.stmts.len == 1

  test "while loop":
    let res = parseSource("func Main() -> int { while true { break; } return 0; }")
    check res.diagnostics.len == 0
    let body = res.module.items[0].declFuncBody
    check body.stmts[0].kind == skWhile
    check body.stmts[0].stmtWhileBody.stmts[0].kind == skBreak

  test "for loop":
    let res = parseSource("func Main() -> int { for i in items { continue; } return 0; }")
    check res.diagnostics.len == 0
    let body = res.module.items[0].declFuncBody
    check body.stmts[0].kind == skFor
    check body.stmts[0].stmtForVar == "i"

  test "match expression":
    let res = parseSource("func Main() -> int { let x = match 1 { 1 => 10, _ => 20 }; return x; }")
    check res.diagnostics.len == 0
    let body = res.module.items[0].declFuncBody
    check body.stmts[0].kind == skLet
    check body.stmts[0].stmtLetInit.kind == ekMatch

  test "binary expression":
    let res = parseSource("func Main() -> int { return 1 + 2 * 3; }")
    check res.diagnostics.len == 0
    let ret = res.module.items[0].declFuncBody.stmts[0]
    check ret.kind == skReturn
    check ret.stmtReturnValue.kind == ekBinary
    # 1 + (2 * 3)
    check ret.stmtReturnValue.exprBinaryOp == tkPlus

  test "call expression":
    let res = parseSource("func Main() -> int { return Add(10, 20); }")
    check res.diagnostics.len == 0
    let ret = res.module.items[0].declFuncBody.stmts[0]
    check ret.stmtReturnValue.kind == ekCall
    check ret.stmtReturnValue.exprCallCallee.kind == ekIdent

  test "full sample file":
    let source = readFile(currentSourcePath.parentDir / "testdata" / "sample.bux")
    let lexRes = tokenize(source, "sample.bux")
    check not lexRes.hasErrors
    let parseRes = parse(lexRes.tokens, "sample.bux")
    check parseRes.diagnostics.len == 0
    check parseRes.module.items.len == 3
    check parseRes.module.items[0].kind == dkUse
    check parseRes.module.items[1].kind == dkFunc
    check parseRes.module.items[2].kind == dkFunc
