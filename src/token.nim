import source_location

type
  TokenKind* = enum
    ##Literals
    tkIntLiteral      # 42  0xFF  0b1010  0o77
    tkFloatLiteral    # 3.14  1.0e-9
    tkStringLiteral   # "hello"  c8"hello"  c16"hello"  c32"hello"
    tkCharLiteral     # 'A'  c8'A'  c16'A'  c32'A'
    tkBoolLiteral     # true  false

    ##Identifiers
    tkIdent           # foo  Bar  _x
    tkUnderscore      # _

    ##Control flow keywords
    tkIf              # if
    tkElse            # else
    tkWhile           # while
    tkDo              # do
    tkLoop            # loop
    tkFor             # for
    tkIn              # in
    tkBreak           # break
    tkContinue        # continue
    tkReturn          # return
    tkMatch           # match

    ##Declaration keywords
    tkFunc            # func
    tkLet             # let
    tkVar             # var
    tkConst           # const
    tkType            # type
    tkStruct          # struct
    tkEnum            # enum
    tkUnion           # union
    tkInterface       # interface
    tkExtend          # extend
    tkModule          # module
    tkImport          # import
    tkPub             # pub
    tkExtern          # extern

    ##Other keywords
    tkAs              # as
    tkIs              # is
    tkNull            # null
    tkSelf            # self
    tkSuper           # super
    tkSizeOf          # sizeof

    ##Punctuation
    tkLParen          # (
    tkRParen          # )
    tkLBrace          # {
    tkRBrace          # }
    tkLBracket        # [
    tkRBracket        # ]
    tkComma           # ,
    tkSemicolon       # ;
    tkColon           # :
    tkColonColon      # ::
    tkDot             # .
    tkDotDot          # ..
    tkDotDotDot       # ...
    tkDotDotEqual     # ..=
    tkArrow           # ->
    tkFatArrow        # =>
    tkAt              # @
    tkHash            # #
    tkQuestion        # ?

    ##Arithmetic operators
    tkPlus            # +
    tkMinus           # -
    tkStar            # *
    tkSlash           # /
    tkPercent         # %
    tkStarStar        # **
    tkPlusPlus        # ++
    tkMinusMinus      # --

    ##Bitwise operators
    tkAmp             # &
    tkPipe            # |
    tkCaret           # ^
    tkTilde           # ~
    tkShl             # <<
    tkShr             # >>

    ##Logical operators
    tkAmpAmp          # &&
    tkPipePipe        # ||
    tkBang            # !

    ##Comparison operators
    tkEq              # ==
    tkNe              # !=
    tkLt              # <
    tkLe              # <=
    tkGt              # >
    tkGe              # >=

    ##Assignment operators
    tkAssign          # =
    tkPlusAssign      # +=
    tkMinusAssign     # -=
    tkStarAssign      # *=
    tkSlashAssign     # /=
    tkPercentAssign   # %=
    tkAmpAssign       # &=
    tkPipeAssign      # |=
    tkCaretAssign     # ^=
    tkShlAssign       # <<=
    tkShrAssign       # >>=

    ##Compile-time intrinsics
    tkHashLine        # #line
    tkHashColumn      # #column
    tkHashFile        # #file
    tkHashFunction    # #function
    tkHashDate        # #date
    tkHashTime        # #time
    tkHashModule      # #module

    ##Special
    tkNewLine         # significant newline (if grammar uses them)
    tkEndOfFile       # end of file
    tkUnknown         # unrecognized character

  Token* = object
    kind*: TokenKind
    text*: string       # original source spelling
    loc*: SourceLocation

proc isKeyword*(kind: TokenKind): bool =
  case kind
  of tkIf, tkElse, tkWhile, tkDo, tkLoop, tkFor, tkIn,
     tkBreak, tkContinue, tkReturn, tkMatch,
     tkFunc, tkLet, tkVar, tkConst, tkType, tkStruct, tkEnum,
     tkUnion, tkInterface, tkExtend, tkModule, tkImport,
     tkPub, tkExtern, tkAs, tkIs, tkNull, tkSelf, tkSuper:
    true
  else:
    false

proc isLiteral*(kind: TokenKind): bool =
  case kind
  of tkIntLiteral, tkFloatLiteral, tkStringLiteral, tkCharLiteral, tkBoolLiteral:
    true
  else:
    false

proc isOperator*(kind: TokenKind): bool =
  case kind
  of tkPlus..tkShrAssign:
    true
  else:
    false

proc isEof*(kind: TokenKind): bool = kind == tkEndOfFile

