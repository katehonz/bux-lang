import std/strutils
import token, source_location, ast

type
  ParserDiagnosticSeverity* = enum
    pdsWarning
    pdsError

  ParserDiagnostic* = object
    severity*: ParserDiagnosticSeverity
    loc*: SourceLocation
    message*: string

  ParseResult* = object
    module*: Module
    diagnostics*: seq[ParserDiagnostic]

  Parser* = object
    tokens: seq[Token]
    sourceName: string
    pos: int
    diagnostics: seq[ParserDiagnostic]
    structInitAllowed: bool  ## disabled inside if/while/for/match conditions

proc initParser*(tokens: seq[Token], sourceName: string = "<input>"): Parser =
  result.tokens = tokens
  result.sourceName = sourceName
  result.pos = 0
  result.structInitAllowed = true

# ---------------------------------------------------------------------------
# Token helpers
# ---------------------------------------------------------------------------

proc peek(p: Parser, ahead: int = 0): TokenKind =
  let i = p.pos + ahead
  if i < p.tokens.len:
    return p.tokens[i].kind
  return tkEndOfFile

proc at(p: Parser): Token =
  if p.pos < p.tokens.len:
    return p.tokens[p.pos]
  return Token(kind: tkEndOfFile)

proc advance(p: var Parser): Token =
  result = p.at
  if p.pos < p.tokens.len:
    inc p.pos

proc check(p: Parser, kind: TokenKind): bool =
  p.peek() == kind

proc checkAny(p: Parser, kinds: openArray[TokenKind]): bool =
  for k in kinds:
    if p.peek() == k: return true
  return false

proc match(p: var Parser, kind: TokenKind): bool =
  if p.check(kind):
    discard p.advance()
    return true
  return false

proc isTypeArgListAhead(p: Parser): bool =
  ## Lookahead to determine if '<' starts a type argument list.
  ## Returns true if we can find a matching '>' before EOF, '{', or ';'.
  if not p.check(tkLt): return false
  var depth = 0
  var ahead = 0
  while true:
    let kind = p.peek(ahead)
    if kind == tkEndOfFile or kind == tkLBrace or kind == tkSemicolon:
      return false
    if kind == tkLt:
      inc depth
    elif kind == tkGt:
      dec depth
      if depth == 0:
        return true
      if depth < 0:
        return false
    inc ahead

proc expect(p: var Parser, kind: TokenKind, message: string): Token =
  if p.check(kind):
    return p.advance()
  let tok = p.at
  p.diagnostics.add(ParserDiagnostic(
    severity: pdsError,
    loc: tok.loc,
    message: message & " (got " & tokenKindName(tok.kind) & ")"
  ))
  result = tok

proc isKeywordToken(kind: TokenKind): bool =
  return kind in {tkIf, tkElse, tkWhile, tkDo, tkLoop, tkFor, tkIn, tkBreak,
    tkContinue, tkReturn, tkMatch, tkFunc, tkLet, tkVar, tkConst, tkType,
    tkStruct, tkEnum, tkUnion, tkInterface, tkExtend, tkModule, tkImport,
    tkPub, tkExtern, tkAs, tkIs, tkNull, tkSelf, tkSuper, tkSizeOf, tkOwn,
    tkDiscard}

proc expectIdentOrKeyword(p: var Parser, message: string): Token =
  ## Accept identifier OR keyword token as a name (for field names, param names, etc.)
  if p.check(tkIdent) or isKeywordToken(p.at.kind):
    return p.advance()
  let tok = p.at
  p.diagnostics.add(ParserDiagnostic(
    severity: pdsError,
    loc: tok.loc,
    message: message & " (got " & tokenKindName(tok.kind) & ")"
  ))
  result = tok

proc previous(p: Parser): Token =
  if p.pos > 0 and p.pos <= p.tokens.len:
    return p.tokens[p.pos - 1]
  return Token(kind: tkEndOfFile)

proc currentLoc(p: Parser): SourceLocation =
  p.at.loc

proc emitError(p: var Parser, loc: SourceLocation, message: string) =
  p.diagnostics.add(ParserDiagnostic(severity: pdsError, loc: loc, message: message))

proc skipNewlines(p: var Parser) =
  while p.check(tkNewLine): discard p.advance()

proc emitError(p: var Parser, message: string) =
  p.emitError(p.currentLoc, message)

proc isAtEnd(p: Parser): bool =
  p.peek() == tkEndOfFile

# ---------------------------------------------------------------------------
# Recovery
# ---------------------------------------------------------------------------

proc synchronize(p: var Parser) =
  ## Skip tokens until a declaration boundary.
  discard p.advance()
  while not p.isAtEnd:
    if p.previous.kind == tkSemicolon: return
    case p.peek()
    of tkFunc, tkStruct, tkEnum, tkUnion, tkInterface, tkExtend,
       tkModule, tkImport, tkConst, tkType, tkExtern, tkPub:
      return
    else:
      discard p.advance()

# ---------------------------------------------------------------------------
# Forward declarations for mutual recursion
# ---------------------------------------------------------------------------

proc parseDecl(p: var Parser): Decl
proc parseType(p: var Parser): TypeExpr
proc parseExpr(p: var Parser): Expr
proc parseStmt(p: var Parser): Stmt
proc parseBlock(p: var Parser): Block
proc parsePattern(p: var Parser): Pattern

# ---------------------------------------------------------------------------
# Attributes
# ---------------------------------------------------------------------------

type
  ParsedAttrs* = object
    importLib*: string
    callConv*: CallingConvention
    targetOs*: string
    checked*: bool             ## @[Checked] — enable borrow checking
    shared*: bool              ## @[Shared] — mark function as thread-safe

proc parseAttrs(p: var Parser): ParsedAttrs =
  while p.check(tkAt):
    discard p.advance()  # @
    discard p.expect(tkLBracket, "expected '[' after '@'")
    let name = p.expect(tkIdent, "expected attribute name").text
    if name == "Checked":
      result.checked = true
    elif name == "Shared":
      result.shared = true
    elif name == "Import":
      discard p.expect(tkLParen, "expected '('")
      let key = p.expect(tkIdent, "expected attribute key").text
      if key == "lib":
        discard p.expect(tkColon, "expected ':'")
        result.importLib = p.expect(tkStringLiteral, "expected string literal").text
      discard p.expect(tkRParen, "expected ')'")
    discard p.expect(tkRBracket, "expected ']'")

# ---------------------------------------------------------------------------
# Type expressions
# ---------------------------------------------------------------------------

