import std/[unittest, strutils]
import ../bootstrap/[lexer, parser, sema, types]

proc checkSource(source: string): SemaResult =
  let lexRes = tokenize(source, "<test>")
  check not lexRes.hasErrors
  let parseRes = parse(lexRes.tokens, "<test>")
  check parseRes.diagnostics.len == 0
  result = analyze(parseRes.module)

suite "Borrow Checker":

  test "@[Checked] function with &mut allows mutation":
    let res = checkSource("""
func Mutate(val: &mut int) {
  *val = 42;
}
func Main() -> int {
  var x: int = 10;
  Mutate(&x);
  return 0;
}
""")
    check(not res.hasErrors)

  test "@[Checked] function rejects write through &T":
    let res = checkSource("""
@[Checked]
func BadWrite(val: &int) {
  *val = 42;
}
func Main() -> int {
  var x: int = 10;
  BadWrite(&x);
  return 0;
}
""")
    check(res.hasErrors)
    check(res.diagnostics[0].message.contains("cannot assign through shared reference"))

  test "unchecked function allows write through raw pointer":
    let res = checkSource("""
func RawWrite(val: *int) {
  *val = 42;
}
func Main() -> int {
  var x: int = 10;
  RawWrite(&x);
  return 0;
}
""")
    check(not res.hasErrors)

  test "&T allows reading":
    let res = checkSource("""
@[Checked]
func Read(val: &int) -> int {
  return *val;
}
func Main() -> int {
  var x: int = 10;
  return Read(&x);
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
