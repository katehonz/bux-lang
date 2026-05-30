import std/[tables, strformat, strutils]
import ast, types, token, source_location, hir, sema, scope

type
  LowerCtx* = object
    module*: Module
    globalScope*: Scope
    methodTable*: Table[string, seq[MethodInfo]]
    currentFuncRetType*: Type
    varCounter*: int

proc freshName(ctx: var LowerCtx): string =
  inc ctx.varCounter
  result = "__tmp_" & $ctx.varCounter

proc initLowerCtx*(module: Module, sema: Sema): LowerCtx =
  result.module = module
  result.globalScope = sema.globalScope
  result.methodTable = sema.methodTable
  result.varCounter = 0

# Forward declarations
proc lowerExpr(ctx: var LowerCtx, expr: Expr): HirNode
proc lowerStmt(ctx: var LowerCtx, stmt: Stmt): HirNode
proc lowerBlock(ctx: var LowerCtx, blk: Block): HirNode

proc resolveExprType(ctx: var LowerCtx, expr: Expr): Type =
  if expr == nil: return makeUnknown()
  case expr.kind
  of ekLiteral:
    case expr.exprLit.kind
    of tkIntLiteral: return makeInt()
    of tkFloatLiteral: return makeFloat64()
    of tkStringLiteral: return makeStr()
    of tkCharLiteral: return makeChar8()
    of tkBoolLiteral: return makeBool()
    else: return makeUnknown()
  of ekIdent:
    let sym = ctx.globalScope.lookup(expr.exprIdent)
    if sym != nil and sym.typ != nil: return sym.typ
    return makeUnknown()
  of ekSelf: return makeNamed("self")
  of ekBinary:
    let left = ctx.resolveExprType(expr.exprBinaryLeft)
    case expr.exprBinaryOp
    of tkEq, tkNe, tkLt, tkLe, tkGt, tkGe, tkAmpAmp, tkPipePipe:
      return makeBool()
    else: return left
  of ekUnary:
    case expr.exprUnaryOp
    of tkBang: return makeBool()
    of tkAmp: return makePointer(ctx.resolveExprType(expr.exprUnaryOperand))
    of tkStar:
      let inner = ctx.resolveExprType(expr.exprUnaryOperand)
      if inner.isPointer: return inner.inner[0]
      return makeUnknown()
    else: return ctx.resolveExprType(expr.exprUnaryOperand)
  of ekCall:
    if expr.exprCallCallee.kind == ekIdent:
      let sym = ctx.globalScope.lookup(expr.exprCallCallee.exprIdent)
      if sym != nil and sym.typ != nil and sym.typ.kind == tkFunc:
        return sym.typ.inner[^1]
    if expr.exprCallCallee.kind == ekField:
      let recvType = ctx.resolveExprType(expr.exprCallCallee.exprFieldObj)
      let methodName = expr.exprCallCallee.exprFieldName
      var typeName = ""
      if recvType.kind == tkNamed: typeName = recvType.name
      elif recvType.isPointer and recvType.inner.len > 0 and recvType.inner[0].kind == tkNamed:
        typeName = recvType.inner[0].name
      if typeName != "" and ctx.methodTable.hasKey(typeName):
        for minfo in ctx.methodTable[typeName]:
          if minfo.name == methodName:
            return minfo.retType
    return makeUnknown()
  of ekField:
    let objType = ctx.resolveExprType(expr.exprFieldObj)
    if objType.kind == tkNamed:
      let sym = ctx.globalScope.lookup(objType.name)
      if sym != nil and sym.decl != nil and sym.decl.kind == dkStruct:
        for f in sym.decl.declStructFields:
          if f.name == expr.exprFieldName:
            if f.ftype != nil:
              case f.ftype.kind
              of tekNamed:
                case f.ftype.typeName
                of "int", "int32", "int64": return makeInt()
                of "float64": return makeFloat64()
                of "float32": return makeFloat32()
                of "bool": return makeBool()
                else: return makeNamed(f.ftype.typeName)
              of tekPointer: return makePointer(makeUnknown())
              else: return makeUnknown()
    return makeUnknown()
  of ekStructInit: return makeNamed(expr.exprStructInitName)
  of ekSlice:
    if expr.exprSliceElements.len > 0:
      return makeSlice(ctx.resolveExprType(expr.exprSliceElements[0]))
    return makeSlice(makeUnknown())
  of ekTuple:
    var elems: seq[Type] = @[]
    for e in expr.exprTupleElements:
      elems.add(ctx.resolveExprType(e))
    return makeTuple(elems)
  of ekCast:
    if expr.exprCastType != nil:
      case expr.exprCastType.kind
      of tekNamed: return makeNamed(expr.exprCastType.typeName)
      else: return makeUnknown()
    return makeUnknown()
  of ekBlock:
    if expr.exprBlock.stmts.len > 0:
      let last = expr.exprBlock.stmts[^1]
      if last.kind == skExpr:
        return ctx.resolveExprType(last.stmtExpr)
    return makeVoid()
  else: return makeUnknown()