proc parseBaseType(p: var Parser): TypeExpr =
  let loc = p.currentLoc
  case p.peek()
  of tkIdent:
    let name = p.advance().text
    if name == "self":
      return TypeExpr(kind: tekSelf, loc: loc)
    if p.check(tkLt):
      var typeArgs: seq[TypeExpr] = @[]
      discard p.advance()
      while not p.check(tkGt) and not p.isAtEnd:
        while p.check(tkNewLine):
          discard p.advance()
        if p.check(tkGt) or p.isAtEnd:
          break
        typeArgs.add(p.parseType())
        if p.check(tkComma):
          discard p.advance()
      discard p.expect(tkGt, "expected '>' to close type arguments")
      return TypeExpr(kind: tekNamed, loc: loc, typeName: name, typeArgs: typeArgs)
    return TypeExpr(kind: tekNamed, loc: loc, typeName: name)
  of tkOwn:
    discard p.advance()
    return TypeExpr(kind: tekOwn, loc: loc, pointerPointee: p.parseBaseType(), refLifetime: "")
  of tkStar:
    discard p.advance()
    return TypeExpr(kind: tekPointer, loc: loc, pointerPointee: p.parseBaseType(), refLifetime: "")
  of tkAmp:
    discard p.advance()
    var lt = ""
    if p.check(tkLifetime):
      lt = p.advance().text
    if p.check(tkMut):
      discard p.advance()
      return TypeExpr(kind: tekMutRef, loc: loc, refLifetime: lt, pointerPointee: p.parseBaseType())
    if p.check(tkDyn):
      discard p.advance()
      let ifaceName = p.expect(tkIdent, "expected interface name after 'dyn'").text
      return TypeExpr(kind: tekDynRef, loc: loc, dynInterface: ifaceName)
    return TypeExpr(kind: tekRef, loc: loc, refLifetime: lt, pointerPointee: p.parseBaseType())
  of tkLParen:
    discard p.advance()
    var elems: seq[TypeExpr] = @[]
    while not p.check(tkRParen) and not p.isAtEnd:
      elems.add(p.parseType())
      if p.check(tkComma):
        discard p.advance()
    discard p.expect(tkRParen, "expected ')' to close tuple type")
    return TypeExpr(kind: tekTuple, loc: loc, tupleElements: elems)
  else:
    p.emitError(loc, "expected type expression")
    return TypeExpr(kind: tekNamed, loc: loc, typeName: "")

proc parseType(p: var Parser): TypeExpr =
  var left = p.parseBaseType()
  while p.check(tkLBracket):
    let loc = p.currentLoc
    discard p.advance()
    if p.check(tkRBracket):
      discard p.advance()
      left = TypeExpr(kind: tekSlice, loc: loc, sliceElement: left, sliceSize: nil)
    else:
      let sizeExpr = p.parseExpr()
      discard p.expect(tkRBracket, "expected ']' to close array size")
      left = TypeExpr(kind: tekSlice, loc: loc, sliceElement: left, sliceSize: sizeExpr)
  # Path types: Std::Io::Reader
  while p.check(tkColonColon):
    discard p.advance()
    let nextSeg = p.expect(tkIdent, "expected identifier after '::'")
    if left.kind == tekNamed:
      var segs = @[left.typeName]
      segs.add(nextSeg.text)
      left = TypeExpr(kind: tekPath, loc: left.loc, pathSegments: segs)
    elif left.kind == tekPath:
      left.pathSegments.add(nextSeg.text)
  return left

# ---------------------------------------------------------------------------
# Patterns
# ---------------------------------------------------------------------------

proc parsePrimaryPattern(p: var Parser): Pattern =
  let loc = p.currentLoc
  case p.peek()
  of tkUnderscore:
    discard p.advance()
    return Pattern(kind: pkWildcard, loc: loc)
  of tkIntLiteral, tkFloatLiteral, tkStringLiteral, tkCharLiteral, tkBoolLiteral:
    return Pattern(kind: pkLiteral, loc: loc, patLit: p.advance())
  of tkIdent:
    let name = p.advance().text
    if name == "true" or name == "false":
      # These were lexed as BoolLiteral already, but just in case
      return Pattern(kind: pkLiteral, loc: loc, patLit: Token(kind: tkBoolLiteral, text: name, loc: loc))
    # Could be enum pattern or ident pattern
    if p.check(tkColonColon):
      var path = @[name]
      while p.check(tkColonColon):
        discard p.advance()
        path.add(p.expect(tkIdent, "expected identifier in pattern path").text)
      if p.check(tkLParen):
        discard p.advance()
        var args: seq[Pattern] = @[]
        var named: seq[tuple[name: string, pattern: Pattern]] = @[]
        while not p.check(tkRParen) and not p.isAtEnd:
          if p.check(tkIdent) and p.peek(1) == tkColon:
            let fieldName = p.advance().text
            discard p.advance()  # :
            named.add((fieldName, p.parsePattern()))
          else:
            args.add(p.parsePattern())
          if p.check(tkComma):
            discard p.advance()
        discard p.expect(tkRParen, "expected ')' to close enum pattern")
        return Pattern(kind: pkEnum, loc: loc, patEnumPath: path, patEnumArgs: args, patEnumNamed: named)
      return Pattern(kind: pkEnum, loc: loc, patEnumPath: path, patEnumArgs: @[], patEnumNamed: @[])
    elif p.check(tkLBrace):
      # Struct pattern: Point { x: 0, y: 0 }
      discard p.advance()
      var fields: seq[tuple[name: string, pattern: Pattern]] = @[]
      while not p.check(tkRBrace) and not p.isAtEnd:
        while p.check(tkNewLine):
          discard p.advance()
        if p.check(tkRBrace) or p.isAtEnd:
          break
        let fieldName = p.expect(tkIdent, "expected field name in struct pattern").text
        discard p.expect(tkColon, "expected ':' after field name in pattern")
        fields.add((fieldName, p.parsePattern()))
        if p.check(tkComma):
          discard p.advance()
      discard p.expect(tkRBrace, "expected '}' to close struct pattern")
      return Pattern(kind: pkStruct, loc: loc, patStructName: name, patStructFields: fields)
    elif p.check(tkLParen):
      # Enum-like pattern with path of length 1
      discard p.advance()
      var args: seq[Pattern] = @[]
      while not p.check(tkRParen) and not p.isAtEnd:
        args.add(p.parsePattern())
        if p.check(tkComma):
          discard p.advance()
      discard p.expect(tkRParen, "expected ')' to close pattern")
      return Pattern(kind: pkEnum, loc: loc, patEnumPath: @[name], patEnumArgs: args)
    return Pattern(kind: pkIdent, loc: loc, patIdent: name)
  of tkLParen:
    discard p.advance()
    var elems: seq[Pattern] = @[]
    while not p.check(tkRParen) and not p.isAtEnd:
      elems.add(p.parsePattern())
      if p.check(tkComma):
        discard p.advance()
    discard p.expect(tkRParen, "expected ')' to close tuple pattern")
    return Pattern(kind: pkTuple, loc: loc, patTupleElements: elems)
  else:
    p.emitError(loc, "expected pattern")
    return Pattern(kind: pkWildcard, loc: loc)

proc parsePattern(p: var Parser): Pattern =
  let loc = p.currentLoc
  var left = p.parsePrimaryPattern()
  # Range pattern
  if p.check(tkDotDot) or p.check(tkDotDotEqual):
    let inclusive = p.check(tkDotDotEqual)
    discard p.advance()
    let right = p.parsePrimaryPattern()
    return Pattern(kind: pkRange, loc: loc, patRangeLo: left, patRangeHi: right, patRangeInclusive: inclusive)
  # Guarded pattern
  if p.check(tkIf):
    discard p.advance()
    let guard = p.parseExpr()
    return Pattern(kind: pkGuarded, loc: loc, patGuardedInner: left, patGuardedExpr: guard)
  return left

# ---------------------------------------------------------------------------
# Expressions (Pratt / precedence climbing)
# ---------------------------------------------------------------------------

