import source_location, token

type
  CallingConvention* = enum
    ccDefault
    ccWin64

  IntrinsicKind* = enum
    ikLine
    ikColumn
    ikFile
    ikFunction
    ikDate
    ikTime
    ikModule

  UseKind* = enum
    ukSingle
    ukGlob
    ukMulti

  # ---------------------------------------------------------------------------
  # Type expressions
  # ---------------------------------------------------------------------------
  TypeExprKind* = enum
    tekNamed
    tekPath
    tekSlice
    tekPointer
    tekOwn       ## own T — owned value (gradual ownership)
    tekRef       ## &T — shared reference (gradual ownership)
    tekMutRef    ## &mut T — mutable reference
    tekDynRef    ## &dyn Trait — trait object (fat pointer)
    tekTuple
    tekSelf

  TypeExpr* = ref object
    loc*: SourceLocation
    case kind*: TypeExprKind
    of tekNamed:
      typeName*: string
      typeArgs*: seq[TypeExpr]
    of tekPath:
      pathSegments*: seq[string]
    of tekSlice:
      sliceElement*: TypeExpr
      sliceSize*: Expr          ## nil for unsized slices T[]
    of tekOwn, tekPointer, tekRef, tekMutRef:
      pointerPointee*: TypeExpr
      refLifetime*: string  ## only meaningful for tekRef/tekMutRef
    of tekDynRef:
      dynInterface*: string
    of tekTuple:
      tupleElements*: seq[TypeExpr]
    of tekSelf:
      discard

  # ---------------------------------------------------------------------------
  # Patterns
  # ---------------------------------------------------------------------------
  PatternKind* = enum
    pkWildcard
    pkLiteral
    pkIdent
    pkRange
    pkEnum
    pkStruct
    pkTuple
    pkGuarded

  Pattern* = ref object
    loc*: SourceLocation
    case kind*: PatternKind
    of pkWildcard:
      discard
    of pkLiteral:
      patLit*: Token
    of pkIdent:
      patIdent*: string
    of pkRange:
      patRangeLo*: Pattern
      patRangeHi*: Pattern
      patRangeInclusive*: bool
    of pkEnum:
      patEnumPath*: seq[string]
      patEnumArgs*: seq[Pattern]
      patEnumNamed*: seq[tuple[name: string, pattern: Pattern]]
    of pkStruct:
      patStructName*: string
      patStructFields*: seq[tuple[name: string, pattern: Pattern]]
    of pkTuple:
      patTupleElements*: seq[Pattern]
    of pkGuarded:
      patGuardedInner*: Pattern
      patGuardedExpr*: Expr

  # ---------------------------------------------------------------------------
  # Expressions
  # ---------------------------------------------------------------------------
  ExprKind* = enum
    ekLiteral
    ekIdent
    ekSelf
    ekPath
    ekSizeOf
    ekIntrinsic
    ekUnary
    ekPostfix
    ekBinary
    ekAssign
    ekTernary
    ekRange
    ekCall
    ekGenericCall
    ekIndex
    ekField
    ekStructInit
    ekSlice
    ekSpread
    ekTuple
    ekCast
    ekIs
    ekTry
    ekUnwrap        ## expr! — unwrap or panic
    ekSpawn         ## spawn expr — create a new task
    ekAwait         ## expr.await — suspend until future resolves
    ekBorrow        ## borrow &mut expr — explicit borrow expression
    ekBlock
    ekMatch
    ekStringInterp

  MatchArm* = object
    loc*: SourceLocation
    pattern*: Pattern
    body*: Expr

  Expr* = ref object
    loc*: SourceLocation
    case kind*: ExprKind
    of ekLiteral:
      exprLit*: Token
    of ekIdent:
      exprIdent*: string
    of ekSelf:
      discard
    of ekPath:
      exprPath*: seq[string]
    of ekSizeOf:
      exprSizeOfType*: TypeExpr
    of ekIntrinsic:
      exprIntrinsic*: IntrinsicKind
    of ekUnary:
      exprUnaryOp*: TokenKind
      exprUnaryOperand*: Expr
    of ekPostfix:
      exprPostfixOp*: TokenKind
      exprPostfixOperand*: Expr
    of ekBinary:
      exprBinaryOp*: TokenKind
      exprBinaryLeft*: Expr
      exprBinaryRight*: Expr
    of ekAssign:
      exprAssignOp*: TokenKind
      exprAssignTarget*: Expr
      exprAssignValue*: Expr
    of ekTernary:
      exprTernaryCond*: Expr
      exprTernaryThen*: Expr
      exprTernaryElse*: Expr
    of ekRange:
      exprRangeLo*: Expr
      exprRangeHi*: Expr
      exprRangeInclusive*: bool
    of ekCall:
      exprCallCallee*: Expr
      exprCallArgs*: seq[Expr]
      exprCallInferredTypeArgs*: seq[TypeExpr]  ## filled by sema for inferred generic calls
    of ekGenericCall:
      exprGenericCallee*: string
      exprGenericTypeArgs*: seq[TypeExpr]
    of ekIndex:
      exprIndexObj*: Expr
      exprIndexIdx*: Expr
      exprIndexBoundsCheck*: bool
    of ekField:
      exprFieldObj*: Expr
      exprFieldName*: string
    of ekStructInit:
      exprStructInitName*: string
      exprStructInitTypeArgs*: seq[TypeExpr]
      exprStructInitFields*: seq[tuple[name: string, value: Expr]]
    of ekSlice:
      exprSliceElements*: seq[Expr]
    of ekSpread:
      exprSpreadOperand*: Expr
    of ekTuple:
      exprTupleElements*: seq[Expr]
    of ekCast:
      exprCastOperand*: Expr
      exprCastType*: TypeExpr
    of ekIs:
      exprIsOperand*: Expr
      exprIsType*: TypeExpr
    of ekTry:
      exprTryOperand*: Expr
      exprTryType*: TypeExpr  # nil for Result?, or explicit target type
    of ekUnwrap:
      exprUnwrapOperand*: Expr
    of ekSpawn:
      exprSpawnCallee*: Expr
      exprSpawnArgs*: seq[Expr]
      exprSpawnAsync*: bool
    of ekAwait:
      exprAwaitOperand*: Expr
    of ekBorrow:
      exprBorrowOperand*: Expr
      exprBorrowMutable*: bool
    of ekBlock:
      exprBlock*: Block
    of ekMatch:
      exprMatchSubject*: Expr
      exprMatchArms*: seq[MatchArm]
    of ekStringInterp:
      exprInterpTexts*: seq[string]
      exprInterpExprs*: seq[Expr]

  # ---------------------------------------------------------------------------
  # Statements
  # ---------------------------------------------------------------------------
  StmtKind* = enum
    skExpr
    skLet
    skIf
    skWhile
    skDoWhile
    skLoop
    skFor
    skMatch
    skReturn
    skBreak
    skContinue
    skStaticAssert
    skComptime
    skEmit
    skDefer
    skSwitch
    skDecl

  ElseIf* = object
    loc*: SourceLocation
    cond*: Expr
    blk*: Block

  SwitchCase* = object
    loc*: SourceLocation
    caseValue*: Expr
    caseBody*: Block

  Block* = ref object
    loc*: SourceLocation
    stmts*: seq[Stmt]

  Stmt* = ref object
    loc*: SourceLocation
    case kind*: StmtKind
    of skExpr:
      stmtExpr*: Expr
    of skLet:
      stmtLetMut*: bool
      stmtLetName*: string
      stmtLetPattern*: Pattern
      stmtLetType*: TypeExpr      ## nil if inferred
      stmtLetInit*: Expr
    of skIf:
      stmtIfCond*: Expr
      stmtIfThen*: Block
      stmtIfElseIfs*: seq[ElseIf]
      stmtIfElse*: Block          ## nil if no else
    of skWhile:
      stmtWhileLabel*: string
      stmtWhileCond*: Expr
      stmtWhileBody*: Block
    of skDoWhile:
      stmtDoWhileLabel*: string
      stmtDoWhileBody*: Block
      stmtDoWhileCond*: Expr
    of skLoop:
      stmtLoopLabel*: string
      stmtLoopBody*: Block
    of skFor:
      stmtForLabel*: string
      stmtForVar*: string
      stmtForIter*: Expr
      stmtForBody*: Block
    of skMatch:
      stmtMatchSubject*: Expr
      stmtMatchArms*: seq[MatchArm]
    of skReturn:
      stmtReturnValue*: Expr      ## nil for bare return
    of skBreak:
      stmtBreakLabel*: string
    of skContinue:
      stmtContinueLabel*: string
    of skStaticAssert:
      stmtStaticAssertCond*: Expr
      stmtStaticAssertMsg*: Expr
    of skComptime:
      stmtComptimeBlock*: Block
    of skEmit:
      stmtEmitExpr*: Expr
      stmtEmitEvaluated*: string  ## filled by sema CTFE
    of skDefer:
      stmtDeferBody*: Expr
    of skSwitch:
      stmtSwitchExpr*: Expr
      stmtSwitchCases*: seq[SwitchCase]
      stmtSwitchDefault*: Block
    of skDecl:
      stmtDecl*: Decl

  # ---------------------------------------------------------------------------
  # Type Parameters (for generics with trait bounds)
  # ---------------------------------------------------------------------------
  TypeParam* = object
    name*: string
    bounds*: seq[string]   ## e.g. ["Comparable"] for <T: Comparable>
    isLifetime*: bool      ## true for lifetime params like 'a

  # ---------------------------------------------------------------------------
  # Declarations
  # ---------------------------------------------------------------------------
  DeclKind* = enum
    dkFunc
    dkStruct
    dkEnum
    dkUnion
    dkInterface
    dkImpl
    dkModule
    dkUse
    dkConst
    dkTypeAlias
    dkExternFunc
    dkExternVar
    dkExternBlock

  Param* = object
    loc*: SourceLocation
    name*: string
    ptype*: TypeExpr
    isVariadic*: bool
    defaultValue*: Expr

  StructField* = object
    loc*: SourceLocation
    isPublic*: bool
    name*: string
    ftype*: TypeExpr

  EnumVariant* = object
    loc*: SourceLocation
    name*: string
    fields*: seq[TypeExpr]
    namedFields*: seq[tuple[name: string, ftype: TypeExpr]]
    discriminant*: string

  UnionField* = object
    loc*: SourceLocation
    name*: string
    ftype*: TypeExpr

  Decl* = ref object
    loc*: SourceLocation
    isPublic*: bool
    declAttrs*: seq[string]   ## attributes: @[Checked], @[Inline], etc.
    case kind*: DeclKind
    of dkFunc:
      declFuncAsm*: bool
      declFuncCallConv*: CallingConvention
      declFuncConst*: bool          ## const func — evaluable at compile time
      declFuncIsAsync*: bool        ## async func — returns Future<T>
      declFuncName*: string
      declFuncTypeParams*: seq[TypeParam]
      declFuncParams*: seq[Param]
      declFuncReturnType*: TypeExpr  ## nil if void/inferred
      declFuncBody*: Block           ## nil for signature-only
    of dkStruct:
      declStructName*: string
      declStructTypeParams*: seq[TypeParam]
      declStructFields*: seq[StructField]
    of dkEnum:
      declEnumName*: string
      declEnumBaseType*: TypeExpr
      declEnumVariants*: seq[EnumVariant]
    of dkUnion:
      declUnionName*: string
      declUnionFields*: seq[UnionField]
    of dkInterface:
      declInterfaceName*: string
      declInterfaceAssocTypes*: seq[string]  ## associated type names: type Output;
      declInterfaceMethods*: seq[Decl]  ## FuncDecl signatures only
    of dkImpl:
      declImplTypeName*: string
      declImplTypeParams*: seq[TypeParam]  ## type parameters for generic impl: extend Box<T>
      declImplInterface*: string        ## empty if not for interface
      declImplAssocTypes*: seq[tuple[name: string, typ: TypeExpr]]  ## type Output = int;
      declImplMethods*: seq[Decl]
    of dkModule:
      declModuleName*: string
      declModulePath*: seq[string]
      declModuleItems*: seq[Decl]
    of dkUse:
      declUsePath*: seq[string]
      declUseKind*: UseKind
      declUseNames*: seq[string]       ## for multi-import
      declUseTargetOs*: string
    of dkConst:
      declConstName*: string
      declConstType*: TypeExpr
      declConstValue*: Expr
    of dkTypeAlias:
      declAliasName*: string
      declAliasType*: TypeExpr
    of dkExternFunc:
      declExtFuncName*: string
      declExtFuncDll*: string
      declExtFuncCallConv*: CallingConvention
      declExtFuncParams*: seq[Param]
      declExtFuncVariadic*: bool
      declExtFuncReturnType*: TypeExpr
    of dkExternVar:
      declExtVarName*: string
      declExtVarType*: TypeExpr
    of dkExternBlock:
      declExtBlockDll*: string
      declExtBlockCallConv*: CallingConvention
      declExtBlockItems*: seq[Decl]

  # ---------------------------------------------------------------------------
  # Module (AST root)
  # ---------------------------------------------------------------------------
  Module* = ref object
    name*: string
    path*: seq[string]
    items*: seq[Decl]

# Convenience constructors
proc newModule*(name: string, path: seq[string] = @[]): Module =
  result = Module(name: name, path: path)

proc newBlock*(loc: SourceLocation): Block =
  result = Block(loc: loc)

proc newLiteralExpr*(tok: Token): Expr =
  result = Expr(kind: ekLiteral, loc: tok.loc, exprLit: tok)

proc newIdentExpr*(name: string, loc: SourceLocation): Expr =
  result = Expr(kind: ekIdent, loc: loc, exprIdent: name)

proc newBinaryExpr*(op: TokenKind, left, right: Expr, loc: SourceLocation): Expr =
  result = Expr(kind: ekBinary, loc: loc, exprBinaryOp: op, exprBinaryLeft: left, exprBinaryRight: right)

proc newUnaryExpr*(op: TokenKind, operand: Expr, loc: SourceLocation): Expr =
  result = Expr(kind: ekUnary, loc: loc, exprUnaryOp: op, exprUnaryOperand: operand)

proc newStringInterpExpr*(texts: seq[string], exprs: seq[Expr], loc: SourceLocation): Expr =
  result = Expr(kind: ekStringInterp, loc: loc, exprInterpTexts: texts, exprInterpExprs: exprs)
