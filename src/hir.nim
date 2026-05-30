import ast, types, token, source_location

type
  HirKind* = enum
    # Literals
    hLit
    hVar
    hSelf
    # Operations
    hUnary
    hBinary
    hAssign
    # Control flow
    hIf
    hWhile
    hLoop
    hBreak
    hContinue
    hReturn
    # Memory
    hAlloca
    hLoad
    hStore
    hFieldPtr
    hArrowField
    hIndexPtr
    # Functions
    hCall
    hCallIndirect
    # Type operations
    hCast
    hIs
    # Composite
    hBlock
    hStructInit
    hSliceInit
    hTupleInit
    # Match (desugared to switch/branch later)
    hMatch

  HirNode* = ref object
    loc*: SourceLocation
    typ*: Type
    case kind*: HirKind
    of hLit:
      litToken*: Token
    of hVar:
      varName*: string
    of hSelf:
      discard
    of hUnary:
      unaryOp*: TokenKind
      unaryOperand*: HirNode
    of hBinary:
      binaryOp*: TokenKind
      binaryLeft*: HirNode
      binaryRight*: HirNode
    of hAssign:
      assignOp*: TokenKind
      assignTarget*: HirNode
      assignValue*: HirNode
    of hIf:
      ifCond*: HirNode
      ifThen*: HirNode
      ifElse*: HirNode
    of hWhile:
      whileCond*: HirNode
      whileBody*: HirNode
    of hLoop:
      loopBody*: HirNode
    of hBreak:
      breakLabel*: string
    of hContinue:
      continueLabel*: string
    of hReturn:
      returnValue*: HirNode
    of hAlloca:
      allocaType*: Type
      allocaName*: string
    of hLoad:
      loadPtr*: HirNode
    of hStore:
      storePtr*: HirNode
      storeValue*: HirNode
    of hFieldPtr:
      fieldPtrBase*: HirNode
      fieldName*: string
    of hArrowField:
      arrowFieldBase*: HirNode
      arrowFieldName*: string
    of hIndexPtr:
      indexPtrBase*: HirNode
      indexPtrIndex*: HirNode
    of hCall:
      callCallee*: string
      callArgs*: seq[HirNode]
    of hCallIndirect:
      callIndirectCallee*: HirNode
      callIndirectArgs*: seq[HirNode]
    of hCast:
      castOperand*: HirNode
      castType*: Type
    of hIs:
      isOperand*: HirNode
      isType*: Type
    of hBlock:
      blockStmts*: seq[HirNode]
      blockExpr*: HirNode
    of hStructInit:
      structInitName*: string
      structInitFields*: seq[tuple[name: string, value: HirNode]]
    of hSliceInit:
      sliceInitElements*: seq[HirNode]
    of hTupleInit:
      tupleInitElements*: seq[HirNode]
    of hMatch:
      matchSubject*: HirNode
      matchArms*: seq[HirMatchArm]

  HirMatchArm* = object
    pattern*: Pattern
    body*: HirNode

  HirFunc* = object
    name*: string
    params*: seq[tuple[name: string, typ: Type]]
    retType*: Type
    body*: HirNode
    isPublic*: bool

  HirEnumVariant* = object
    name*: string
    fields*: seq[Type]  # Positional fields for algebraic enums
    namedFields*: seq[tuple[name: string, typ: Type]]  # Named fields

  HirModule* = object
    funcs*: seq[HirFunc]
    externFuncs*: seq[HirFunc]  # Functions declared with extern (no body)
    structs*: seq[tuple[name: string, fields: seq[tuple[name: string, typ: Type]]]]
    enums*: seq[tuple[name: string, variants: seq[HirEnumVariant]]]
    consts*: seq[tuple[name: string, typ: Type, value: HirNode]]

# Constructor helpers
proc hirLit*(tok: Token, typ: Type, loc: SourceLocation): HirNode =
  HirNode(kind: hLit, litToken: tok, typ: typ, loc: loc)

proc hirVar*(name: string, typ: Type, loc: SourceLocation): HirNode =
  HirNode(kind: hVar, varName: name, typ: typ, loc: loc)

proc hirSelf*(typ: Type, loc: SourceLocation): HirNode =
  HirNode(kind: hSelf, typ: typ, loc: loc)

proc hirUnary*(op: TokenKind, operand: HirNode, typ: Type, loc: SourceLocation): HirNode =
  HirNode(kind: hUnary, unaryOp: op, unaryOperand: operand, typ: typ, loc: loc)

proc hirBinary*(op: TokenKind, left, right: HirNode, typ: Type, loc: SourceLocation): HirNode =
  HirNode(kind: hBinary, binaryOp: op, binaryLeft: left, binaryRight: right, typ: typ, loc: loc)

proc hirCall*(callee: string, args: seq[HirNode], typ: Type, loc: SourceLocation): HirNode =
  HirNode(kind: hCall, callCallee: callee, callArgs: args, typ: typ, loc: loc)

proc hirReturn*(value: HirNode, loc: SourceLocation): HirNode =
  HirNode(kind: hReturn, returnValue: value, typ: makeVoid(), loc: loc)

proc hirBlock*(stmts: seq[HirNode], expr: HirNode, typ: Type, loc: SourceLocation): HirNode =
  HirNode(kind: hBlock, blockStmts: stmts, blockExpr: expr, typ: typ, loc: loc)

proc hirAlloca*(name: string, typ: Type, loc: SourceLocation): HirNode =
  HirNode(kind: hAlloca, allocaType: typ, allocaName: name, typ: makePointer(typ), loc: loc)

proc hirStore*(ptrNode, value: HirNode, loc: SourceLocation): HirNode =
  HirNode(kind: hStore, storePtr: ptrNode, storeValue: value, typ: makeVoid(), loc: loc)

proc hirLoad*(ptrNode: HirNode, typ: Type, loc: SourceLocation): HirNode =
  HirNode(kind: hLoad, loadPtr: ptrNode, typ: typ, loc: loc)