proc keywordKind*(text: string): TokenKind =
  case text
  of "func": tkFunc
  of "let": tkLet
  of "var": tkVar
  of "const": tkConst
  of "type": tkType
  of "struct": tkStruct
  of "enum": tkEnum
  of "union": tkUnion
  of "interface": tkInterface
  of "extend": tkExtend
  of "module": tkModule
  of "import": tkImport
  of "pub": tkPub
  of "extern": tkExtern
  of "if": tkIf
  of "else": tkElse
  of "while": tkWhile
  of "do": tkDo
  of "loop": tkLoop
  of "for": tkFor
  of "in": tkIn
  of "break": tkBreak
  of "continue": tkContinue
  of "return": tkReturn
  of "match": tkMatch
  of "as": tkAs
  of "is": tkIs
  of "null": tkNull
  of "self": tkSelf
  of "super": tkSuper
  of "sizeof": tkSizeOf
  of "true", "false": tkBoolLiteral
  else: tkIdent

proc tokenKindName*(kind: TokenKind): string =
  case kind
  of tkIntLiteral: "integer literal"
  of tkFloatLiteral: "float literal"
  of tkStringLiteral: "string literal"
  of tkCharLiteral: "char literal"
  of tkBoolLiteral: "boolean literal"
  of tkIdent: "identifier"
  of tkUnderscore: "'_'"
  of tkSizeOf: "'sizeof'"
  of tkIf: "'if'"
  of tkElse: "'else'"
  of tkWhile: "'while'"
  of tkDo: "'do'"
  of tkLoop: "'loop'"
  of tkFor: "'for'"
  of tkIn: "'in'"
  of tkBreak: "'break'"
  of tkContinue: "'continue'"
  of tkReturn: "'return'"
  of tkMatch: "'match'"
  of tkFunc: "'func'"
  of tkLet: "'let'"
  of tkVar: "'var'"
  of tkConst: "'const'"
  of tkType: "'type'"
  of tkStruct: "'struct'"
  of tkEnum: "'enum'"
  of tkUnion: "'union'"
  of tkInterface: "'interface'"
  of tkExtend: "'extend'"
  of tkModule: "'module'"
  of tkImport: "'import'"
  of tkPub: "'pub'"
  of tkExtern: "'extern'"
  of tkAs: "'as'"
  of tkIs: "'is'"
  of tkNull: "'null'"
  of tkSelf: "'self'"
  of tkSuper: "'super'"
  of tkLParen: "'('"
  of tkRParen: "')'"
  of tkLBrace: "'{'"
  of tkRBrace: "'}'"
  of tkLBracket: "'['"
  of tkRBracket: "']'"
  of tkComma: "','"
  of tkSemicolon: "';'"
  of tkColon: "':'"
  of tkColonColon: "'::'"
  of tkDot: "'.'"
  of tkDotDot: "'..'"
  of tkDotDotDot: "'...'"
  of tkDotDotEqual: "'..='"
  of tkArrow: "'->'"
  of tkFatArrow: "'=>'"
  of tkAt: "'@'"
  of tkHash: "'#'"
  of tkQuestion: "'?'"
  of tkPlus: "'+'"
  of tkMinus: "'-'"
  of tkStar: "'*'"
  of tkSlash: "'/'"
  of tkPercent: "'%'"
  of tkStarStar: "'**'"
  of tkPlusPlus: "'++'"
  of tkMinusMinus: "'--'"
  of tkAmp: "'&'"
  of tkPipe: "'|'"
  of tkCaret: "'^'"
  of tkTilde: "'~'"
  of tkShl: "'<<'"
  of tkShr: "'>>'"
  of tkAmpAmp: "'&&'"
  of tkPipePipe: "'||'"
  of tkBang: "'!'"
  of tkEq: "'=='"
  of tkNe: "'!='"
  of tkLt: "'<'"
  of tkLe: "'<='"
  of tkGt: "'>'"
  of tkGe: "'>='"
  of tkAssign: "'='"
  of tkPlusAssign: "'+='"
  of tkMinusAssign: "'-='"
  of tkStarAssign: "'*='"
  of tkSlashAssign: "'/='"
  of tkPercentAssign: "'%='"
  of tkAmpAssign: "'&='"
  of tkPipeAssign: "'|='"
  of tkCaretAssign: "'^='"
  of tkShlAssign: "'<<='"
  of tkShrAssign: "'>>='"
  of tkHashLine: "'#line'"
  of tkHashColumn: "'#column'"
  of tkHashFile: "'#file'"
  of tkHashFunction: "'#function'"
  of tkHashDate: "'#date'"
  of tkHashTime: "'#time'"
  of tkHashModule: "'#module'"
  of tkNewLine: "newline"
  of tkEndOfFile: "end of file"
  of tkUnknown: "unknown token"

proc `$`*(tok: Token): string =
  result = tokenKindName(tok.kind) & " '" & tok.text & "' @ " & $tok.loc
