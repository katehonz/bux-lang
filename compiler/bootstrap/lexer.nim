import std/[strutils, strformat]
import token, source_location

type
  LexerDiagnosticSeverity* = enum
    ldsWarning
    ldsError

  LexerDiagnostic* = object
    severity*: LexerDiagnosticSeverity
    loc*: SourceLocation
    message*: string

  LexerResult* = object
    tokens*: seq[Token]
    diagnostics*: seq[LexerDiagnostic]

proc hasErrors*(res: LexerResult): bool =
  for d in res.diagnostics:
    if d.severity == ldsError:
      return true
  return false

proc `$`*(d: LexerDiagnostic): string =
  let sev = if d.severity == ldsError: "error" else: "warning"
  result = &"{sev}: {d.message} at {d.loc}"

type
  Lexer* = object
    source: string
    sourceName: string
    pos: int
    line: uint32
    col: uint32
    tokens: seq[Token]
    diagnostics: seq[LexerDiagnostic]

proc initLexer*(source, sourceName: string): Lexer =
  result.source = source
  result.sourceName = sourceName
  result.pos = 0
  result.line = 1
  result.col = 1

proc isAtEnd(lex: Lexer): bool =
  lex.pos >= lex.source.len

proc peek(lex: Lexer, ahead: int = 0): char =
  let i = lex.pos + ahead
  if i < lex.source.len:
    return lex.source[i]
  return '\0'

proc advance(lex: var Lexer): char =
  result = lex.peek()
  if not lex.isAtEnd():
    inc lex.pos
    if result == '\n':
      inc lex.line
      lex.col = 1
    else:
      inc lex.col

proc match(lex: var Lexer, expected: char): bool =
  if lex.isAtEnd(): return false
  if lex.peek() != expected: return false
  discard lex.advance()
  return true

proc matchStr(lex: var Lexer, s: string): bool =
  for i, c in s:
    if lex.peek(i) != c:
      return false
  for _ in s:
    discard lex.advance()
  return true

proc currentLocation(lex: Lexer): SourceLocation =
  result = SourceLocation(line: lex.line, column: lex.col, offset: uint32(lex.pos))

proc emitError(lex: var Lexer, loc: SourceLocation, message: string) =
  lex.diagnostics.add(LexerDiagnostic(severity: ldsError, loc: loc, message: message))

proc emitWarning(lex: var Lexer, loc: SourceLocation, message: string) =
  lex.diagnostics.add(LexerDiagnostic(severity: ldsWarning, loc: loc, message: message))

proc makeToken(lex: Lexer, kind: TokenKind, startLoc: SourceLocation, startPos: int): Token =
  let text = lex.source[startPos ..< lex.pos]
  result = Token(kind: kind, text: text, loc: startLoc)

# ---------------------------------------------------------------------------
# Whitespace / comments
# ---------------------------------------------------------------------------

proc skipLineComment(lex: var Lexer) =
  while not lex.isAtEnd() and lex.peek() != '\n':
    discard lex.advance()

proc skipBlockComment(lex: var Lexer) =
  let startLoc = lex.currentLocation()
  var depth = 1
  while not lex.isAtEnd() and depth > 0:
    if lex.peek() == '/' and lex.peek(1) == '*':
      discard lex.advance()
      discard lex.advance()
      inc depth
    elif lex.peek() == '*' and lex.peek(1) == '/':
      discard lex.advance()
      discard lex.advance()
      dec depth
    else:
      discard lex.advance()
  if depth > 0:
    lex.emitError(startLoc, "unterminated block comment")

proc skipWhitespace(lex: var Lexer) =
  while not lex.isAtEnd():
    let c = lex.peek()
    if c in {' ', '\t', '\r'}:
      discard lex.advance()
    elif c == '/' and lex.peek(1) == '/':
      lex.skipLineComment()
    elif c == '/' and lex.peek(1) == '*':
      discard lex.advance()
      discard lex.advance()
      lex.skipBlockComment()
    else:
      break