proc parsePrimary(p: var Parser): Expr
proc parsePostfix(p: var Parser): Expr
proc parseUnary(p: var Parser): Expr
proc parseExp(p: var Parser): Expr
proc parseMul(p: var Parser): Expr
proc parseAdd(p: var Parser): Expr
proc parseShift(p: var Parser): Expr
proc parseCast(p: var Parser): Expr
proc parseComparison(p: var Parser): Expr
proc parseRange(p: var Parser): Expr
proc parseEquality(p: var Parser): Expr
proc parseBitAnd(p: var Parser): Expr
proc parseBitXor(p: var Parser): Expr
proc parseBitOr(p: var Parser): Expr
proc parseAnd(p: var Parser): Expr
proc parseOr(p: var Parser): Expr
proc parseTernary(p: var Parser): Expr
proc parseAssign(p: var Parser): Expr

proc parseExpr(p: var Parser): Expr =
  p.parseAssign()

proc parsePrimary(p: var Parser): Expr =
  let loc = p.currentLoc
  case p.peek()
  of tkIntLiteral, tkFloatLiteral, tkStringLiteral, tkCharLiteral, tkBoolLiteral:
    return newLiteralExpr(p.advance())
  of tkSelf:
    discard p.advance()
    return Expr(kind: ekSelf, loc: loc)
  of tkIdent:
    let name = p.advance().text
    # Path expression: a::b::c
    if p.check(tkColonColon):
      var segs = @[name]
      while p.check(tkColonColon):
        discard p.advance()
        segs.add(p.expect(tkIdent, "expected identifier in path").text)
      return Expr(kind: ekPath, loc: loc, exprPath: segs)
    return newIdentExpr(name, loc)
  of tkLParen:
    discard p.advance()
    if p.check(tkRParen):
      discard p.advance()
      return Expr(kind: ekTuple, loc: loc, exprTupleElements: @[])
    let expr = p.parseExpr()
    if p.check(tkComma):
      # Tuple expression
      var elems = @[expr]
      while p.check(tkComma):
        discard p.advance()
        elems.add(p.parseExpr())
      discard p.expect(tkRParen, "expected ')' to close tuple")
      return Expr(kind: ekTuple, loc: loc, exprTupleElements: elems)
    discard p.expect(tkRParen, "expected ')'")
    return expr
  of tkLBrace:
    # Block expression
    let blk = p.parseBlock()
    return Expr(kind: ekBlock, loc: loc, exprBlock: blk)
  of tkLBracket:
    # Slice expression [a, b, c]
    discard p.advance()
    var elems: seq[Expr] = @[]
    while not p.check(tkRBracket) and not p.isAtEnd:
      elems.add(p.parseExpr())
      if p.check(tkComma):
        discard p.advance()
    discard p.expect(tkRBracket, "expected ']' to close slice")
    return Expr(kind: ekSlice, loc: loc, exprSliceElements: elems)
  of tkMatch:
    discard p.advance()
    p.structInitAllowed = false
    let subject = p.parseExpr()
    p.structInitAllowed = true
    discard p.expect(tkLBrace, "expected '{' to start match")
    var arms: seq[MatchArm] = @[]
    while not p.check(tkRBrace) and not p.isAtEnd:
      let armLoc = p.currentLoc
      let pat = p.parsePattern()
      discard p.expect(tkFatArrow, "expected '=>' in match arm")
      let body = p.parseExpr()
      arms.add(MatchArm(loc: armLoc, pattern: pat, body: body))
      if p.check(tkComma):
        discard p.advance()
    discard p.expect(tkRBrace, "expected '}' to close match")
    return Expr(kind: ekMatch, loc: loc, exprMatchSubject: subject, exprMatchArms: arms)
  of tkMinus, tkBang, tkTilde, tkStar, tkAmp, tkPlusPlus, tkMinusMinus:
    # These are handled in parseUnary, but ++/-- as prefix are rare
    return p.parseUnary()
  of tkSizeOf:
    discard p.advance()  # sizeof
    discard p.expect(tkLParen, "expected '('")
    let ty = p.parseType()
    discard p.expect(tkRParen, "expected ')'")
    return Expr(kind: ekSizeOf, loc: loc, exprSizeOfType: ty)
  of tkSpawn:
    discard p.advance()  # spawn
    let callee = p.parsePrimary()
    var args: seq[Expr] = @[]
    if p.check(tkLParen):
      discard p.advance()  # (
      while not p.check(tkRParen) and not p.isAtEnd:
        args.add(p.parseExpr())
        if p.check(tkComma):
          discard p.advance()
      discard p.expect(tkRParen, "expected ')' after spawn arguments")
    return Expr(kind: ekSpawn, loc: loc, exprSpawnCallee: callee, exprSpawnArgs: args, exprSpawnAsync: false)
  of tkHashLine:
    discard p.advance()
    return Expr(kind: ekIntrinsic, loc: loc, exprIntrinsic: ikLine)
  of tkHashColumn:
    discard p.advance()
    return Expr(kind: ekIntrinsic, loc: loc, exprIntrinsic: ikColumn)
  of tkHashFile:
    discard p.advance()
    return Expr(kind: ekIntrinsic, loc: loc, exprIntrinsic: ikFile)
  of tkHashFunction:
    discard p.advance()
    return Expr(kind: ekIntrinsic, loc: loc, exprIntrinsic: ikFunction)
  of tkHashDate:
    discard p.advance()
    return Expr(kind: ekIntrinsic, loc: loc, exprIntrinsic: ikDate)
  of tkHashTime:
    discard p.advance()
    return Expr(kind: ekIntrinsic, loc: loc, exprIntrinsic: ikTime)
  of tkHashModule:
    discard p.advance()
    return Expr(kind: ekIntrinsic, loc: loc, exprIntrinsic: ikModule)
  of tkNull:
    discard p.advance()
    return newLiteralExpr(Token(kind: tkNull, text: "null", loc: loc))
  else:
    p.emitError(loc, "expected expression")
    discard p.advance()
    return newLiteralExpr(Token(kind: tkIntLiteral, text: "0", loc: loc))