proc lowerExpr(ctx: var LowerCtx, expr: Expr): HirNode =
  if expr == nil: return nil
  let loc = expr.loc
  let typ = ctx.resolveExprType(expr)

  case expr.kind
  of ekLiteral:
    return hirLit(expr.exprLit, typ, loc)

  of ekIdent:
    return hirVar(expr.exprIdent, typ, loc)

  of ekPath:
    # Handle enum variants: Color::Red → Color_Red
    # or module paths: Std::Io::PrintLine → Std_Io_PrintLine
    let mangledName = expr.exprPath.join("_")
    return hirVar(mangledName, typ, loc)

  of ekSelf:
    return hirSelf(typ, loc)

  of ekUnary:
    let operand = ctx.lowerExpr(expr.exprUnaryOperand)
    return hirUnary(expr.exprUnaryOp, operand, typ, loc)

  of ekBinary:
    let left = ctx.lowerExpr(expr.exprBinaryLeft)
    let right = ctx.lowerExpr(expr.exprBinaryRight)
    return hirBinary(expr.exprBinaryOp, left, right, typ, loc)

  of ekCall:
    # Method call desugaring: obj.method(args) → Type_method(obj, args)
    if expr.exprCallCallee.kind == ekField:
      let methodName = expr.exprCallCallee.exprFieldName
      
      # Try to find the method in methodTable
      for typeName, methods in ctx.methodTable:
        for minfo in methods:
          if minfo.name == methodName:
            # Found the method - desugar to Type_method(receiver, args)
            let mangledName = typeName & "_" & methodName
            var args: seq[HirNode] = @[]
            args.add(ctx.lowerExpr(expr.exprCallCallee.exprFieldObj))
            for arg in expr.exprCallArgs:
              args.add(ctx.lowerExpr(arg))
            return hirCall(mangledName, args, typ, loc)
      
      # Not a method call - treat as field access + call (function pointer)
      let callee = ctx.lowerExpr(expr.exprCallCallee)
      var args: seq[HirNode] = @[]
      for arg in expr.exprCallArgs:
        args.add(ctx.lowerExpr(arg))
      return HirNode(kind: hCallIndirect, callIndirectCallee: callee,
                     callIndirectArgs: args, typ: typ, loc: loc)

    # Regular function call
    var calleeName = ""
    if expr.exprCallCallee.kind == ekIdent:
      calleeName = expr.exprCallCallee.exprIdent
    elif expr.exprCallCallee.kind == ekPath:
      calleeName = expr.exprCallCallee.exprPath.join("::")
    var args: seq[HirNode] = @[]
    for arg in expr.exprCallArgs:
      args.add(ctx.lowerExpr(arg))
    if calleeName != "":
      return hirCall(calleeName, args, typ, loc)
    else:
      let callee = ctx.lowerExpr(expr.exprCallCallee)
      return HirNode(kind: hCallIndirect, callIndirectCallee: callee,
                     callIndirectArgs: args, typ: typ, loc: loc)

  of ekField:
    let base = ctx.lowerExpr(expr.exprFieldObj)
    let basePtr = HirNode(kind: hFieldPtr, fieldPtrBase: base,
                          fieldName: expr.exprFieldName,
                          typ: makePointer(typ), loc: loc)
    return HirNode(kind: hLoad, loadPtr: basePtr, typ: typ, loc: loc)

  of ekIndex:
    let base = ctx.lowerExpr(expr.exprIndexObj)
    let idx = ctx.lowerExpr(expr.exprIndexIdx)
    let basePtr = HirNode(kind: hIndexPtr, indexPtrBase: base,
                          indexPtrIndex: idx, typ: makePointer(typ), loc: loc)
    return HirNode(kind: hLoad, loadPtr: basePtr, typ: typ, loc: loc)

  of ekAssign:
    let target = ctx.lowerExpr(expr.exprAssignTarget)
    let value = ctx.lowerExpr(expr.exprAssignValue)
    return HirNode(kind: hAssign, assignOp: expr.exprAssignOp,
                   assignTarget: target, assignValue: value,
                   typ: makeVoid(), loc: loc)

  of ekStructInit:
    var fields: seq[tuple[name: string, value: HirNode]] = @[]
    for f in expr.exprStructInitFields:
      fields.add((f.name, ctx.lowerExpr(f.value)))
    return HirNode(kind: hStructInit, structInitName: expr.exprStructInitName,
                   structInitFields: fields, typ: typ, loc: loc)

  of ekSlice:
    var elems: seq[HirNode] = @[]
    for e in expr.exprSliceElements:
      elems.add(ctx.lowerExpr(e))
    return HirNode(kind: hSliceInit, sliceInitElements: elems, typ: typ, loc: loc)

  of ekTuple:
    var elems: seq[HirNode] = @[]
    for e in expr.exprTupleElements:
      elems.add(ctx.lowerExpr(e))
    return HirNode(kind: hTupleInit, tupleInitElements: elems, typ: typ, loc: loc)

  of ekCast:
    let operand = ctx.lowerExpr(expr.exprCastOperand)
    var castType = makeUnknown()
    if expr.exprCastType != nil:
      case expr.exprCastType.kind
      of tekNamed: castType = makeNamed(expr.exprCastType.typeName)
      of tekPointer: castType = makePointer(makeUnknown())
      else: discard
    return HirNode(kind: hCast, castOperand: operand, castType: castType,
                   typ: typ, loc: loc)

  of ekBlock:
    return ctx.lowerBlock(expr.exprBlock)

  of ekPostfix:
    let operand = ctx.lowerExpr(expr.exprPostfixOperand)
    return HirNode(kind: hUnary, unaryOp: expr.exprPostfixOp,
                   unaryOperand: operand, typ: typ, loc: loc)

  of ekTernary:
    let cond = ctx.lowerExpr(expr.exprTernaryCond)
    let thenE = ctx.lowerExpr(expr.exprTernaryThen)
    let elseE = ctx.lowerExpr(expr.exprTernaryElse)
    return HirNode(kind: hIf, ifCond: cond, ifThen: thenE, ifElse: elseE,
                   typ: typ, loc: loc)

  of ekIs:
    let operand = ctx.lowerExpr(expr.exprIsOperand)
    var isType = makeUnknown()
    if expr.exprIsType != nil and expr.exprIsType.kind == tekNamed:
      isType = makeNamed(expr.exprIsType.typeName)
    return HirNode(kind: hIs, isOperand: operand, isType: isType,
                   typ: makeBool(), loc: loc)

  of ekMatch:
    let subject = ctx.lowerExpr(expr.exprMatchSubject)
    var arms: seq[HirMatchArm] = @[]
    for arm in expr.exprMatchArms:
      arms.add(HirMatchArm(pattern: arm.pattern, body: ctx.lowerExpr(arm.body)))
    return HirNode(kind: hMatch, matchSubject: subject, matchArms: arms,
                   typ: typ, loc: loc)

  of ekSizeOf:
    return HirNode(kind: hLit, litToken: Token(kind: tkIntLiteral, text: "0", loc: loc),
                   typ: makeInt(), loc: loc)

  of ekIntrinsic:
    return HirNode(kind: hLit, litToken: Token(kind: tkStringLiteral, text: "\"\"", loc: loc),
                   typ: makeStr(), loc: loc)

  else:
    return HirNode(kind: hLit, litToken: Token(kind: tkIntLiteral, text: "0", loc: loc),
                   typ: makeVoid(), loc: loc)

