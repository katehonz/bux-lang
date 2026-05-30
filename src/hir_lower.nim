import std/[tables, sets, strformat, strutils]
import ast, types, token, source_location, hir, sema, scope

type
  LowerCtx* = object
    module*: Module
    globalScope*: Scope
    methodTable*: Table[string, seq[MethodInfo]]
    currentFuncRetType*: Type
    currentFuncDecl*: Decl
    varCounter*: int
    typeSubst*: Table[string, Type]  # Type parameter substitution for generics
    importTable*: Table[string, string]  # Local name → fully qualified name for imports

proc freshName(ctx: var LowerCtx): string =
  inc ctx.varCounter
  result = "__tmp_" & $ctx.varCounter

proc lowerMatch(ctx: var LowerCtx, subject: HirNode, arms: seq[HirMatchArm], typ: Type, loc: SourceLocation): HirNode =
  # Lower match expression to a block with if-else chain.
  # For now, supports enum tag matching and wildcard/ident fallbacks.
  let resultName = ctx.freshName()
  var stmts: seq[HirNode] = @[]
  
  # Allocate result variable
  stmts.add(hirAlloca(resultName, typ, loc))
  
  # Build if-else chain from arms (last arm is the outermost else)
  var ifChain: HirNode = nil
  
  for i in countdown(arms.len - 1, 0):
    let arm = arms[i]
    let body = arm.body
    
    case arm.pattern.kind
    of pkEnum:
      let path = arm.pattern.patEnumPath
      if path.len >= 2:
        let enumName = path[0]
        let variantName = path[^1]
        let tagName = enumName & "_" & variantName
        
        # condition: subject.tag == EnumName_VariantName
        let tagField = HirNode(kind: hFieldPtr, fieldPtrBase: subject, fieldName: "tag",
                               typ: makePointer(makeNamed(enumName & "_Tag")), loc: loc)
        let tagLoad = HirNode(kind: hLoad, loadPtr: tagField, typ: makeNamed(enumName & "_Tag"), loc: loc)
        let tagConst = hirLit(Token(kind: tkIdent, text: tagName, loc: loc), makeNamed(enumName & "_Tag"), loc)
        let cond = hirBinary(tkEq, tagLoad, tagConst, makeBool(), loc)
        
        # body: result = arm_body
        var armStmts: seq[HirNode] = @[]
        armStmts.add(hirStore(hirVar(resultName, typ, loc), body, loc))
        let armBlock = hirBlock(armStmts, nil, makeVoid(), loc)
        
        if ifChain == nil:
          ifChain = HirNode(kind: hIf, ifCond: cond, ifThen: armBlock, ifElse: nil,
                            typ: makeVoid(), loc: loc)
        else:
          ifChain = HirNode(kind: hIf, ifCond: cond, ifThen: armBlock, ifElse: ifChain,
                            typ: makeVoid(), loc: loc)
      else:
        var armStmts: seq[HirNode] = @[]
        armStmts.add(hirStore(hirVar(resultName, typ, loc), body, loc))
        let armBlock = hirBlock(armStmts, nil, makeVoid(), loc)
        if ifChain == nil:
          ifChain = armBlock
        else:
          ifChain = HirNode(kind: hIf,
            ifCond: hirLit(Token(kind: tkBoolLiteral, text: "true", loc: loc), makeBool(), loc),
            ifThen: armBlock, ifElse: ifChain, typ: makeVoid(), loc: loc)
    of pkWildcard, pkIdent:
      # Default arm — always matches
      var armStmts: seq[HirNode] = @[]
      armStmts.add(hirStore(hirVar(resultName, typ, loc), body, loc))
      let armBlock = hirBlock(armStmts, nil, makeVoid(), loc)
      if ifChain == nil:
        ifChain = armBlock
      else:
        ifChain = HirNode(kind: hIf,
          ifCond: hirLit(Token(kind: tkBoolLiteral, text: "true", loc: loc), makeBool(), loc),
          ifThen: armBlock, ifElse: ifChain, typ: makeVoid(), loc: loc)
    else:
      var armStmts: seq[HirNode] = @[]
      armStmts.add(hirStore(hirVar(resultName, typ, loc), body, loc))
      let armBlock = hirBlock(armStmts, nil, makeVoid(), loc)
      if ifChain == nil:
        ifChain = armBlock
      else:
        ifChain = HirNode(kind: hIf,
          ifCond: hirLit(Token(kind: tkBoolLiteral, text: "true", loc: loc), makeBool(), loc),
          ifThen: armBlock, ifElse: ifChain, typ: makeVoid(), loc: loc)
  
  stmts.add(ifChain)
  
  # Return the result variable as the block expression
  return hirBlock(stmts, hirVar(resultName, typ, loc), typ, loc)