proc parsePostfix(p: var Parser): Expr =
  var left = p.parsePrimary()
  while true:
    let loc = p.currentLoc
    case p.peek()
    of tkLParen:
      # Call expression
      discard p.advance()
      var args: seq[Expr] = @[]
      while not p.check(tkRParen) and not p.isAtEnd:
        if p.check(tkDotDotDot):
          discard p.advance()
          let operand = p.parseExpr()
          args.add(Expr(kind: ekSpread, loc: operand.loc, exprSpreadOperand: operand))
        else:
          args.add(p.parseExpr())
        if p.check(tkComma):
          discard p.advance()
      discard p.expect(tkRParen, "expected ')' to close call")
      left = Expr(kind: ekCall, loc: loc, exprCallCallee: left, exprCallArgs: args)
    of tkLt:
      # Generic type arguments: Max<int>(10, 20)
      # Only treat '<' as generic args if lookahead confirms a matching '>'
      if left.kind == ekIdent and p.isTypeArgListAhead():
        discard p.advance()
        var typeArgs: seq[TypeExpr] = @[]
        while not p.check(tkGt) and not p.isAtEnd:
          typeArgs.add(p.parseType())
          if p.check(tkComma):
            discard p.advance()
        discard p.expect(tkGt, "expected '>' to close type arguments")
        # Store type args in the identifier for later use
        left = Expr(kind: ekGenericCall, loc: loc, exprGenericCallee: left.exprIdent, exprGenericTypeArgs: typeArgs)
      else:
        break
    of tkLBracket:
      # Index expression
      discard p.advance()
      let idx = p.parseExpr()
      discard p.expect(tkRBracket, "expected ']' to close index")
      left = Expr(kind: ekIndex, loc: loc, exprIndexObj: left, exprIndexIdx: idx, exprIndexBoundsCheck: false)
    of tkDot:
      # Field expression or .await
      discard p.advance()
      if p.check(tkAwait):
        discard p.advance()
        left = Expr(kind: ekAwait, loc: loc, exprAwaitOperand: left)
      else:
        let fieldName = p.expectIdentOrKeyword("expected field name after '.'").text
        left = Expr(kind: ekField, loc: loc, exprFieldObj: left, exprFieldName: fieldName)
    of tkPlusPlus, tkMinusMinus:
      let op = p.advance().kind
      left = Expr(kind: ekPostfix, loc: loc, exprPostfixOp: op, exprPostfixOperand: left)
    of tkAs:
      discard p.advance()
      let ty = p.parseType()
      left = Expr(kind: ekCast, loc: loc, exprCastOperand: left, exprCastType: ty)
    of tkIs:
      discard p.advance()
      let ty = p.parseType()
      left = Expr(kind: ekIs, loc: loc, exprIsOperand: left, exprIsType: ty)
    of tkQuestion:
      discard p.advance()
      left = Expr(kind: ekTry, loc: loc, exprTryOperand: left, exprTryType: nil)
    of tkBang:
      discard p.advance()
      left = Expr(kind: ekUnwrap, loc: loc, exprUnwrapOperand: left)
    of tkLBrace:
      if p.structInitAllowed and left.kind in {ekIdent, ekPath, ekGenericCall}:
        discard p.advance()
        var fields: seq[tuple[name: string, value: Expr]] = @[]
        while not p.check(tkRBrace) and not p.isAtEnd:
          while p.check(tkNewLine): discard p.advance()
          if p.check(tkRBrace) or p.isAtEnd: break
          let fieldName = p.expect(tkIdent, "expected field name").text
          discard p.expect(tkColon, "expected ':'")
          let fieldValue = p.parseExpr()
          fields.add((fieldName, fieldValue))
          if p.check(tkComma):
            discard p.advance()
        discard p.expect(tkRBrace, "expected '}'")
        var typeName = ""
        var typeArgs: seq[TypeExpr] = @[]
        if left.kind == ekIdent:
          typeName = left.exprIdent
        elif left.kind == ekPath:
          typeName = left.exprPath.join("::")
        elif left.kind == ekGenericCall:
          typeName = left.exprGenericCallee
          typeArgs = left.exprGenericTypeArgs
        left = Expr(kind: ekStructInit, loc: loc, exprStructInitName: typeName,
                    exprStructInitTypeArgs: typeArgs, exprStructInitFields: fields)
      else:
        break
    else:
      break
  return left

proc parseUnary(p: var Parser): Expr =
  let loc = p.currentLoc
  case p.peek()
  of tkBorrow:
    discard p.advance()  # borrow
    discard p.expect(tkAmp, "expected '&' after 'borrow'")
    var isMut = p.check(tkMut)
    if isMut:
      discard p.advance()  # mut
    let operand = p.parseUnary()  # parse the moved value
    return Expr(kind: ekBorrow, loc: loc, exprBorrowOperand: operand, exprBorrowMutable: isMut)
  of tkBang, tkMinus, tkTilde, tkStar, tkAmp:
    let op = p.advance().kind
    if op == tkAmp and p.check(tkMut):
      discard p.advance()  # mut
    let savedStructInit = p.structInitAllowed
    p.structInitAllowed = false
    let operand = p.parseUnary()
    p.structInitAllowed = savedStructInit
    return Expr(kind: ekUnary, loc: loc, exprUnaryOp: op, exprUnaryOperand: operand)
  of tkPlusPlus, tkMinusMinus:
    let op = p.advance().kind
    let operand = p.parseUnary()
    return Expr(kind: ekUnary, loc: loc, exprUnaryOp: op, exprUnaryOperand: operand)
  else:
    return p.parsePostfix()

proc parseExp(p: var Parser): Expr =
  let loc = p.currentLoc
  var left = p.parseUnary()
  while p.check(tkStarStar):
    let op = p.advance().kind
    let right = p.parseUnary()  # right-associative: parseUnary not parseExp
    left = newBinaryExpr(op, left, right, loc)
  return left

proc parseMul(p: var Parser): Expr =
  let loc = p.currentLoc
  var left = p.parseExp()
  while p.checkAny([tkStar, tkSlash, tkPercent]):
    let op = p.advance().kind
    let right = p.parseExp()
    left = newBinaryExpr(op, left, right, loc)
  return left

proc parseAdd(p: var Parser): Expr =
  let loc = p.currentLoc
  var left = p.parseMul()
  while p.checkAny([tkPlus, tkMinus]):
    let op = p.advance().kind
    let right = p.parseMul()
    left = newBinaryExpr(op, left, right, loc)
  return left

proc parseShift(p: var Parser): Expr =
  let loc = p.currentLoc
  var left = p.parseAdd()
  while p.checkAny([tkShl, tkShr]):
    let op = p.advance().kind
    let right = p.parseAdd()
    left = newBinaryExpr(op, left, right, loc)
  return left

proc parseCast(p: var Parser): Expr =
  let loc = p.currentLoc
  var left = p.parseShift()
  # 'as' and 'is' are handled in postfix for chaining
  return left

proc parseComparison(p: var Parser): Expr =
  let loc = p.currentLoc
  var left = p.parseCast()
  while p.checkAny([tkLt, tkLe, tkGt, tkGe]):
    let op = p.advance().kind
    let right = p.parseCast()
    left = newBinaryExpr(op, left, right, loc)
  return left

proc parseRange(p: var Parser): Expr =
  let loc = p.currentLoc
  var left = p.parseComparison()
  if p.check(tkDotDot) or p.check(tkDotDotEqual):
    let inclusive = p.check(tkDotDotEqual)
    discard p.advance()
    let right = p.parseComparison()
    return Expr(kind: ekRange, loc: loc, exprRangeLo: left, exprRangeHi: right, exprRangeInclusive: inclusive)
  return left

proc parseEquality(p: var Parser): Expr =
  let loc = p.currentLoc
  var left = p.parseRange()
  while p.checkAny([tkEq, tkNe]):
    let op = p.advance().kind
    let right = p.parseRange()
    left = newBinaryExpr(op, left, right, loc)
  return left

proc parseBitAnd(p: var Parser): Expr =
  let loc = p.currentLoc
  var left = p.parseEquality()
  while p.check(tkAmp):
    let op = p.advance().kind
    let right = p.parseEquality()
    left = newBinaryExpr(op, left, right, loc)
  return left

proc parseBitXor(p: var Parser): Expr =
  let loc = p.currentLoc
  var left = p.parseBitAnd()
  while p.check(tkCaret):
    let op = p.advance().kind
    let right = p.parseBitAnd()
    left = newBinaryExpr(op, left, right, loc)
  return left