# ---------------------------------------------------------------------------
# Identifiers
# ---------------------------------------------------------------------------

proc isIdentStart(c: char): bool =
  c in {'a'..'z', 'A'..'Z', '_'}

proc isIdentChar(c: char): bool =
  c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc scanIdent(lex: var Lexer, startLoc: SourceLocation): Token =
  let startPos = lex.pos
  while not lex.isAtEnd() and isIdentChar(lex.peek()):
    discard lex.advance()
  let text = lex.source[startPos ..< lex.pos]
  var kind = keywordKind(text)
  if text == "_":
    kind = tkUnderscore
  result = Token(kind: kind, text: text, loc: startLoc)

# ---------------------------------------------------------------------------
# Numbers
# ---------------------------------------------------------------------------

proc scanIntSuffix(lex: var Lexer) =
  # i8, i16, i32, i64, u8, u16, u32, u64, f32, f64
  if lex.isAtEnd(): return
  let c = lex.peek()
  if c in {'i', 'u', 'f'}:
    discard lex.advance()
    while not lex.isAtEnd() and lex.peek() in {'0'..'9'}:
      discard lex.advance()

proc scanHexDigits(lex: var Lexer) =
  while not lex.isAtEnd() and lex.peek() in {'0'..'9', 'a'..'f', 'A'..'F'}:
    discard lex.advance()

proc scanBinDigits(lex: var Lexer) =
  while not lex.isAtEnd() and lex.peek() in {'0', '1'}:
    discard lex.advance()

proc scanOctDigits(lex: var Lexer) =
  while not lex.isAtEnd() and lex.peek() in {'0'..'7'}:
    discard lex.advance()

proc scanDecDigits(lex: var Lexer) =
  while not lex.isAtEnd() and lex.peek() in {'0'..'9'}:
    discard lex.advance()

proc scanNumber(lex: var Lexer, startLoc: SourceLocation): Token =
  let startPos = lex.pos
  var isFloat = false

  if lex.peek() == '0' and lex.peek(1) in {'x', 'X', 'b', 'B', 'o', 'O'}:
    discard lex.advance()  # '0'
    let prefix = lex.advance()
    case prefix
    of 'x', 'X': lex.scanHexDigits()
    of 'b', 'B': lex.scanBinDigits()
    of 'o', 'O': lex.scanOctDigits()
    else: discard
    lex.scanIntSuffix()
    return lex.makeToken(tkIntLiteral, startLoc, startPos)

  lex.scanDecDigits()

  # Fractional part
  if lex.peek() == '.' and lex.peek(1) in {'0'..'9'}:
    isFloat = true
    discard lex.advance()  # '.'
    lex.scanDecDigits()

  # Exponent
  if lex.peek() in {'e', 'E'}:
    isFloat = true
    discard lex.advance()
    if lex.peek() in {'+', '-'}:
      discard lex.advance()
    if lex.peek() notin {'0'..'9'}:
      lex.emitError(lex.currentLocation(), "expected digits in exponent")
    else:
      lex.scanDecDigits()

  if isFloat:
    # Optional f32/f64 suffix
    if lex.peek() == 'f' and lex.peek(1) in {'3', '6'}:
      discard lex.advance()
      discard lex.advance()
    result = lex.makeToken(tkFloatLiteral, startLoc, startPos)
  else:
    lex.scanIntSuffix()
    result = lex.makeToken(tkIntLiteral, startLoc, startPos)

# ---------------------------------------------------------------------------
# Strings and chars
# ---------------------------------------------------------------------------