proc initLowerCtx*(module: Module, sema: Sema): LowerCtx =
  result.module = module
  result.globalScope = sema.globalScope
  result.methodTable = sema.methodTable
  result.varCounter = 0
  result.typeSubst = initTable[string, Type]()
  result.importTable = initTable[string, string]()

proc resolveTypeExpr(ctx: var LowerCtx, te: TypeExpr): Type =
  if te == nil: return makeUnknown()
  case te.kind
  of tekNamed:
    case te.typeName
    of "void": return makeVoid()
    of "bool": return makeBool()
    of "int": return makeInt()
    of "int32": return makeInt()
    of "int64": return makeInt64()
    of "float64": return makeFloat64()
    of "float32": return makeFloat32()
    of "uint": return makeUInt()
    of "uint32": return makeUInt()
    of "uint64": return makeUInt64()
    else: return makeNamed(te.typeName)
  of tekPointer: return makePointer(ctx.resolveTypeExpr(te.pointerPointee))
  of tekSlice: return makeSlice(ctx.resolveTypeExpr(te.sliceElement))
  else: return makeUnknown()

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
    # Check global scope first
    let sym = ctx.globalScope.lookup(expr.exprIdent)
    if sym != nil and sym.typ != nil: return sym.typ
    # Check current function parameters
    if ctx.currentFuncDecl != nil:
      var params: seq[Param] = @[]
      case ctx.currentFuncDecl.kind
      of dkFunc: params = ctx.currentFuncDecl.declFuncParams
      of dkExternFunc: params = ctx.currentFuncDecl.declExtFuncParams
      else: discard
      for p in params:
        if p.name == expr.exprIdent and p.ptype != nil:
          case p.ptype.kind
          of tekNamed:
            case p.ptype.typeName
            of "int", "int32": return makeInt()
            of "int64": return makeInt64()
            of "float64": return makeFloat64()
            of "float32": return makeFloat32()
            of "bool": return makeBool()
            of "uint": return makeUInt()
            of "void": return makeVoid()
            else: return makeNamed(p.ptype.typeName)
          of tekPointer:
            let pointeeType = ctx.resolveTypeExpr(p.ptype.pointerPointee)
            return makePointer(pointeeType)
          else: discard
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
    var objType = ctx.resolveExprType(expr.exprFieldObj)
    # Auto-dereference pointer types for field access
    if objType.kind == tkPointer and objType.inner.len > 0:
      objType = objType.inner[0]
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
              of tekPointer:
                return ctx.resolveTypeExpr(f.ftype)
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
      return ctx.resolveTypeExpr(expr.exprCastType)
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
    let name = expr.exprIdent
    if ctx.importTable.hasKey(name):
      return hirVar(ctx.importTable[name], typ, loc)
    return hirVar(name, typ, loc)

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

    # Generic function call: Max<int>(10, 20) → Max_int(10, 20)
    if expr.exprCallCallee.kind == ekGenericCall:
      let baseName = expr.exprCallCallee.exprGenericCallee
      var typeSuffix = ""
      for i, targ in expr.exprCallCallee.exprGenericTypeArgs:
        if i > 0:
          typeSuffix.add("_")
        if targ.kind == tekNamed:
          typeSuffix.add(targ.typeName)
        else:
          typeSuffix.add("unknown")
      let mangledName = baseName & "_" & typeSuffix
      var args: seq[HirNode] = @[]
      for arg in expr.exprCallArgs:
        args.add(ctx.lowerExpr(arg))
      return hirCall(mangledName, args, typ, loc)

    # Regular function call
    var calleeName = ""
    if expr.exprCallCallee.kind == ekIdent:
      calleeName = expr.exprCallCallee.exprIdent
      if ctx.importTable.hasKey(calleeName):
        calleeName = ctx.importTable[calleeName]
    elif expr.exprCallCallee.kind == ekPath:
      calleeName = expr.exprCallCallee.exprPath.join("_")
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
    let objType = ctx.resolveExprType(expr.exprFieldObj)
    let base = ctx.lowerExpr(expr.exprFieldObj)
    # Auto-dereference pointer types for field access
    if objType.kind == tkPointer:
      let arrowPtr = HirNode(kind: hArrowField, arrowFieldBase: base,
                             arrowFieldName: expr.exprFieldName,
                             typ: makePointer(typ), loc: loc)
      return HirNode(kind: hLoad, loadPtr: arrowPtr, typ: typ, loc: loc)
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
      castType = ctx.resolveTypeExpr(expr.exprCastType)
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
    return lowerMatch(ctx, subject, arms, typ, loc)

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
  # If the last statement is an expression, make it the block's result expression
  var expr: HirNode = nil
  if stmts.len > 0 and stmts[^1].kind == hBlock and stmts[^1].blockExpr != nil:
    # Nested block expression (e.g., from match lowering) — lift it
    let last = stmts[^1]
    stmts[^1] = hirBlock(last.blockStmts, nil, makeVoid(), last.loc)
    expr = last.blockExpr
  elif stmts.len > 0 and stmts[^1].kind != hBlock:
    # Last stmt is a simple expression-like node — we can't easily extract it,
    # but for hVar/hLit/hCall etc. we could treat them as block expr.
    # For now, leave as-is to avoid breaking control-flow statements.
    discard
  return HirNode(kind: hBlock, blockStmts: stmts, blockExpr: expr,
                 typ: if expr != nil: expr.typ else: makeVoid(), loc: blk.loc)