proc parseBitOr(p: var Parser): Expr =
  let loc = p.currentLoc
  var left = p.parseBitXor()
  while p.check(tkPipe):
    let op = p.advance().kind
    let right = p.parseBitXor()
    left = newBinaryExpr(op, left, right, loc)
  return left

proc parseAnd(p: var Parser): Expr =
  let loc = p.currentLoc
  var left = p.parseBitOr()
  p.skipNewlines()
  while p.check(tkAmpAmp):
    let op = p.advance().kind
    p.skipNewlines()
    let right = p.parseBitOr()
    left = newBinaryExpr(op, left, right, loc)
    p.skipNewlines()
  return left

proc parseOr(p: var Parser): Expr =
  let loc = p.currentLoc
  var left = p.parseAnd()
  p.skipNewlines()
  while p.check(tkPipePipe):
    let op = p.advance().kind
    p.skipNewlines()
    let right = p.parseAnd()
    left = newBinaryExpr(op, left, right, loc)
    p.skipNewlines()
  return left

proc parseTernary(p: var Parser): Expr =
  let loc = p.currentLoc
  var cond = p.parseOr()
  if p.check(tkQuestion):
    discard p.advance()
    let thenExpr = p.parseExpr()
    discard p.expect(tkColon, "expected ':' in ternary expression")
    let elseExpr = p.parseTernary()
    return Expr(kind: ekTernary, loc: loc, exprTernaryCond: cond, exprTernaryThen: thenExpr, exprTernaryElse: elseExpr)
  return cond

proc parseAssign(p: var Parser): Expr =
  let loc = p.currentLoc
  var left = p.parseTernary()
  if p.checkAny([tkAssign, tkPlusAssign, tkMinusAssign, tkStarAssign, tkSlashAssign,
                 tkPercentAssign, tkAmpAssign, tkPipeAssign, tkCaretAssign,
                 tkShlAssign, tkShrAssign]):
    let op = p.advance().kind
    let right = p.parseAssign()  # right-associative
    return Expr(kind: ekAssign, loc: loc, exprAssignOp: op, exprAssignTarget: left, exprAssignValue: right)
  return left

# ---------------------------------------------------------------------------
# Block
# ---------------------------------------------------------------------------

proc parseBlock(p: var Parser): Block =
  let loc = p.currentLoc
  discard p.expect(tkLBrace, "expected '{' to start block")
  result = newBlock(loc)
  while not p.check(tkRBrace) and not p.isAtEnd:
    while p.check(tkNewLine):
      discard p.advance()
    if p.check(tkRBrace) or p.isAtEnd:
      break
    result.stmts.add(p.parseStmt())
  discard p.expect(tkRBrace, "expected '}' to close block")

# ---------------------------------------------------------------------------
# Statements
# ---------------------------------------------------------------------------

proc parseStmt(p: var Parser): Stmt =
  let loc = p.currentLoc
  case p.peek()
  of tkLet, tkVar:
    let isMut = p.peek() == tkVar
    discard p.advance()
    let name = p.expect(tkIdent, "expected variable name").text
    var pat: Pattern = nil
    var ty: TypeExpr = nil
    if p.check(tkColon):
      discard p.advance()
      ty = p.parseType()
    var initExpr: Expr = nil
    if p.check(tkAssign):
      discard p.advance()
      initExpr = p.parseExpr()
    elif not isMut:
      discard p.expect(tkAssign, "expected '=' in let statement")
    if p.check(tkSemicolon):
      discard p.advance()
    return Stmt(kind: skLet, loc: loc, stmtLetMut: isMut, stmtLetName: name,
                stmtLetPattern: pat, stmtLetType: ty, stmtLetInit: initExpr)
  of tkIf:
    discard p.advance()
    p.structInitAllowed = false
    let cond = p.parseExpr()
    p.structInitAllowed = true
    let thenBlk = p.parseBlock()
    var elseIfs: seq[ElseIf] = @[]
    var elseBlk: Block = nil
    while p.check(tkNewLine): discard p.advance()
    while p.check(tkElse):
      let elseLoc = p.currentLoc
      discard p.advance()
      while p.check(tkNewLine): discard p.advance()
      if p.check(tkIf):
        discard p.advance()
        p.structInitAllowed = false
        let elifCond = p.parseExpr()
        p.structInitAllowed = true
        let elifBlk = p.parseBlock()
        elseIfs.add(ElseIf(loc: elseLoc, cond: elifCond, blk: elifBlk))
        while p.check(tkNewLine): discard p.advance()
      else:
        elseBlk = p.parseBlock()
        break
    return Stmt(kind: skIf, loc: loc, stmtIfCond: cond, stmtIfThen: thenBlk,
                stmtIfElseIfs: elseIfs, stmtIfElse: elseBlk)
  of tkWhile:
    discard p.advance()
    p.structInitAllowed = false
    let cond = p.parseExpr()
    p.structInitAllowed = true
    let body = p.parseBlock()
    return Stmt(kind: skWhile, loc: loc, stmtWhileCond: cond, stmtWhileBody: body)
  of tkDo:
    discard p.advance()
    let body = p.parseBlock()
    discard p.expect(tkWhile, "expected 'while' after 'do' block")
    let cond = p.parseExpr()
    if p.check(tkSemicolon):
      discard p.advance()
    return Stmt(kind: skDoWhile, loc: loc, stmtDoWhileBody: body, stmtDoWhileCond: cond)
  of tkLoop:
    discard p.advance()
    let body = p.parseBlock()
    return Stmt(kind: skLoop, loc: loc, stmtLoopBody: body)
  of tkFor:
    discard p.advance()
    let varName = p.expect(tkIdent, "expected loop variable name").text
    discard p.expect(tkIn, "expected 'in' in for loop")
    p.structInitAllowed = false
    let iter = p.parseExpr()
    p.structInitAllowed = true
    let body = p.parseBlock()
    return Stmt(kind: skFor, loc: loc, stmtForVar: varName, stmtForIter: iter, stmtForBody: body)
  of tkMatch:
    discard p.advance()
    p.structInitAllowed = false
    let subject = p.parseExpr()
    p.structInitAllowed = true
    # Skip newlines before opening brace
    while p.check(tkNewLine):
      discard p.advance()
    discard p.expect(tkLBrace, "expected '{' to start match")
    var arms: seq[MatchArm] = @[]
    while not p.check(tkRBrace) and not p.isAtEnd:
      # Skip newlines
      while p.check(tkNewLine):
        discard p.advance()
      if p.check(tkRBrace) or p.isAtEnd:
        break
      let armLoc = p.currentLoc
      let pat = p.parsePattern()
      discard p.expect(tkFatArrow, "expected '=>' in match arm")
      let body = p.parseExpr()
      arms.add(MatchArm(loc: armLoc, pattern: pat, body: body))
      if p.check(tkComma):
        discard p.advance()
    discard p.expect(tkRBrace, "expected '}' to close match")
    return Stmt(kind: skExpr, loc: loc, stmtExpr: Expr(kind: ekMatch, loc: loc, exprMatchSubject: subject, exprMatchArms: arms))
  of tkReturn:
    discard p.advance()
    var val: Expr = nil
    if not p.check(tkSemicolon) and not p.check(tkRBrace):
      val = p.parseExpr()
    if p.check(tkSemicolon):
      discard p.advance()
    return Stmt(kind: skReturn, loc: loc, stmtReturnValue: val)
  of tkBreak:
    discard p.advance()
    var label = ""
    if p.check(tkIdent):
      label = p.advance().text
    if p.check(tkSemicolon):
      discard p.advance()
    return Stmt(kind: skBreak, loc: loc, stmtBreakLabel: label)
  of tkContinue:
    discard p.advance()
    var label = ""
    if p.check(tkIdent):
      label = p.advance().text
    if p.check(tkSemicolon):
      discard p.advance()
    return Stmt(kind: skContinue, loc: loc, stmtContinueLabel: label)
  of tkStaticAssert:
    discard p.advance()
    let cond = p.parseExpr()
    var msg: Expr = nil
    if p.check(tkComma):
      discard p.advance()
      msg = p.parseExpr()
    if p.check(tkSemicolon):
      discard p.advance()
    return Stmt(kind: skStaticAssert, loc: loc, stmtStaticAssertCond: cond, stmtStaticAssertMsg: msg)
  of tkComptime:
    discard p.advance()
    let blk = p.parseBlock()
    return Stmt(kind: skComptime, loc: loc, stmtComptimeBlock: blk)
  of tkHashEmit:
    discard p.advance()
    let expr = p.parseExpr()
    if p.check(tkSemicolon):
      discard p.advance()
    return Stmt(kind: skEmit, loc: loc, stmtEmitExpr: expr, stmtEmitEvaluated: "")
  of tkDiscard:
    discard p.advance()
    var val: Expr = nil
    if not p.check(tkSemicolon) and not p.check(tkRBrace) and not p.check(tkNewLine):
      val = p.parseExpr()
    if p.check(tkSemicolon):
      discard p.advance()
    # discard expr → expression statement; discard; → no-op (nil expr)
    if val != nil:
      return Stmt(kind: skExpr, loc: loc, stmtExpr: val)
    else:
      # No-op: emit literal 0 as expression statement
      let zeroTok = Token(kind: tkIntLiteral, text: "0", loc: loc)
      return Stmt(kind: skExpr, loc: loc, stmtExpr: Expr(kind: ekLiteral, loc: loc, exprLit: zeroTok))
  of tkFunc, tkStruct, tkEnum, tkUnion, tkInterface, tkExtend, tkModule,
     tkImport, tkConst, tkType, tkExtern, tkPub:
    # Local declaration
    let decl = p.parseDecl()
    return Stmt(kind: skDecl, loc: loc, stmtDecl: decl)
  else:
    # Expression statement
    let expr = p.parseExpr()
    if p.check(tkSemicolon):
      discard p.advance()
    return Stmt(kind: skExpr, loc: loc, stmtExpr: expr)