proc lowerStmt(ctx: var LowerCtx, stmt: Stmt): HirNode =
  if stmt == nil: return nil
  let loc = stmt.loc

  case stmt.kind
  of skExpr:
    return ctx.lowerExpr(stmt.stmtExpr)

  of skLet:
    let initHir = ctx.lowerExpr(stmt.stmtLetInit)
    let allocaType = if stmt.stmtLetType != nil:
      case stmt.stmtLetType.kind
      of tekNamed:
        case stmt.stmtLetType.typeName
        of "int", "int32": makeInt()
        of "int64": makeInt64()
        of "float64": makeFloat64()
        of "float32": makeFloat32()
        of "bool": makeBool()
        else: makeNamed(stmt.stmtLetType.typeName)
      of tekPointer: makePointer(makeUnknown())
      else: makeUnknown()
    else:
      ctx.resolveExprType(stmt.stmtLetInit)

    let alloca = hirAlloca(stmt.stmtLetName, allocaType, loc)
    let varNode = hirVar(stmt.stmtLetName, makePointer(allocaType), loc)
    let store = hirStore(varNode, initHir, loc)
    return HirNode(kind: hBlock, blockStmts: @[alloca, store],
                   blockExpr: nil, typ: makeVoid(), loc: loc)

  of skReturn:
    let value = if stmt.stmtReturnValue != nil: ctx.lowerExpr(stmt.stmtReturnValue) else: nil
    return hirReturn(value, loc)

  of skIf:
    let cond = ctx.lowerExpr(stmt.stmtIfCond)
    let thenBlock = ctx.lowerBlock(stmt.stmtIfThen)
    var elseBlock: HirNode = nil
    if stmt.stmtIfElse != nil:
      elseBlock = ctx.lowerBlock(stmt.stmtIfElse)
    elif stmt.stmtIfElseIfs.len > 0:
      # Desugar else-if chain
      var current: HirNode = nil
      for i in countdown(stmt.stmtIfElseIfs.len - 1, 0):
        let elifBranch = stmt.stmtIfElseIfs[i]
        let elifCond = ctx.lowerExpr(elifBranch.cond)
        let elifBlock = ctx.lowerBlock(elifBranch.blk)
        current = HirNode(kind: hIf, ifCond: elifCond, ifThen: elifBlock,
                         ifElse: current, typ: makeVoid(), loc: elifBranch.loc)
      elseBlock = current
    return HirNode(kind: hIf, ifCond: cond, ifThen: thenBlock, ifElse: elseBlock,
                   typ: makeVoid(), loc: loc)

  of skWhile:
    let cond = ctx.lowerExpr(stmt.stmtWhileCond)
    let body = ctx.lowerBlock(stmt.stmtWhileBody)
    return HirNode(kind: hWhile, whileCond: cond, whileBody: body,
                   typ: makeVoid(), loc: loc)

  of skLoop:
    let body = ctx.lowerBlock(stmt.stmtLoopBody)
    return HirNode(kind: hLoop, loopBody: body, typ: makeVoid(), loc: loc)

  of skBreak:
    return HirNode(kind: hBreak, breakLabel: stmt.stmtBreakLabel,
                   typ: makeVoid(), loc: loc)

  of skContinue:
    return HirNode(kind: hContinue, continueLabel: stmt.stmtContinueLabel,
                   typ: makeVoid(), loc: loc)

  of skFor:
    # Desugar: for i in iter { body } → { let __iter = iter; while __hasNext(__iter) { let i = __next(__iter); body } }
    let iterExpr = ctx.lowerExpr(stmt.stmtForIter)
    let body = ctx.lowerBlock(stmt.stmtForBody)
    # Simplified: just lower the body for now
    return HirNode(kind: hLoop, loopBody: body, typ: makeVoid(), loc: loc)

  of skDoWhile:
    let body = ctx.lowerBlock(stmt.stmtDoWhileBody)
    let cond = ctx.lowerExpr(stmt.stmtDoWhileCond)
    let whileNode = HirNode(kind: hWhile, whileCond: cond, whileBody: body,
                           typ: makeVoid(), loc: loc)
    return HirNode(kind: hBlock, blockStmts: @[body, whileNode],
                   blockExpr: nil, typ: makeVoid(), loc: loc)

  of skMatch:
    let subject = ctx.lowerExpr(stmt.stmtMatchSubject)
    var arms: seq[HirMatchArm] = @[]
    for arm in stmt.stmtMatchArms:
      arms.add(HirMatchArm(pattern: arm.pattern, body: ctx.lowerExpr(arm.body)))
    return HirNode(kind: hMatch, matchSubject: subject, matchArms: arms,
                   typ: makeVoid(), loc: loc)

  of skDecl:
    return HirNode(kind: hLit, litToken: Token(kind: tkIntLiteral, text: "0", loc: loc),
                   typ: makeVoid(), loc: loc)

