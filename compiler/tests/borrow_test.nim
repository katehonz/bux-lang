import std/[unittest, os, strutils]
import ../bootstrap/[lexer, parser, sema, types]

proc checkSource(source: string): tuple[hasErrors: bool, diagnostics: seq[SemaDiagnostic]] =
  let lexRes = lexer.tokenize(source, "test.bux")
  if lexRes.hasErrors:
    return (true, @[])
  let parseRes = parser.parse(lexRes.tokens, "test.bux")
  if parseRes.diagnostics.len > 0:
    return (true, @[])
  let (semaRes, _) = sema.analyzeFull(parseRes.module)
  return (semaRes.hasErrors, semaRes.diagnostics)

suite "Borrow Checker":
  test "@[Checked] function with &mut allows mutation":
    let res = checkSource("""
@[Checked]
func Inc(p: &mut int) {
  *p = *p + 1;
}
@[Checked]
func Main() -> int {
  var x: int = 5;
  Inc(&x);
  return x;
}
""")
    check(not res.hasErrors)

  test "@[Checked] function rejects write through &T":
    let res = checkSource("""
@[Checked]
func BadWrite(p: &int) {
  *p = 42;
}
@[Checked]
func Main() -> int {
  var x: int = 5;
  BadWrite(&x);
  return x;
}
""")
    check(res.hasErrors)

  test "unchecked function allows write through raw pointer":
    let res = checkSource("""
func RawWrite(p: *int) {
  *p = 42;
}
func Main() -> int {
  var x: int = 5;
  RawWrite(&x);
  return x;
}
""")
    check(not res.hasErrors)

  test "&T allows reading":
    let res = checkSource("""
@[Checked]
func Get(p: &int) -> int {
  return *p;
}
@[Checked]
func Main() -> int {
  var x: int = 5;
  return Get(&x);
}
""")
    check(not res.hasErrors)

  test "own T type parses and resolves":
    let res = checkSource("""
struct Box {
  value: int;
}
func TakeOwn(b: own Box) -> int {
  return b.value;
}
func Main() -> int {
  var b: Box = Box { value: 42 };
  return TakeOwn(b);
}
""")
    check(not res.hasErrors)

  test "@[Checked] rejects double mutable borrow in call":
    let res = checkSource("""
@[Checked]
func Swap(a: &mut int, b: &mut int) {
  let tmp = *a;
  *a = *b;
  *b = tmp;
}
@[Checked]
func Main() -> int {
  var x: int = 10;
  Swap(&x, &x);
  return 0;
}
""")
    check(res.hasErrors)
    check(res.diagnostics[0].message.contains("mutable borrow"))

  test "@[Checked] rejects use after move":
    let res = checkSource("""
struct Box {
  value: int;
}
@[Checked]
func Consume(b: own Box) -> int {
  return b.value;
}
@[Checked]
func Main() -> int {
  var b: Box = Box { value: 42 };
  let x: int = Consume(b);
  return b.value;
}
""")
    check(res.hasErrors)
    check(res.diagnostics[0].message.contains("moved"))

  test "@[Checked] allows reinitialization after move":
    let res = checkSource("""
struct Box {
  value: int;
}
@[Checked]
func Take(b: own Box) -> int {
  return b.value;
}
@[Checked]
func Main() -> int {
  var b: own Box = Box { value: 1 };
  Take(b);
  b = Box { value: 2 };
  return b.value;
}
""")
    check(not res.hasErrors)

  test "@[Checked] move in assignment":
    let res = checkSource("""
struct Box {
  value: int;
}
@[Checked]
func Main() -> int {
  var a: own Box = Box { value: 1 };
  var b: own Box = a;
  return a.value;
}
""")
    check(res.hasErrors)
    check(res.diagnostics[0].message.contains("moved"))

  test "@[Checked] move in return":
    let res = checkSource("""
struct Box {
  value: int;
}
@[Checked]
func Give() -> own Box {
  var x: own Box = Box { value: 42 };
  return x;
}
@[Checked]
func Main() -> int {
  let b: own Box = Give();
  return b.value;
}
""")
    check(not res.hasErrors)