# ---------------------------------------------------------------------------
# Declarations
# ---------------------------------------------------------------------------

proc parseTypeParams(p: var Parser): seq[TypeParam] =
  if p.check(tkLt):
    discard p.advance()
    while not p.check(tkGt) and not p.isAtEnd:
      while p.check(tkNewLine):
        discard p.advance()
      if p.check(tkGt) or p.isAtEnd:
        break
      var name = ""
      var isLifetime = false
      if p.check(tkIdent):
        name = p.advance().text
      elif p.check(tkLifetime):
        name = p.advance().text
        isLifetime = true
      else:
        discard p.expect(tkIdent, "expected type parameter name")
      var bounds: seq[string] = @[]
      if p.check(tkColon):
        discard p.advance()
        # Parse bound: single identifier or path like Std::Comparable
        var boundName = ""
        while true:
          let part = p.expect(tkIdent, "expected trait/interface name").text
          if boundName.len > 0:
            boundName.add("_")
          boundName.add(part)
          if p.check(tkColonColon):
            discard p.advance()
          else:
            break
        bounds.add(boundName)
      result.add(TypeParam(name: name, bounds: bounds, isLifetime: isLifetime))
      if p.check(tkComma):
        discard p.advance()
    discard p.expect(tkGt, "expected '>' to close type parameters")

proc parseParamList(p: var Parser, allowVariadic: bool = false): seq[Param] =
  discard p.expect(tkLParen, "expected '('")
  while not p.check(tkRParen) and not p.isAtEnd:
    while p.check(tkNewLine):
      discard p.advance()
    if p.check(tkRParen) or p.isAtEnd:
      break
    let loc = p.currentLoc
    var isVar = false
    if allowVariadic and p.check(tkDotDotDot):
      discard p.advance()
      let nameTok = p.at
      var name = ""
      if nameTok.kind == tkIdent:
        name = p.advance().text
      elif nameTok.kind == tkSelf:
        name = p.advance().text
      else:
        name = p.expect(tkIdent, "expected parameter name after '...'").text
      let ty = p.parseType()
      result.add(Param(loc: loc, name: name, ptype: ty, isVariadic: true))
    else:
      let nameTok = p.at
      var name = ""
      if nameTok.kind == tkIdent:
        name = p.advance().text
      elif nameTok.kind == tkSelf:
        name = p.advance().text
      else:
        name = p.expect(tkIdent, "expected parameter name").text
      discard p.expect(tkColon, "expected ':' after parameter name")
      let ty = p.parseType()
      var defaultVal: Expr = nil
      if p.check(tkAssign):
        discard p.advance()
        defaultVal = p.parseExpr()
      result.add(Param(loc: loc, name: name, ptype: ty, defaultValue: defaultVal))
    if p.check(tkComma):
      discard p.advance()
  discard p.expect(tkRParen, "expected ')' to close parameter list")

proc parseFuncDecl(p: var Parser, isPublic: bool, isAsm: bool, attrs: ParsedAttrs, isConst: bool = false, isAsync: bool = false): Decl =
  let loc = p.currentLoc
  discard p.expect(tkFunc, "expected 'func'")
  let name = p.expect(tkIdent, "expected function name").text
  let typeParams = p.parseTypeParams()
  let params = p.parseParamList(true)
  var retType: TypeExpr = nil
  if p.check(tkArrow):
    discard p.advance()
    retType = p.parseType()
  var body: Block = nil
  if p.check(tkLBrace):
    body = p.parseBlock()
  elif p.check(tkSemicolon):
    discard p.advance()
  var declAttrs: seq[string] = @[]
  if attrs.checked: declAttrs.add("Checked")
  return Decl(kind: dkFunc, loc: loc, isPublic: isPublic,
              declAttrs: declAttrs,
              declFuncAsm: isAsm, declFuncCallConv: attrs.callConv,
              declFuncConst: isConst, declFuncIsAsync: isAsync,
              declFuncName: name, declFuncTypeParams: typeParams,
              declFuncParams: params, declFuncReturnType: retType,
              declFuncBody: body)

