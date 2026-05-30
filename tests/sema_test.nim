import std/[unittest, strutils]
import ../src/[lexer, parser, sema, types]

proc checkSource(source: string): SemaResult =
  let lexRes = tokenize(source, "<test>")
  check not lexRes.hasErrors
  let parseRes = parse(lexRes.tokens, "<test>")
  check parseRes.diagnostics.len == 0
  result = analyze(parseRes.module)

suite "Sema":
  test "valid function with correct types":
    let res = checkSource("func Main() -> int { return 0; }")
    check not res.hasErrors

  test "undeclared identifier":
    let res = checkSource("func Main() -> int { return x; }")
    check res.hasErrors
    check "undeclared" in res.diagnostics[0].message

  test "duplicate function":
    let res = checkSource("func Main() -> int { return 0; } func Main() -> int { return 1; }")
    check res.hasErrors
    check "duplicate" in res.diagnostics[0].message

  test "type mismatch in assignment":
    let res = checkSource("func Main() -> int { let x: int32 = c8\"hello\"; return 0; }")
    check res.hasErrors
    check "cannot assign" in res.diagnostics[0].message

  test "valid arithmetic":
    let res = checkSource("func Main() -> int { return 1 + 2 * 3; }")
    check not res.hasErrors

  test "arithmetic on strings fails":
    let res = checkSource("func Main() -> int { return c8\"a\" + c8\"b\"; }")
    check res.hasErrors

  test "valid function call":
    let res = checkSource("func Add(a: int, b: int) -> int { return a + b; } func Main() -> int { return Add(1, 2); }")
    check not res.hasErrors

  test "wrong number of arguments":
    let res = checkSource("func Add(a: int32, b: int32) -> int32 { return a + b; } func Main() -> int { return Add(1); }")
    check res.hasErrors
    check "expected 2 arguments" in res.diagnostics[0].message

  test "wrong argument type":
    let res = checkSource("func Add(a: int32, b: int32) -> int32 { return a + b; } func Main() -> int { return Add(c8\"a\", 2); }")
    check res.hasErrors
    check "argument 1" in res.diagnostics[0].message

  test "if condition must be bool":
    let res = checkSource("func Main() -> int { if 1 { return 0; } return 0; }")
    check res.hasErrors
    check "bool" in res.diagnostics[0].message

  test "valid if with bool":
    let res = checkSource("func Main() -> int { if true { return 0; } return 0; }")
    check not res.hasErrors

  test "pointer dereference":
    let res = checkSource("func Main() -> int32 { let p: *int32 = null; return *p; }")
    check not res.hasErrors

  test "struct field access":
    let res = checkSource("struct Point { x: float64; y: float64; } func Main() -> int32 { let p = Point { x: 1.0, y: 2.0 }; return 0; }")
    check not res.hasErrors

  test "unknown struct field":
    let res = checkSource("struct Point { x: float64; y: float64; } func Main() -> int32 { let p = Point { x: 1.0, y: 2.0 }; return p.z; }")
    check res.hasErrors
    check "no field" in res.diagnostics[0].message

  test "valid comparison":
    let res = checkSource("func Main() -> int { return 1 == 2; }")
    check not res.hasErrors

  test "valid slice literal":
    let res = checkSource("func Main() -> int { let arr = [1, 2, 3]; return 0; }")
    check not res.hasErrors

  test "slice element type mismatch":
    let res = checkSource("func Main() -> int { let arr = [1, c8\"a\"]; return 0; }")
    check res.hasErrors

  test "method call with extend":
    let src = """
struct Point { x: float64; y: float64; }
extend Point {
  func Distance(self: Point) -> float64 { return 0.0; }
}
func Main() -> int {
  let p = Point { x: 1.0, y: 2.0 };
  let d = p.Distance();
  return 0;
}
"""
    let res = checkSource(src)
    check not res.hasErrors

  test "method call with wrong arguments":
    let src = """
struct Point { x: float64; y: float64; }
extend Point {
  func Add(self: Point, other: Point) -> Point { return self; }
}
func Main() -> int {
  let p = Point { x: 1.0, y: 2.0 };
  let q = p.Add();
  return 0;
}
"""
    let res = checkSource(src)
    check res.hasErrors
    check "too few arguments" in res.diagnostics[0].message

  test "interface declaration":
    let src = """
interface Display {
  func ToString(self: Self) -> String;
}
"""
    let res = checkSource(src)
    check not res.hasErrors

  test "extend for interface":
    let src = """
struct Point { x: float64; y: float64; }
interface Display {
  func ToString(self: Self) -> String;
}
extend Point for Display {
  func ToString(self: Point) -> String { return c8"Point"; }
}
func Main() -> int { return 0; }
"""
    let res = checkSource(src)
    check not res.hasErrors