proc lowerBlock(ctx: var LowerCtx, blk: Block): HirNode =
  if blk == nil: return nil
  var stmts: seq[HirNode] = @[]
  for s in blk.stmts:
    let hir = ctx.lowerStmt(s)
    if hir != nil:
      stmts.add(hir)
  return HirNode(kind: hBlock, blockStmts: stmts, blockExpr: nil,
                 typ: makeVoid(), loc: blk.loc)

proc lowerFunc*(ctx: var LowerCtx, decl: Decl): HirFunc =
  var params: seq[tuple[name: string, typ: Type]] = @[]
  for p in decl.declFuncParams:
    var pType = makeUnknown()
    if p.ptype != nil:
      case p.ptype.kind
      of tekNamed:
        case p.ptype.typeName
        of "int", "int32": pType = makeInt()
        of "int64": pType = makeInt64()
        of "float64": pType = makeFloat64()
        of "float32": pType = makeFloat32()
        of "bool": pType = makeBool()
        of "Point", "Self": pType = makeNamed(p.ptype.typeName)
        else: pType = makeNamed(p.ptype.typeName)
      of tekPointer: pType = makePointer(makeUnknown())
      else: discard
    params.add((p.name, pType))

  var retType = makeVoid()
  if decl.declFuncReturnType != nil:
    case decl.declFuncReturnType.kind
    of tekNamed:
      case decl.declFuncReturnType.typeName
      of "int", "int32": retType = makeInt()
      of "int64": retType = makeInt64()
      of "float64": retType = makeFloat64()
      of "float32": retType = makeFloat32()
      of "bool": retType = makeBool()
      else: retType = makeNamed(decl.declFuncReturnType.typeName)
    of tekPointer: retType = makePointer(makeUnknown())
    else: discard

  ctx.currentFuncRetType = retType
  let body = if decl.declFuncBody != nil: ctx.lowerBlock(decl.declFuncBody) else: nil

  result = HirFunc(name: decl.declFuncName, params: params, retType: retType,
                   body: body, isPublic: decl.isPublic)