proc parseStructDecl(p: var Parser, isPublic: bool): Decl =
  let loc = p.currentLoc
  discard p.expect(tkStruct, "expected 'struct'")
  let name = p.expect(tkIdent, "expected struct name").text
  let typeParams = p.parseTypeParams()
  discard p.expect(tkLBrace, "expected '{' to start struct body")
  var fields: seq[StructField] = @[]
  while not p.check(tkRBrace) and not p.isAtEnd:
    # Skip newlines
    while p.check(tkNewLine):
      discard p.advance()
    if p.check(tkRBrace) or p.isAtEnd:
      break
    let startPos = p.pos  # Track position for infinite-loop safeguard
    let fLoc = p.currentLoc
    var fPub = false
    if p.check(tkPub):
      fPub = true
      discard p.advance()
    let fName = p.expectIdentOrKeyword("expected field name").text
    discard p.expect(tkColon, "expected ':' after field name")
    let fType = p.parseType()
    if p.check(tkSemicolon) or p.check(tkComma):
      discard p.advance()
    fields.add(StructField(loc: fLoc, isPublic: fPub, name: fName, ftype: fType))
    # Infinite-loop safeguard: if no progress, advance
    if p.pos == startPos:
      discard p.advance()
  discard p.expect(tkRBrace, "expected '}' to close struct")
  return Decl(kind: dkStruct, loc: loc, isPublic: isPublic,
              declStructName: name, declStructTypeParams: typeParams,
              declStructFields: fields)

proc parseEnumDecl(p: var Parser, isPublic: bool): Decl =
  let loc = p.currentLoc
  discard p.expect(tkEnum, "expected 'enum'")
  let name = p.expect(tkIdent, "expected enum name").text
  var baseType: TypeExpr = nil
  if p.check(tkColon):
    discard p.advance()
    baseType = p.parseType()
  discard p.expect(tkLBrace, "expected '{' to start enum body")
  var variants: seq[EnumVariant] = @[]
  while not p.check(tkRBrace) and not p.isAtEnd:
    # Skip newlines
    while p.check(tkNewLine):
      discard p.advance()
    if p.check(tkRBrace) or p.isAtEnd:
      break
    let vLoc = p.currentLoc
    let vName = p.expect(tkIdent, "expected variant name").text
    var fields: seq[TypeExpr] = @[]
    var namedFields: seq[tuple[name: string, ftype: TypeExpr]] = @[]
    var discr: string = ""
    if p.check(tkLParen):
      discard p.advance()
      while not p.check(tkRParen) and not p.isAtEnd:
        if p.check(tkIdent) and p.peek(1) == tkColon:
          let fn = p.advance().text
          discard p.advance()  # :
          let ft = p.parseType()
          namedFields.add((fn, ft))
        else:
          fields.add(p.parseType())
        if p.check(tkComma):
          discard p.advance()
      discard p.expect(tkRParen, "expected ')' to close variant")
    if p.check(tkAssign):
      discard p.advance()
      discr = p.expect(tkIdent, "expected discriminant").text
    if p.check(tkComma):
      discard p.advance()
    variants.add(EnumVariant(loc: vLoc, name: vName, fields: fields,
                             namedFields: namedFields, discriminant: discr))
  discard p.expect(tkRBrace, "expected '}' to close enum")
  return Decl(kind: dkEnum, loc: loc, isPublic: isPublic,
              declEnumName: name, declEnumBaseType: baseType,
              declEnumVariants: variants)

proc parseUnionDecl(p: var Parser, isPublic: bool): Decl =
  let loc = p.currentLoc
  discard p.expect(tkUnion, "expected 'union'")
  let name = p.expect(tkIdent, "expected union name").text
  discard p.expect(tkLBrace, "expected '{' to start union body")
  var fields: seq[UnionField] = @[]
  while not p.check(tkRBrace) and not p.isAtEnd:
    let fLoc = p.currentLoc
    let fName = p.expect(tkIdent, "expected field name").text
    discard p.expect(tkColon, "expected ':' after field name")
    let fType = p.parseType()
    if p.check(tkSemicolon):
      discard p.advance()
    fields.add(UnionField(loc: fLoc, name: fName, ftype: fType))
  discard p.expect(tkRBrace, "expected '}' to close union")
  return Decl(kind: dkUnion, loc: loc, isPublic: isPublic,
              declUnionName: name, declUnionFields: fields)

proc parseInterfaceDecl(p: var Parser, isPublic: bool): Decl =
  let loc = p.currentLoc
  discard p.expect(tkInterface, "expected 'interface'")
  let name = p.expect(tkIdent, "expected interface name").text
  discard p.expect(tkLBrace, "expected '{' to start interface body")
  var methods: seq[Decl] = @[]
  var assocTypes: seq[string] = @[]
  while not p.check(tkRBrace) and not p.isAtEnd:
    # Skip newlines
    while p.check(tkNewLine):
      discard p.advance()
    if p.check(tkRBrace) or p.isAtEnd:
      break
    if p.check(tkType):
      discard p.advance()
      let assocName = p.expect(tkIdent, "expected associated type name").text
      if p.check(tkSemicolon):
        discard p.advance()
      assocTypes.add(assocName)
    else:
      methods.add(p.parseFuncDecl(false, false, ParsedAttrs()))
  discard p.expect(tkRBrace, "expected '}' to close interface")
  return Decl(kind: dkInterface, loc: loc, isPublic: isPublic,
              declInterfaceName: name, declInterfaceAssocTypes: assocTypes,
              declInterfaceMethods: methods)

proc parseImplDecl(p: var Parser): Decl =
  let loc = p.currentLoc
  discard p.expect(tkExtend, "expected 'extend'")
  let typeName = p.expect(tkIdent, "expected type name").text
  let typeParams = p.parseTypeParams()
  var interfaceName = ""
  if p.check(tkFor):
    discard p.advance()
    interfaceName = p.expect(tkIdent, "expected interface name").text
  discard p.expect(tkLBrace, "expected '{' to start impl block")
  var methods: seq[Decl] = @[]
  var assocTypes: seq[tuple[name: string, typ: TypeExpr]] = @[]
  while not p.check(tkRBrace) and not p.isAtEnd:
    # Skip newlines
    while p.check(tkNewLine):
      discard p.advance()
    if p.check(tkRBrace) or p.isAtEnd:
      break
    if p.check(tkType):
      discard p.advance()
      let assocName = p.expect(tkIdent, "expected associated type name").text
      discard p.expect(tkAssign, "expected '=' in associated type implementation")
      let assocType = p.parseType()
      if p.check(tkSemicolon):
        discard p.advance()
      assocTypes.add((assocName, assocType))
    else:
      methods.add(p.parseFuncDecl(false, false, ParsedAttrs()))
  discard p.expect(tkRBrace, "expected '}' to close impl block")
  return Decl(kind: dkImpl, loc: loc, declImplTypeName: typeName,
              declImplTypeParams: typeParams,
              declImplInterface: interfaceName,
              declImplAssocTypes: assocTypes,
              declImplMethods: methods)

proc parseModuleDecl(p: var Parser, isPublic: bool): Decl =
  let loc = p.currentLoc
  discard p.expect(tkModule, "expected 'module'")
  var path: seq[string] = @[]
  path.add(p.expect(tkIdent, "expected module name").text)
  while p.check(tkColonColon):
    discard p.advance()
    path.add(p.expect(tkIdent, "expected module path segment").text)
  let name = path[^1]
  discard p.expect(tkLBrace, "expected '{' to start module body")
  var items: seq[Decl] = @[]
  while not p.check(tkRBrace) and not p.isAtEnd:
    while p.check(tkNewLine):
      discard p.advance()
    if p.check(tkRBrace) or p.isAtEnd:
      break
    items.add(p.parseDecl())
  discard p.expect(tkRBrace, "expected '}' to close module")
  return Decl(kind: dkModule, loc: loc, isPublic: isPublic,
              declModuleName: name, declModulePath: path,
              declModuleItems: items)