proc scanEscapeSequence(lex: var Lexer): string =
  if lex.isAtEnd():
    return ""
  let c = lex.advance()
  case c
  of '\\': result = "\\"
  of '"': result = "\""
  of '\'': result = "\'"
  of 'n': result = "\n"
  of 'r': result = "\r"
  of 't': result = "\t"
  of '0': result = "\0"
  of 'x':
    var hexVal = ""
    for _ in 0..<2:
      if lex.isAtEnd() or lex.peek() notin {'0'..'9', 'a'..'f', 'A'..'F'}:
        lex.emitError(lex.currentLocation(), "expected two hex digits after \\x")
        break
      hexVal.add(lex.advance())
    if hexVal.len == 2:
      try:
        let code = parseHexInt(hexVal)
        result = $chr(code)
      except ValueError:
        lex.emitError(lex.currentLocation(), &"invalid hex escape \\x{hexVal}")
        result = ""
    else:
      result = ""
  else:
    lex.emitError(lex.currentLocation(), &"unknown escape sequence \\\\{c}")
    result = $c

proc scanString(lex: var Lexer, startLoc: SourceLocation, prefixLen: int): Token =
  let startPos = lex.pos - prefixLen
  # prefixLen characters before the opening quote were already consumed by caller
  # but we need to handle the quote itself
  # Collect resolved string content to properly handle escape sequences
  var resolved = ""
  if lex.peek() == '"':
    discard lex.advance()
  while not lex.isAtEnd() and lex.peek() != '"':
    if lex.peek() == '\n':
      lex.emitError(lex.currentLocation(), "unterminated string literal")
      break
    if lex.peek() == '\\':
      discard lex.advance()
      resolved.add(lex.scanEscapeSequence())
    else:
      resolved.add(lex.advance())
  if lex.isAtEnd():
    lex.emitError(startLoc, "unterminated string literal")
  else:
    discard lex.advance()  # closing "
  # Rebuild text with resolved escapes: prefix + " + resolved + "
  var text = lex.source[startPos ..< startPos + prefixLen]
  text.add('"')
  text.add(resolved)
  text.add('"')
  result = Token(kind: tkStringLiteral, text: text, loc: startLoc)

proc scanBacktickString(lex: var Lexer, startLoc: SourceLocation): Token =
  ## Scan a backtick-delimited raw string literal: content is literal,
  ## no escape processing, newlines are preserved.
  let startPos = lex.pos - 1  # include the opening backtick
  while not lex.isAtEnd() and lex.peek() != '`':
    discard lex.advance()
  if lex.isAtEnd():
    lex.emitError(startLoc, "unterminated backtick string literal")
  else:
    discard lex.advance()  # closing backtick
  result = lex.makeToken(tkStringLiteral, startLoc, startPos)

proc scanChar(lex: var Lexer, startLoc: SourceLocation, prefixLen: int): Token =
  let startPos = lex.pos - prefixLen
  # Collect resolved char content to properly handle escape sequences
  var resolved = ""
  if lex.peek() == '\'':
    discard lex.advance()
  if lex.isAtEnd():
    lex.emitError(startLoc, "unterminated char literal")
  elif lex.peek() == '\n':
    lex.emitError(lex.currentLocation(), "newline in char literal")
  elif lex.peek() == '\\':
    discard lex.advance()
    resolved.add(lex.scanEscapeSequence())
  else:
    resolved.add(lex.advance())
  if lex.isAtEnd() or lex.peek() != '\'':
    lex.emitError(lex.currentLocation(), "expected closing ' for char literal")
  else:
    discard lex.advance()
  # Rebuild text with resolved escape: prefix + ' + resolved + '
  var text = lex.source[startPos ..< startPos + prefixLen]
  text.add('\'')
  text.add(resolved)
  text.add('\'')
  result = Token(kind: tkCharLiteral, text: text, loc: startLoc)

# ---------------------------------------------------------------------------
# Symbols / operators
# ---------------------------------------------------------------------------