proc lowerFunc*(ctx: var LowerCtx, decl: Decl): HirFunc =
  # Set up type substitution for generic functions
  let oldSubst = ctx.typeSubst
  
  var funcName: string
  var funcParams: seq[Param]
  var funcReturnType: TypeExpr
  var funcBody: Block
  
  case decl.kind
  of dkFunc:
    funcName = decl.declFuncName
    funcParams = decl.declFuncParams
    funcReturnType = decl.declFuncReturnType
    funcBody = decl.declFuncBody
  of dkExternFunc:
    funcName = decl.declExtFuncName
    funcParams = decl.declExtFuncParams
    funcReturnType = decl.declExtFuncReturnType
    funcBody = nil
  else:
    result = HirFunc(name: "", params: @[], retType: makeVoid(), body: nil)
    return
  
  var params: seq[tuple[name: string, typ: Type]] = @[]
  for p in funcParams:
    var pType = makeUnknown()
    if p.ptype != nil:
      case p.ptype.kind
      of tekNamed:
        # Check if this is a type parameter
        if ctx.typeSubst.hasKey(p.ptype.typeName):
          pType = ctx.typeSubst[p.ptype.typeName]
        else:
          case p.ptype.typeName
          of "int", "int32": pType = makeInt()
          of "int64": pType = makeInt64()
          of "float64": pType = makeFloat64()
          of "float32": pType = makeFloat32()
          of "bool": pType = makeBool()
          of "Point", "Self": pType = makeNamed(p.ptype.typeName)
          else: pType = makeNamed(p.ptype.typeName)
      of tekPointer:
        let pointeeType = ctx.resolveTypeExpr(p.ptype.pointerPointee)
        pType = makePointer(pointeeType)
      else: discard
    params.add((p.name, pType))

  var retType = makeVoid()
  if funcReturnType != nil:
    case funcReturnType.kind
    of tekNamed:
      # Check if this is a type parameter
      if ctx.typeSubst.hasKey(funcReturnType.typeName):
        retType = ctx.typeSubst[funcReturnType.typeName]
      else:
        case funcReturnType.typeName
        of "int", "int32": retType = makeInt()
        of "int64": retType = makeInt64()
        of "float64": retType = makeFloat64()
        of "float32": retType = makeFloat32()
        of "bool": retType = makeBool()
        else: retType = makeNamed(funcReturnType.typeName)
    of tekPointer:
      let pointeeType = ctx.resolveTypeExpr(funcReturnType.pointerPointee)
      retType = makePointer(pointeeType)
    else: discard

  ctx.currentFuncRetType = retType
  ctx.currentFuncDecl = decl
  let body = if funcBody != nil: ctx.lowerBlock(funcBody) else: nil

  result = HirFunc(name: funcName, params: params, retType: retType,
                   body: body, isPublic: decl.isPublic)
  
  # Restore old substitution
  ctx.typeSubst = oldSubst