proc parseUseDecl(p: var Parser, attrs: ParsedAttrs): Decl =
  let loc = p.currentLoc
  discard p.expect(tkImport, "expected 'import'")
  var path: seq[string] = @[]
  path.add(p.expect(tkIdent, "expected import path segment").text)
  while p.check(tkColonColon):
    # Lookahead: if :: is followed by { or *, don't consume it here
    if p.peek(1) == tkLBrace or p.peek(1) == tkStar:
      break
    discard p.advance()
    path.add(p.expect(tkIdent, "expected import path segment").text)
  var kind = ukSingle
  var names: seq[string] = @[]
  if p.check(tkDotDotDot):
    discard p.advance()
    kind = ukGlob
  elif p.check(tkDot):
    discard p.advance()
    discard p.expect(tkStar, "expected '*'")
    kind = ukGlob
  elif p.check(tkColonColon):
    discard p.advance()
    if p.check(tkLBrace):
      discard p.advance()
      while not p.check(tkRBrace) and not p.isAtEnd:
        while p.check(tkNewLine):
          discard p.advance()
        if p.check(tkRBrace) or p.isAtEnd:
          break
        names.add(p.expect(tkIdent, "expected name in multi-import").text)
        if p.check(tkComma):
          discard p.advance()
      discard p.expect(tkRBrace, "expected '}' to close multi-import")
      kind = ukMulti
    elif p.check(tkStar):
      discard p.advance()
      kind = ukGlob
  if p.check(tkSemicolon):
    discard p.advance()
  return Decl(kind: dkUse, loc: loc, declUsePath: path, declUseKind: kind,
              declUseNames: names, declUseTargetOs: attrs.targetOs)

proc parseConstDecl(p: var Parser, isPublic: bool): Decl =
  let loc = p.currentLoc
  discard p.expect(tkConst, "expected 'const'")
  let name = p.expect(tkIdent, "expected constant name").text
  var ty: TypeExpr = nil
  if p.check(tkColon):
    discard p.advance()
    ty = p.parseType()
  discard p.expect(tkAssign, "expected '=' in const declaration")
  let value = p.parseExpr()
  if p.check(tkSemicolon):
    discard p.advance()
  return Decl(kind: dkConst, loc: loc, isPublic: isPublic,
              declConstName: name, declConstType: ty, declConstValue: value)

proc parseTypeAliasDecl(p: var Parser, isPublic: bool): Decl =
  let loc = p.currentLoc
  discard p.expect(tkType, "expected 'type'")
  let name = p.expect(tkIdent, "expected type alias name").text
  discard p.expect(tkAssign, "expected '=' in type alias")
  let ty = p.parseType()
  if p.check(tkSemicolon):
    discard p.advance()
  return Decl(kind: dkTypeAlias, loc: loc, isPublic: isPublic,
              declAliasName: name, declAliasType: ty)

proc parseExternDecl(p: var Parser, isPublic: bool, attrs: ParsedAttrs): Decl =
  let loc = p.currentLoc
  discard p.expect(tkExtern, "expected 'extern'")
  if p.check(tkFunc):
    let funcDecl = p.parseFuncDecl(isPublic, false, attrs)
    # Convert dkFunc to dkExternFunc
    return Decl(kind: dkExternFunc, loc: funcDecl.loc, isPublic: isPublic,
                declExtFuncName: funcDecl.declFuncName,
                declExtFuncDll: attrs.importLib,
                declExtFuncCallConv: attrs.callConv,
                declExtFuncParams: funcDecl.declFuncParams,
                declExtFuncVariadic: false,
                declExtFuncReturnType: funcDecl.declFuncReturnType)
  elif p.check(tkLBrace):
    discard p.advance()
    var items: seq[Decl] = @[]
    while not p.check(tkRBrace) and not p.isAtEnd:
      if p.check(tkFunc):
        items.add(p.parseFuncDecl(isPublic, false, attrs))
      elif p.check(tkIdent):
        let vName = p.advance().text
        discard p.expect(tkColon, "expected ':'")
        let vType = p.parseType()
        if p.check(tkSemicolon):
          discard p.advance()
        items.add(Decl(kind: dkExternVar, loc: loc, isPublic: isPublic,
                       declExtVarName: vName, declExtVarType: vType))
      else:
        p.emitError("expected function or variable in extern block")
        discard p.advance()
    discard p.expect(tkRBrace, "expected '}' to close extern block")
    return Decl(kind: dkExternBlock, loc: loc, declExtBlockDll: attrs.importLib,
                declExtBlockCallConv: attrs.callConv, declExtBlockItems: items)
  else:
    # Single extern variable
    let vName = p.expect(tkIdent, "expected variable name").text
    discard p.expect(tkColon, "expected ':'")
    let vType = p.parseType()
    if p.check(tkSemicolon):
      discard p.advance()
    return Decl(kind: dkExternVar, loc: loc, isPublic: isPublic,
                declExtVarName: vName, declExtVarType: vType)

proc parseDecl(p: var Parser): Decl =
  let loc = p.currentLoc
  var isPublic = false
  if p.check(tkPub):
    isPublic = true
    discard p.advance()
  
  var attrs = ParsedAttrs()
  if p.check(tkAt):
    attrs = p.parseAttrs()
  p.skipNewlines()
  
  var isConst = false
  if p.check(tkConst) and p.peek(1) == tkFunc:
    isConst = true
    discard p.advance()

  var isAsync = false
  if p.check(tkAsync) and p.peek(1) == tkFunc:
    isAsync = true
    discard p.advance()
  
  case p.peek()
  of tkFunc:
    return p.parseFuncDecl(isPublic, false, attrs, isConst, isAsync)
  of tkStruct:
    return p.parseStructDecl(isPublic)
  of tkEnum:
    return p.parseEnumDecl(isPublic)
  of tkUnion:
    return p.parseUnionDecl(isPublic)
  of tkInterface:
    return p.parseInterfaceDecl(isPublic)
  of tkExtend:
    return p.parseImplDecl()
  of tkModule:
    return p.parseModuleDecl(isPublic)
  of tkImport:
    return p.parseUseDecl(attrs)
  of tkConst:
    return p.parseConstDecl(isPublic)
  of tkType:
    return p.parseTypeAliasDecl(isPublic)
  of tkExtern:
    return p.parseExternDecl(isPublic, attrs)
  else:
    p.emitError(loc, "expected declaration")
    p.synchronize()
    return Decl(kind: dkFunc, loc: loc, declFuncName: "")

# ---------------------------------------------------------------------------
# Module (top-level)
# ---------------------------------------------------------------------------

proc parseModule*(p: var Parser, name: string): ParseResult =
  var modu = newModule(name)
  while not p.isAtEnd:
    if p.check(tkNewLine):
      discard p.advance()
      continue
    modu.items.add(p.parseDecl())
  result = ParseResult(module: modu, diagnostics: p.diagnostics)

proc parse*(tokens: seq[Token], sourceName: string = "<input>"): ParseResult =
  var p = initParser(tokens, sourceName)
  result = p.parseModule(sourceName)
