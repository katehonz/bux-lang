import std/[unittest, os, strutils]
import ../bootstrap/[lexer, token, source_location]

proc tokenKinds(source: string): seq[TokenKind] =
  let res = tokenize(source, "<test>")
  for t in res.tokens:
    result.add(t.kind)

proc tokenTexts(source: string): seq[string] =
  let res = tokenize(source, "<test>")
  for t in res.tokens:
    result.add(t.text)

suite "Lexer":
  test "empty source":
    let res = tokenize("", "<test>")
    check res.tokens.len == 1
    check res.tokens[0].kind == tkEndOfFile
    check not res.hasErrors

  test "simple identifiers":
    let kinds = tokenKinds("foo bar _x Baz123")
    check kinds == @[tkIdent, tkIdent, tkIdent, tkIdent, tkEndOfFile]

  test "keywords":
    let kinds = tokenKinds("func let var if else while for return match struct enum")
    check kinds == @[tkFunc, tkLet, tkVar, tkIf, tkElse, tkWhile, tkFor, tkReturn, tkMatch, tkStruct, tkEnum, tkEndOfFile]

  test "bool literals":
    let kinds = tokenKinds("true false")
    check kinds == @[tkBoolLiteral, tkBoolLiteral, tkEndOfFile]
    let texts = tokenTexts("true false")
    check texts == @["true", "false", ""]

  test "integers":
    let kinds = tokenKinds("42 0xFF 0b1010 0o77")
    check kinds == @[tkIntLiteral, tkIntLiteral, tkIntLiteral, tkIntLiteral, tkEndOfFile]

  test "floats":
    let kinds = tokenKinds("3.14 1.0e-9 2.5E+3")
    check kinds == @[tkFloatLiteral, tkFloatLiteral, tkFloatLiteral, tkEndOfFile]

  test "operators":
    let kinds = tokenKinds("+ - * / % ** ++ --")
    check kinds == @[tkPlus, tkMinus, tkStar, tkSlash, tkPercent, tkStarStar, tkPlusPlus, tkMinusMinus, tkEndOfFile]

  test "comparison operators":
    let kinds = tokenKinds("== != < <= > >=")
    check kinds == @[tkEq, tkNe, tkLt, tkLe, tkGt, tkGe, tkEndOfFile]

  test "assignment operators":
    let kinds = tokenKinds("= += -= *= /= %= &= |= ^= <<= >>=")
    check kinds == @[tkAssign, tkPlusAssign, tkMinusAssign, tkStarAssign, tkSlashAssign, tkPercentAssign, tkAmpAssign, tkPipeAssign, tkCaretAssign, tkShlAssign, tkShrAssign, tkEndOfFile]

  test "punctuation":
    let kinds = tokenKinds("( ) { } [ ] , ; : :: . .. ... ..= -> => @ # ?")
    check kinds == @[tkLParen, tkRParen, tkLBrace, tkRBrace, tkLBracket, tkRBracket, tkComma, tkSemicolon, tkColon, tkColonColon, tkDot, tkDotDot, tkDotDotDot, tkDotDotEqual, tkArrow, tkFatArrow, tkAt, tkHash, tkQuestion, tkEndOfFile]

  test "logical operators":
    let kinds = tokenKinds("&& || !")
    check kinds == @[tkAmpAmp, tkPipePipe, tkBang, tkEndOfFile]

  test "bitwise operators":
    let kinds = tokenKinds("& | ^ ~ << >>")
    check kinds == @[tkAmp, tkPipe, tkCaret, tkTilde, tkShl, tkShr, tkEndOfFile]

  test "string literals":
    let kinds = tokenKinds("\"hello\" c8\"world\"")
    check kinds == @[tkStringLiteral, tkStringLiteral, tkEndOfFile]

  test "char literals":
    let kinds = tokenKinds("'A' c8'B'")
    check kinds == @[tkCharLiteral, tkCharLiteral, tkEndOfFile]

  test "line comments are skipped":
    let kinds = tokenKinds("let x = 42 // this is a comment")
    check kinds == @[tkLet, tkIdent, tkAssign, tkIntLiteral, tkEndOfFile]

  test "block comments are skipped":
    let kinds = tokenKinds("let /* inline comment */ x = 42")
    check kinds == @[tkLet, tkIdent, tkAssign, tkIntLiteral, tkEndOfFile]

  test "nested block comments":
    let kinds = tokenKinds("let /* outer /* inner */ still outer */ x = 42")
    check kinds == @[tkLet, tkIdent, tkAssign, tkIntLiteral, tkEndOfFile]

  test "intrinsics":
    let kinds = tokenKinds("#line #column #file #function #date #time #module")
    check kinds == @[tkHashLine, tkHashColumn, tkHashFile, tkHashFunction, tkHashDate, tkHashTime, tkHashModule, tkEndOfFile]

  test "newline tokens":
    let kinds = tokenKinds("let x = 42\nlet y = 10")
    check kinds == @[tkLet, tkIdent, tkAssign, tkIntLiteral, tkNewLine, tkLet, tkIdent, tkAssign, tkIntLiteral, tkEndOfFile]

  test "paths":
    let kinds = tokenKinds("Std::Io::PrintLine")
    check kinds == @[tkIdent, tkColonColon, tkIdent, tkColonColon, tkIdent, tkEndOfFile]

  test "unterminated string error":
    let res = tokenize("\"hello", "<test>")
    check res.hasErrors

  test "unterminated char error":
    let res = tokenize("'a", "<test>")
    check res.hasErrors

  test "escape sequences in string":
    let res = tokenize("\"hello\\nworld\\t!\"", "<test>")
    check not res.hasErrors
    check res.tokens[0].kind == tkStringLiteral

  test "full function":
    let src = "func Main() -> int {\n    let x: int32 = 42;\n    return x;\n}\n"
    let res = tokenize(src, "<test>")
    check not res.hasErrors
    check res.tokens[0].kind == tkFunc
    check res.tokens[1].kind == tkIdent
    check res.tokens[1].text == "Main"

  test "dumpTokens produces output":
    let res = tokenize("let x = 42", "<test>")
    let dump = dumpTokens(res)
    check "let" in dump
    check "42" in dump
