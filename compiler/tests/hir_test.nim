import std/[unittest, strformat]
import ../bootstrap/[lexer, parser, sema, hir, hir_lower, types, scope]

proc lowerSource(source: string): HirModule =
  let lexRes = tokenize(source, "<test>")
  check not lexRes.hasErrors
  let parseRes = parse(lexRes.tokens, "<test>")
  check parseRes.diagnostics.len == 0
  # Create Sema and populate global scope + method table
  var s = Sema(module: parseRes.module, globalScope: newScope())
  s.collectGlobals()
  result = lowerModule(parseRes.module, s)

suite "HIR Lowering":
  test "simple function":
    let src = "func Main() -> int { return 0; }"
    let hir = lowerSource(src)
    check hir.funcs.len == 1
    check hir.funcs[0].name == "Main"
    check hir.funcs[0].body != nil
    check hir.funcs[0].body.kind == hBlock
    echo "  PASS: simple function"

  test "function with arithmetic":
    let src = "func Add(a: int, b: int) -> int { return a + b; }"
    let hir = lowerSource(src)
    check hir.funcs.len == 1
    check hir.funcs[0].params.len == 2
    echo "  PASS: function with arithmetic"

  test "struct lowering":
    let src = """
struct Point { x: float64; y: float64; }
func Main() -> int { return 0; }
"""
    let hir = lowerSource(src)
    check hir.structs.len == 1
    check hir.structs[0].name == "Point"
    check hir.structs[0].fields.len == 2
    echo "  PASS: struct lowering"

  test "method lowering":
    let src = """
struct Point { x: float64; }
extend Point {
  func GetX(self: Point) -> float64 { return 0.0; }
}
func Main() -> int { return 0; }
"""
    let hir = lowerSource(src)
    check hir.funcs.len == 2  # GetX (mangled) + Main
    var foundMangled = false
    for f in hir.funcs:
      if f.name == "Point_GetX":
        foundMangled = true
    check foundMangled
    echo "  PASS: method lowering"

  test "if statement":
    let src = """
func Main() -> int {
  if true { return 1; }
  return 0;
}
"""
    let hir = lowerSource(src)
    let body = hir.funcs[0].body
    check body.kind == hBlock
    check body.blockStmts.len >= 1
    echo "  PASS: if statement"

  test "while loop":
    let src = """
func Main() -> int {
  while true { break; }
  return 0;
}
"""
    let hir = lowerSource(src)
    let body = hir.funcs[0].body
    check body.kind == hBlock
    echo "  PASS: while loop"

  test "let statement":
    let src = """
func Main() -> int {
  let x: int = 42;
  return x;
}
"""
    let hir = lowerSource(src)
    check hir.funcs.len == 1
    echo "  PASS: let statement"

  test "enum lowering":
    let src = """
enum Color { Red, Green, Blue }
func Main() -> int { return 0; }
"""
    let hir = lowerSource(src)
    check hir.enums.len == 1
    check hir.enums[0].name == "Color"
    check hir.enums[0].variants.len == 3
    echo "  PASS: enum lowering"