proc scanSymbol(lex: var Lexer, startLoc: SourceLocation): Token =
  let startPos = lex.pos
  let c1 = lex.advance()

  template check2(c2: char, kind2: TokenKind, kind1: TokenKind) =
    if lex.peek() == c2:
      discard lex.advance()
      return lex.makeToken(kind2, startLoc, startPos)
    else:
      return lex.makeToken(kind1, startLoc, startPos)

  template check3(c2: char, kind2: TokenKind, c3: char, kind3: TokenKind, kind1: TokenKind) =
    if lex.peek() == c2:
      discard lex.advance()
      if lex.peek() == c3:
        discard lex.advance()
        return lex.makeToken(kind3, startLoc, startPos)
      return lex.makeToken(kind2, startLoc, startPos)
    else:
      return lex.makeToken(kind1, startLoc, startPos)

  template checkEq(c2: char, kind2: TokenKind, kind1: TokenKind) =
    check2(c2, kind2, kind1)

  case c1
  of '(': return lex.makeToken(tkLParen, startLoc, startPos)
  of ')': return lex.makeToken(tkRParen, startLoc, startPos)
  of '{': return lex.makeToken(tkLBrace, startLoc, startPos)
  of '}': return lex.makeToken(tkRBrace, startLoc, startPos)
  of '[': return lex.makeToken(tkLBracket, startLoc, startPos)
  of ']': return lex.makeToken(tkRBracket, startLoc, startPos)
  of ',': return lex.makeToken(tkComma, startLoc, startPos)
  of ';': return lex.makeToken(tkSemicolon, startLoc, startPos)
  of '@': return lex.makeToken(tkAt, startLoc, startPos)
  of '?': return lex.makeToken(tkQuestion, startLoc, startPos)
  of '~': return lex.makeToken(tkTilde, startLoc, startPos)
  of ':': check2(':', tkColonColon, tkColon)
  of '.':
    if lex.peek() == '.' and lex.peek(1) == '.':
      discard lex.advance()
      discard lex.advance()
      return lex.makeToken(tkDotDotDot, startLoc, startPos)
    elif lex.peek() == '.' and lex.peek(1) == '=':
      discard lex.advance()
      discard lex.advance()
      return lex.makeToken(tkDotDotEqual, startLoc, startPos)
    elif lex.peek() == '.':
      discard lex.advance()
      return lex.makeToken(tkDotDot, startLoc, startPos)
    else:
      return lex.makeToken(tkDot, startLoc, startPos)
  of '-':
    if lex.peek() == '>':
      discard lex.advance()
      return lex.makeToken(tkArrow, startLoc, startPos)
    elif lex.peek() == '-':
      discard lex.advance()
      return lex.makeToken(tkMinusMinus, startLoc, startPos)
    elif lex.peek() == '=':
      discard lex.advance()
      return lex.makeToken(tkMinusAssign, startLoc, startPos)
    else:
      return lex.makeToken(tkMinus, startLoc, startPos)
  of '+':
    if lex.peek() == '+':
      discard lex.advance()
      return lex.makeToken(tkPlusPlus, startLoc, startPos)
    elif lex.peek() == '=':
      discard lex.advance()
      return lex.makeToken(tkPlusAssign, startLoc, startPos)
    else:
      return lex.makeToken(tkPlus, startLoc, startPos)
  of '*':
    if lex.peek() == '*':
      discard lex.advance()
      return lex.makeToken(tkStarStar, startLoc, startPos)
    elif lex.peek() == '=':
      discard lex.advance()
      return lex.makeToken(tkStarAssign, startLoc, startPos)
    else:
      return lex.makeToken(tkStar, startLoc, startPos)
  of '/':
    if lex.peek() == '=':
      discard lex.advance()
      return lex.makeToken(tkSlashAssign, startLoc, startPos)
    else:
      return lex.makeToken(tkSlash, startLoc, startPos)
  of '%':
    if lex.peek() == '=':
      discard lex.advance()
      return lex.makeToken(tkPercentAssign, startLoc, startPos)
    else:
      return lex.makeToken(tkPercent, startLoc, startPos)
  of '=':
    if lex.peek() == '=':
      discard lex.advance()
      return lex.makeToken(tkEq, startLoc, startPos)
    elif lex.peek() == '>':
      discard lex.advance()
      return lex.makeToken(tkFatArrow, startLoc, startPos)
    else:
      return lex.makeToken(tkAssign, startLoc, startPos)
  of '!':
    if lex.peek() == '=':
      discard lex.advance()
      return lex.makeToken(tkNe, startLoc, startPos)
    else:
      return lex.makeToken(tkBang, startLoc, startPos)
  of '<':
    if lex.peek() == '=':
      discard lex.advance()
      return lex.makeToken(tkLe, startLoc, startPos)
    elif lex.peek() == '<':
      discard lex.advance()
      if lex.peek() == '=':
        discard lex.advance()
        return lex.makeToken(tkShlAssign, startLoc, startPos)
      return lex.makeToken(tkShl, startLoc, startPos)
    else:
      return lex.makeToken(tkLt, startLoc, startPos)
  of '>':
    if lex.peek() == '=':
      discard lex.advance()
      return lex.makeToken(tkGe, startLoc, startPos)
    elif lex.peek() == '>':
      discard lex.advance()
      if lex.peek() == '=':
        discard lex.advance()
        return lex.makeToken(tkShrAssign, startLoc, startPos)
      return lex.makeToken(tkShr, startLoc, startPos)
    else:
      return lex.makeToken(tkGt, startLoc, startPos)
  of '&':
    if lex.peek() == '&':
      discard lex.advance()
      return lex.makeToken(tkAmpAmp, startLoc, startPos)
    elif lex.peek() == '=':
      discard lex.advance()
      return lex.makeToken(tkAmpAssign, startLoc, startPos)
    else:
      return lex.makeToken(tkAmp, startLoc, startPos)
  of '|':
    if lex.peek() == '|':
      discard lex.advance()
      return lex.makeToken(tkPipePipe, startLoc, startPos)
    elif lex.peek() == '=':
      discard lex.advance()
      return lex.makeToken(tkPipeAssign, startLoc, startPos)
    else:
      return lex.makeToken(tkPipe, startLoc, startPos)
  of '^':
    if lex.peek() == '=':
      discard lex.advance()
      return lex.makeToken(tkCaretAssign, startLoc, startPos)
    else:
      return lex.makeToken(tkCaret, startLoc, startPos)
  of '#':
    # Check for intrinsics: #line, #column, #file, #function, #date, #time, #module
    let afterHash = lex.peek()
    if afterHash == 'l' and lex.matchStr("line"):
      return lex.makeToken(tkHashLine, startLoc, startPos)
    elif afterHash == 'c' and lex.matchStr("column"):
      return lex.makeToken(tkHashColumn, startLoc, startPos)
    elif afterHash == 'f' and lex.peek(1) == 'i' and lex.peek(2) == 'l' and lex.peek(3) == 'e':
      discard lex.matchStr("file")
      return lex.makeToken(tkHashFile, startLoc, startPos)
    elif afterHash == 'f' and lex.peek(1) == 'u' and lex.peek(2) == 'n':
      discard lex.matchStr("function")
      return lex.makeToken(tkHashFunction, startLoc, startPos)
    elif afterHash == 'd' and lex.matchStr("date"):
      return lex.makeToken(tkHashDate, startLoc, startPos)
    elif afterHash == 't' and lex.matchStr("time"):
      return lex.makeToken(tkHashTime, startLoc, startPos)
    elif afterHash == 'm' and lex.matchStr("module"):
      return lex.makeToken(tkHashModule, startLoc, startPos)
    elif afterHash == 'e' and lex.matchStr("emit"):
      return lex.makeToken(tkHashEmit, startLoc, startPos)
    else:
      return lex.makeToken(tkHash, startLoc, startPos)
  else:
    lex.emitError(startLoc, &"unexpected character '{c1}'")
    return lex.makeToken(tkUnknown, startLoc, startPos)