proc lowerModule*(module: Module, sema: Sema): HirModule =
  var ctx = initLowerCtx(module, sema)
  var funcs: seq[HirFunc] = @[]
  var externFuncs: seq[HirFunc] = @[]
  var structs: seq[tuple[name: string, fields: seq[tuple[name: string, typ: Type]]]] = @[]
  var enums: seq[tuple[name: string, variants: seq[HirEnumVariant]]] = @[]
  var consts: seq[tuple[name: string, typ: Type, value: HirNode]] = @[]

  # Collect local symbol names so we don't remap them via imports
  var localSymbols = initHashSet[string]()
  for decl in module.items:
    case decl.kind
    of dkFunc: localSymbols.incl(decl.declFuncName)
    of dkExternFunc: localSymbols.incl(decl.declExtFuncName)
    of dkStruct: localSymbols.incl(decl.declStructName)
    of dkEnum: localSymbols.incl(decl.declEnumName)
    of dkUnion: localSymbols.incl(decl.declUnionName)
    else: discard

  # Collect imports for name resolution
  for decl in module.items:
    if decl.kind == dkUse:
      case decl.declUseKind
      of ukSingle:
        if decl.declUsePath.len > 0:
          let localName = decl.declUsePath[^1]
          let fullName = decl.declUsePath.join("_")
          if localName notin localSymbols:
            ctx.importTable[localName] = fullName
      of ukMulti:
        if decl.declUsePath.len > 0:
          let basePath = decl.declUsePath.join("_")
          for name in decl.declUseNames:
            if name notin localSymbols:
              ctx.importTable[name] = basePath & "_" & name
      of ukGlob:
        # For glob imports, we can't statically resolve all names here.
        # Store the base path for potential future use.
        discard


  # First pass: collect generic functions
  var genericFuncs = initTable[string, Decl]()
  for decl in module.items:
    if decl.kind == dkFunc and decl.declFuncTypeParams.len > 0:
      genericFuncs[decl.declFuncName] = decl

  # Second pass: find all generic calls and monomorphize
  proc findGenericCalls(expr: Expr): seq[tuple[name: string, typeArgs: seq[TypeExpr]]] =
    if expr == nil: return @[]
    result = @[]
    case expr.kind
    of ekCall:
      if expr.exprCallCallee.kind == ekGenericCall:
        result.add((expr.exprCallCallee.exprGenericCallee, expr.exprCallCallee.exprGenericTypeArgs))
      result.add(findGenericCalls(expr.exprCallCallee))
      for arg in expr.exprCallArgs:
        result.add(findGenericCalls(arg))
    of ekGenericCall:
      result.add((expr.exprGenericCallee, expr.exprGenericTypeArgs))
    of ekBinary:
      result.add(findGenericCalls(expr.exprBinaryLeft))
      result.add(findGenericCalls(expr.exprBinaryRight))
    of ekUnary:
      result.add(findGenericCalls(expr.exprUnaryOperand))
    of ekAssign:
      result.add(findGenericCalls(expr.exprAssignTarget))
      result.add(findGenericCalls(expr.exprAssignValue))
    of ekBlock:
      if expr.exprBlock != nil:
        for stmt in expr.exprBlock.stmts:
          case stmt.kind
          of skLet: result.add(findGenericCalls(stmt.stmtLetInit))
          of skReturn: result.add(findGenericCalls(stmt.stmtReturnValue))
          of skExpr: result.add(findGenericCalls(stmt.stmtExpr))
          of skIf:
            result.add(findGenericCalls(stmt.stmtIfCond))
          of skWhile:
            result.add(findGenericCalls(stmt.stmtWhileCond))
          else: discard
    else: discard

  # Collect all generic instantiations
  var instantiations: seq[tuple[name: string, typeArgs: seq[TypeExpr]]] = @[]
  for decl in module.items:
    if decl.kind == dkFunc and decl.declFuncBody != nil:
      for stmt in decl.declFuncBody.stmts:
        case stmt.kind
        of skLet:
          instantiations.add(findGenericCalls(stmt.stmtLetInit))
        of skReturn:
          instantiations.add(findGenericCalls(stmt.stmtReturnValue))
        of skExpr:
          instantiations.add(findGenericCalls(stmt.stmtExpr))
        of skIf:
          instantiations.add(findGenericCalls(stmt.stmtIfCond))
        of skWhile:
          instantiations.add(findGenericCalls(stmt.stmtWhileCond))
        else: discard

  # Generate monomorphized functions
  var generated = initTable[string, bool]()
  for inst in instantiations:
    let baseName = inst.name
    if genericFuncs.hasKey(baseName):
      var typeSuffix = ""
      for i, targ in inst.typeArgs:
        if i > 0: typeSuffix.add("_")
        if targ.kind == tekNamed:
          typeSuffix.add(targ.typeName)
        else:
          typeSuffix.add("unknown")
      let mangledName = baseName & "_" & typeSuffix
      if not generated.hasKey(mangledName):
        # Generate specialized version
        let genericDecl = genericFuncs[baseName]
        
        # Build type substitution table
        var subst = initTable[string, Type]()
        for j, tp in genericDecl.declFuncTypeParams:
          if j < inst.typeArgs.len:
            let targ = inst.typeArgs[j]
            if targ.kind == tekNamed:
              case targ.typeName
              of "int", "int32": subst[tp] = makeInt()
              of "int64": subst[tp] = makeInt64()
              of "float64": subst[tp] = makeFloat64()
              of "float32": subst[tp] = makeFloat32()
              of "bool": subst[tp] = makeBool()
              else: subst[tp] = makeNamed(targ.typeName)
        
        # Create specialized declaration
        var specDecl = Decl(
          kind: dkFunc,
          loc: genericDecl.loc,
          isPublic: genericDecl.isPublic,
          declFuncAsm: genericDecl.declFuncAsm,
          declFuncCallConv: genericDecl.declFuncCallConv,
          declFuncName: mangledName,
          declFuncTypeParams: @[],
          declFuncParams: genericDecl.declFuncParams,
          declFuncReturnType: genericDecl.declFuncReturnType,
          declFuncBody: genericDecl.declFuncBody
        )
        
        # Set substitution and lower
        ctx.typeSubst = subst
        funcs.add(ctx.lowerFunc(specDecl))
        ctx.typeSubst = initTable[string, Type]()  # Clear substitution
        generated[mangledName] = true

  # Third pass: lower all non-generic functions
  for decl in module.items:
    case decl.kind
    of dkFunc:
      if decl.declFuncTypeParams.len == 0:  # Skip generic functions
        if decl.declFuncBody != nil:
          funcs.add(ctx.lowerFunc(decl))
        else:
          # Extern function (no body)
          externFuncs.add(ctx.lowerFunc(decl))
    of dkExternFunc:
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
        let fType = if f.ftype != nil: ctx.resolveTypeExpr(f.ftype) else: makeUnknown()
        fields.add((f.name, fType))
      structs.add((decl.declStructName, fields))
    of dkEnum:
      var variants: seq[HirEnumVariant] = @[]
      for v in decl.declEnumVariants:
        var fields: seq[Type] = @[]
        for f in v.fields:
          var fType = makeUnknown()
          if f != nil and f.kind == tekNamed:
            case f.typeName
            of "int", "int32": fType = makeInt()
            of "int64": fType = makeInt64()
            of "float64": fType = makeFloat64()
            of "float32": fType = makeFloat32()
            of "bool": fType = makeBool()
            of "String", "str": fType = makeStr()
            else: fType = makeNamed(f.typeName)
          fields.add(fType)
        
        var namedFields: seq[tuple[name: string, typ: Type]] = @[]
        for nf in v.namedFields:
          var fType = makeUnknown()
          if nf.ftype != nil and nf.ftype.kind == tekNamed:
            case nf.ftype.typeName
            of "int", "int32": fType = makeInt()
            of "int64": fType = makeInt64()
            of "float64": fType = makeFloat64()
            of "float32": fType = makeFloat32()
            of "bool": fType = makeBool()
            of "String", "str": fType = makeStr()
            else: fType = makeNamed(nf.ftype.typeName)
          namedFields.add((nf.name, fType))
        
        variants.add(HirEnumVariant(name: v.name, fields: fields, namedFields: namedFields))
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