proc lowerModule*(module: Module, sema: Sema): HirModule =
  var ctx = initLowerCtx(module, sema)
  var funcs: seq[HirFunc] = @[]
  var externFuncs: seq[HirFunc] = @[]
  var structs: seq[tuple[name: string, fields: seq[tuple[name: string, typ: Type]]]] = @[]
  var enums: seq[tuple[name: string, variants: seq[string]]] = @[]
  var consts: seq[tuple[name: string, typ: Type, value: HirNode]] = @[]

  for decl in module.items:
    case decl.kind
    of dkFunc:
      if decl.declFuncBody != nil:
        funcs.add(ctx.lowerFunc(decl))
      else:
        # Extern function (no body)
        externFuncs.add(ctx.lowerFunc(decl))
    of dkImpl:
      for methodDecl in decl.declImplMethods:
        if methodDecl.kind == dkFunc:
          var hf = ctx.lowerFunc(methodDecl)
          hf.name = decl.declImplTypeName & "_" & hf.name
          funcs.add(hf)
    of dkStruct:
      var fields: seq[tuple[name: string, typ: Type]] = @[]
      for f in decl.declStructFields:
        var fType = makeUnknown()
        if f.ftype != nil and f.ftype.kind == tekNamed:
          case f.ftype.typeName
          of "float64": fType = makeFloat64()
          of "float32": fType = makeFloat32()
          of "int", "int32": fType = makeInt()
          else: fType = makeNamed(f.ftype.typeName)
        fields.add((f.name, fType))
      structs.add((decl.declStructName, fields))
    of dkEnum:
      var variants: seq[string] = @[]
      for v in decl.declEnumVariants:
        variants.add(v.name)
      enums.add((decl.declEnumName, variants))
    of dkConst:
      let value = ctx.lowerExpr(decl.declConstValue)
      let typ = if decl.declConstType != nil:
        case decl.declConstType.kind
        of tekNamed: makeNamed(decl.declConstType.typeName)
        else: makeUnknown()
      else: makeUnknown()
      consts.add((decl.declConstName, typ, value))
    else: discard

  result = HirModule(funcs: funcs, externFuncs: externFuncs, structs: structs, enums: enums, consts: consts)