# ---------------------------------------------------------------------------
# Main scanning loop
# ---------------------------------------------------------------------------

proc nextToken(lex: var Lexer): Token =
  lex.skipWhitespace()
  let startLoc = lex.currentLocation()
  let startPos = lex.pos

  if lex.isAtEnd():
    return Token(kind: tkEndOfFile, text: "", loc: startLoc)

  let c = lex.peek()

  if c == '\n':
    discard lex.advance()
    return Token(kind: tkNewLine, text: "\n", loc: startLoc)

  # String prefixes: c8" c16" c32" — must come before ident check
  if c == 'c' and lex.peek(1) in {'8', '1', '3'}:
    let d = lex.peek(1)
    if d == '8' and lex.peek(2) == '"':
      discard lex.advance()  # c
      discard lex.advance()  # 8
      return lex.scanString(startLoc, 2)
    elif d == '1' and lex.peek(2) == '6' and lex.peek(3) == '"':
      discard lex.advance()
      discard lex.advance()
      discard lex.advance()
      return lex.scanString(startLoc, 3)
    elif d == '3' and lex.peek(2) == '2' and lex.peek(3) == '"':
      discard lex.advance()
      discard lex.advance()
      discard lex.advance()
      return lex.scanString(startLoc, 3)

  if c == '"':
    return lex.scanString(startLoc, 0)

  # Backtick-delimited raw string: `...`
  if c == '`':
    discard lex.advance()
    return lex.scanBacktickString(startLoc)

  # Char prefixes: c8' c16' c32' — must come before ident check
  if c == 'c' and lex.peek(1) in {'8', '1', '3'}:
    let d = lex.peek(1)
    if d == '8' and lex.peek(2) == '\'':
      discard lex.advance()
      discard lex.advance()
      return lex.scanChar(startLoc, 2)
    elif d == '1' and lex.peek(2) == '6' and lex.peek(3) == '\'':
      discard lex.advance()
      discard lex.advance()
      discard lex.advance()
      return lex.scanChar(startLoc, 3)
    elif d == '3' and lex.peek(2) == '2' and lex.peek(3) == '\'':
      discard lex.advance()
      discard lex.advance()
      discard lex.advance()
      return lex.scanChar(startLoc, 3)

  if c == '\'':
    # Check if this is a lifetime (e.g., 'a) or char literal (e.g., 'a')
    # Lifetime: ' followed by identifier chars, no closing '
    # Char literal: ' followed by one char/escape, then closing '
    let afterQuote = lex.peek(1)
    if isIdentStart(afterQuote):
      # Could be lifetime or char literal like 'x'
      # If next char after ident start is NOT ', it's a lifetime
      # (for char literals, the char/escape is consumed and then ')
      # Simple heuristic: if peek(2) is ', it's a char literal; else lifetime
      if lex.peek(2) == '\'':
        return lex.scanChar(startLoc, 0)
      elif lex.peek(2) == '\0':
        return lex.scanChar(startLoc, 0)
      else:
        # Lifetime: consume ' and then identifier chars
        discard lex.advance()  # '
        while not lex.isAtEnd() and isIdentChar(lex.peek()):
          discard lex.advance()
        return lex.makeToken(tkLifetime, startLoc, startPos)
    else:
      return lex.scanChar(startLoc, 0)

  if isIdentStart(c):
    return lex.scanIdent(startLoc)

  if c in {'0'..'9'}:
    return lex.scanNumber(startLoc)

  return lex.scanSymbol(startLoc)

proc tokenize*(lex: var Lexer): LexerResult =
  while true:
    let tok = lex.nextToken()
    lex.tokens.add(tok)
    if tok.kind == tkEndOfFile:
      break
  result = LexerResult(tokens: lex.tokens, diagnostics: lex.diagnostics)

proc tokenize*(source, sourceName: string): LexerResult =
  var lex = initLexer(source, sourceName)
  result = lex.tokenize()

proc dumpTokens*(res: LexerResult): string =
  for tok in res.tokens:
    result.add($tok & "\n")
