import std/[tables, sets, strutils]
import ast, types, token, source_location, hir, sema, scope

type
  LowerCtx* = object
    module*: Module
    globalScope*: Scope
    methodTable*: Table[string, seq[MethodInfo]]
    currentFuncRetType*: Type
    currentFuncDecl*: Decl
    varCounter*: int
    tryCounter*: int
    pendingStmts*: seq[HirNode]
    deferStmts*: seq[HirNode]
    typeSubst*: Table[string, Type]  # Type parameter substitution for generics
    importTable*: Table[string, string]  # Local name → fully qualified name for imports
    genericStructs*: Table[string, Decl]  # Generic struct declarations
    generatedStructInsts*: Table[string, bool]  # Track generated struct instantiations
    extraStructs*: seq[tuple[name: string, fields: seq[tuple[name: string, typ: Type]]]]
    structInstMap*: Table[string, tuple[baseName: string, typeArgs: seq[Type]]]  # Mangled name -> base + args
    genericFuncs*: Table[string, Decl]  # Generic function declarations
    generatedFuncInsts*: Table[string, bool]  # Track generated function instantiations
    extraFuncs*: seq[HirFunc]  # Monomorphized generic methods
    varTypeExprs*: Table[string, TypeExpr]  # Track variable names -> type expr for generic method inference
    closureDepth*: int
    currentClosureExpr*: Expr
    envInstanceName*: string

proc freshName(ctx: var LowerCtx): string =
  inc ctx.varCounter
  result = "__tmp_" & $ctx.varCounter

proc freshTryVar(ctx: var LowerCtx): string =
  inc ctx.tryCounter
  result = "__try_" & $ctx.tryCounter

proc flushPending(ctx: var LowerCtx, node: HirNode): HirNode =
  if ctx.pendingStmts.len > 0:
    var stmts = ctx.pendingStmts
    ctx.pendingStmts = @[]
    stmts.add(node)
    return hirBlock(stmts, nil, makeVoid(), node.loc)
  return node

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
  result.tryCounter = 0
  result.pendingStmts = @[]
  result.typeSubst = initTable[string, Type]()
  result.importTable = initTable[string, string]()
  result.genericStructs = initTable[string, Decl]()
  result.generatedStructInsts = initTable[string, bool]()
  result.extraStructs = @[]
  result.structInstMap = initTable[string, tuple[baseName: string, typeArgs: seq[Type]]]()
  result.genericFuncs = initTable[string, Decl]()
  result.generatedFuncInsts = initTable[string, bool]()
  result.extraFuncs = @[]
  result.varTypeExprs = initTable[string, TypeExpr]()

proc resolveTypeExpr(ctx: var LowerCtx, te: TypeExpr): Type

proc substituteType(ctx: var LowerCtx, te: TypeExpr, subst: Table[string, Type]): Type =
  if te == nil: return makeUnknown()
  case te.kind
  of tekNamed:
    if subst.hasKey(te.typeName):
      return subst[te.typeName]
    if te.typeArgs.len > 0 and ctx.genericStructs.hasKey(te.typeName):
      var suffix = ""
      for i, arg in te.typeArgs:
        if i > 0: suffix.add("_")
        let argType = substituteType(ctx, arg, subst)
        suffix.add(argType.toString)
      let mangledName = te.typeName & "_" & suffix
      if not ctx.generatedStructInsts.hasKey(mangledName):
        let genericDecl = ctx.genericStructs[te.typeName]
        # Skip if any type arg is still an unresolved type parameter
        var hasUnresolved = false
        for arg in te.typeArgs:
          let argType = substituteType(ctx, arg, subst)
          for tp in genericDecl.declStructTypeParams:
            if argType.kind == tkNamed and argType.name == tp.name:
              hasUnresolved = true
              break
          if hasUnresolved: break
        if not hasUnresolved:
          var localSubst = subst
          for j, tp in genericDecl.declStructTypeParams:
            if j < te.typeArgs.len:
              localSubst[tp.name] = substituteType(ctx, te.typeArgs[j], subst)
          var fields: seq[tuple[name: string, typ: Type]] = @[]
          var concreteArgs: seq[Type] = @[]
          for f in genericDecl.declStructFields:
            let resolvedType = substituteType(ctx, f.ftype, localSubst)
            fields.add((f.name, resolvedType))
          for arg in te.typeArgs:
            concreteArgs.add(substituteType(ctx, arg, subst))
          ctx.extraStructs.add((mangledName, fields))
          ctx.generatedStructInsts[mangledName] = true
          ctx.structInstMap[mangledName] = (te.typeName, concreteArgs)
      return makeNamed(mangledName)
    return ctx.resolveTypeExpr(te)
  of tekOwn:
    return substituteType(ctx, te.pointerPointee, subst)
  of tekPointer:
    return makePointer(substituteType(ctx, te.pointerPointee, subst))
  of tekRef:
    return makeRef(substituteType(ctx, te.pointerPointee, subst))
  of tekMutRef:
    return makeMutRef(substituteType(ctx, te.pointerPointee, subst))
  of tekDynRef:
    return makeDynRef(te.dynInterface)
  of tekSlice:
    return makeSlice(substituteType(ctx, te.sliceElement, subst))
  of tekTuple:
    var elems: seq[Type] = @[]
    for e in te.tupleElements:
      elems.add(substituteType(ctx, e, subst))
    return makeTuple(elems)
  else:
    return ctx.resolveTypeExpr(te)

proc resolveTypeExpr(ctx: var LowerCtx, te: TypeExpr): Type =
  if te == nil: return makeUnknown()
  case te.kind
  of tekNamed:
    if te.typeArgs.len > 0 and ctx.genericStructs.hasKey(te.typeName):
      var suffix = ""
      for i, arg in te.typeArgs:
        if i > 0: suffix.add("_")
        let argType = ctx.resolveTypeExpr(arg)
        suffix.add(argType.toString)
      let mangledName = te.typeName & "_" & suffix
      if not ctx.generatedStructInsts.hasKey(mangledName):
        let genericDecl = ctx.genericStructs[te.typeName]
        # Skip if any type arg is still an unresolved type parameter
        var hasUnresolved = false
        for arg in te.typeArgs:
          let argType = ctx.resolveTypeExpr(arg)
          for tp in genericDecl.declStructTypeParams:
            if argType.kind == tkNamed and argType.name == tp.name:
              hasUnresolved = true
              break
          if hasUnresolved: break
        if not hasUnresolved:
          var fields: seq[tuple[name: string, typ: Type]] = @[]
          var subst = initTable[string, Type]()
          var concreteArgs: seq[Type] = @[]
          for j, tp in genericDecl.declStructTypeParams:
            if j < te.typeArgs.len:
              subst[tp.name] = ctx.resolveTypeExpr(te.typeArgs[j])
          for arg in te.typeArgs:
            concreteArgs.add(ctx.resolveTypeExpr(arg))
          for f in genericDecl.declStructFields:
            let resolvedType = substituteType(ctx, f.ftype, subst)
            fields.add((f.name, resolvedType))
          ctx.extraStructs.add((mangledName, fields))
          ctx.generatedStructInsts[mangledName] = true
          ctx.structInstMap[mangledName] = (te.typeName, concreteArgs)
      return makeNamed(mangledName)
    case te.typeName
    of "void": return makeVoid()
    of "bool": return makeBool()
    of "bool8": return makeBool8()
    of "bool16": return makeBool16()
    of "bool32": return makeBool32()
    of "char8": return makeChar8()
    of "char16": return makeChar16()
    of "char32": return makeChar32()
    of "String", "str": return makeStr()
    of "int": return makeInt()
    of "int8": return makeInt8()
    of "int16": return makeInt16()
    of "int32": return makeInt32()
    of "int64": return makeInt64()
    of "uint": return makeUInt()
    of "uint8": return makeUInt8()
    of "uint16": return makeUInt16()
    of "uint32": return makeUInt32()
    of "uint64": return makeUInt64()
    of "float": return makeFloat64()
    of "float32": return makeFloat32()
    of "float64": return makeFloat64()
    else:
      if ctx.typeSubst.hasKey(te.typeName):
        return ctx.typeSubst[te.typeName]
      return makeNamed(te.typeName)
  of tekOwn: return ctx.resolveTypeExpr(te.pointerPointee)
  of tekDynRef: return makeDynRef(te.dynInterface)
  of tekPointer: return makePointer(ctx.resolveTypeExpr(te.pointerPointee))
  of tekSlice: return makeSlice(ctx.resolveTypeExpr(te.sliceElement))
  of tekFunc:
    var params: seq[Type] = @[]
    for p in te.funcParams:
      params.add(ctx.resolveTypeExpr(p))
    let ret = if te.funcRet != nil: ctx.resolveTypeExpr(te.funcRet) else: makeVoid()
    return makeFunc(params, ret)
  else: return makeUnknown()

# Forward declarations
proc lowerExpr(ctx: var LowerCtx, expr: Expr): HirNode
proc lowerStmt(ctx: var LowerCtx, stmt: Stmt): HirNode
proc lowerBlock(ctx: var LowerCtx, blk: Block): HirNode
proc lowerClosureFunc(ctx: var LowerCtx, expr: Expr): HirFunc

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
    # Check local variables and parameters tracked in varTypeExprs
    if ctx.varTypeExprs.hasKey(expr.exprIdent):
      return substituteType(ctx, ctx.varTypeExprs[expr.exprIdent], ctx.typeSubst)
    # Check current function parameters (fallback for untracked params)
    if ctx.currentFuncDecl != nil:
      var params: seq[Param] = @[]
      case ctx.currentFuncDecl.kind
      of dkFunc: params = ctx.currentFuncDecl.declFuncParams
      of dkExternFunc: params = ctx.currentFuncDecl.declExtFuncParams
      else: discard
      for p in params:
        if p.name == expr.exprIdent and p.ptype != nil:
          return substituteType(ctx, p.ptype, ctx.typeSubst)
    return makeUnknown()
  of ekSelf:
    # Look up self parameter type from current function
    if ctx.currentFuncDecl != nil:
      var params: seq[Param] = @[]
      case ctx.currentFuncDecl.kind
      of dkFunc: params = ctx.currentFuncDecl.declFuncParams
      of dkExternFunc: params = ctx.currentFuncDecl.declExtFuncParams
      else: discard
      if params.len > 0 and params[0].name == "self" and params[0].ptype != nil:
        return substituteType(ctx, params[0].ptype, ctx.typeSubst)
    return makeNamed("self")
  of ekBinary:
    let left = ctx.resolveExprType(expr.exprBinaryLeft)
    case expr.exprBinaryOp
    of tkEq, tkNe, tkLt, tkLe, tkGt, tkGe, tkAmpAmp, tkPipePipe:
      return makeBool()
    else: return left
  of ekUnary:
    case expr.exprUnaryOp
    of tkBang: return makeBool()
    of tkAmp: return makeMutRef(ctx.resolveExprType(expr.exprUnaryOperand))
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
      elif recvType.kind in {tkInt, tkInt8, tkInt16, tkInt32, tkInt64,
                            tkUInt, tkUInt8, tkUInt16, tkUInt32, tkUInt64,
                            tkFloat32, tkFloat64, tkBool, tkStr, tkChar8}:
        typeName = recvType.toString
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
    if objType.isPointer and objType.inner.len > 0:
      objType = objType.inner[0]
    if objType.kind == tkNamed:
      # Check if this is a _Data union field access
      if objType.name.endsWith("_Data"):
        let enumName = objType.name[0..^6]
        let enumSym = ctx.globalScope.lookup(enumName)
        if enumSym != nil and enumSym.decl != nil and enumSym.decl.kind == dkEnum:
          for variant in enumSym.decl.declEnumVariants:
            for i, f in variant.fields:
              let fieldName = variant.name & "_" & $i
              if fieldName == expr.exprFieldName:
                return ctx.resolveTypeExpr(f)
            for nf in variant.namedFields:
              if nf.name == expr.exprFieldName:
                return ctx.resolveTypeExpr(nf.ftype)
      var sym = ctx.globalScope.lookup(objType.name)
      var decl = if sym != nil: sym.decl else: nil
      # If the type is a monomorphized generic struct instance, look up the base
      if decl == nil and ctx.structInstMap.hasKey(objType.name):
        let (baseName, typeArgs) = ctx.structInstMap[objType.name]
        let baseSym = ctx.globalScope.lookup(baseName)
        if baseSym != nil and baseSym.decl != nil and baseSym.decl.kind == dkStruct:
          decl = baseSym.decl
          var subst = initTable[string, Type]()
          for i, tp in decl.declStructTypeParams:
            if i < typeArgs.len:
              subst[tp.name] = typeArgs[i]
          for f in decl.declStructFields:
            if f.name == expr.exprFieldName:
              if f.ftype != nil:
                case f.ftype.kind
                of tekNamed:
                  case f.ftype.typeName
                  of "int", "int32", "int64": return makeInt()
                  of "float64": return makeFloat64()
                  of "float32": return makeFloat32()
                  of "bool": return makeBool()
                  else:
                    if subst.hasKey(f.ftype.typeName):
                      return subst[f.ftype.typeName]
                    return makeNamed(f.ftype.typeName)
                of tekOwn, tekPointer:
                  return substituteType(ctx, f.ftype, subst)
                else: return makeUnknown()
      if decl != nil:
        case decl.kind
        of dkStruct:
          for f in decl.declStructFields:
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
                of tekOwn, tekPointer:
                  return ctx.resolveTypeExpr(f.ftype)
                else: return makeUnknown()
        of dkEnum:
          # Algebraic enum fields: tag and data
          var hasData = false
          for v in decl.declEnumVariants:
            if v.fields.len > 0 or v.namedFields.len > 0:
              hasData = true
              break
          if not hasData and expr.exprFieldName == "tag":
            return makeNamed(objType.name)
          elif expr.exprFieldName == "tag":
            return makeNamed(objType.name & "_Tag")
          elif expr.exprFieldName == "data":
            return makeNamed(objType.name & "_Data")
          else:
            # Enum variant field access: e.g., r.data.Ok_0
            # We can't easily resolve this here; return unknown
            return makeUnknown()
        else: discard
    return makeUnknown()
  of ekStructInit:
    if expr.exprStructInitTypeArgs.len > 0:
      let te = TypeExpr(kind: tekNamed, loc: expr.loc, typeName: expr.exprStructInitName, typeArgs: expr.exprStructInitTypeArgs)
      return ctx.resolveTypeExpr(te)
    return makeNamed(expr.exprStructInitName)
  of ekSlice:
    if expr.exprSliceElements.len > 0:
      return makeSlice(ctx.resolveExprType(expr.exprSliceElements[0]))
    return makeSlice(makeUnknown())
  of ekRange:
    let loType = ctx.resolveExprType(expr.exprRangeLo)
    return makeRange(loType)
  of ekTuple:
    var elems: seq[Type] = @[]
    for e in expr.exprTupleElements:
      elems.add(ctx.resolveExprType(e))
    return makeTuple(elems)
  of ekCast:
    if expr.exprCastType != nil:
      return ctx.resolveTypeExpr(expr.exprCastType)
    return makeUnknown()
  of ekTry:
    # For now, assume Result<int, String> -> int or Option<int> -> int
    return makeInt()
  of ekUnwrap:
    return makeInt()
  of ekIndex:
    let baseType = ctx.resolveExprType(expr.exprIndexObj)
    if baseType.isSlice and baseType.inner.len > 0:
      return baseType.inner[0]
    if baseType.isPointer and baseType.inner.len > 0:
      return baseType.inner[0]
    return makeUnknown()
  of ekBlock:
    if expr.exprBlock.stmts.len > 0:
      let last = expr.exprBlock.stmts[^1]
      if last.kind == skExpr:
        return ctx.resolveExprType(last.stmtExpr)
    return makeVoid()
  of ekBorrow:
    return ctx.resolveExprType(expr.exprBorrowOperand)
  else: return makeUnknown()

proc extractGenericStructInfo(ctx: LowerCtx, te: TypeExpr): tuple[baseName: string, typeArgs: seq[TypeExpr]] =
  if te == nil: return ("", @[])
  var baseTe = te
  if baseTe.kind in {tekOwn, tekPointer}:
    baseTe = baseTe.pointerPointee
  if baseTe.kind == tekNamed and baseTe.typeArgs.len > 0 and ctx.genericStructs.hasKey(baseTe.typeName):
    return (baseTe.typeName, baseTe.typeArgs)
  return ("", @[])

proc getReceiverTypeExpr(ctx: LowerCtx, expr: Expr): TypeExpr =
  case expr.kind
  of ekIdent:
    if ctx.varTypeExprs.hasKey(expr.exprIdent):
      return ctx.varTypeExprs[expr.exprIdent]
  of ekField:
    # For chained field access, try to resolve from the outer object
    # This is limited but covers common cases
    discard
  of ekStructInit:
    return TypeExpr(kind: tekNamed, loc: expr.loc, typeName: expr.exprStructInitName,
                    typeArgs: expr.exprStructInitTypeArgs)
  else: discard
  return nil

proc generateMethodInstance(ctx: var LowerCtx, baseMethodName: string, typeArgs: seq[TypeExpr]): string

proc lowerExprWithDynRefCoerce(ctx: var LowerCtx, arg: Expr, expectedType: Type): HirNode =
  ## Lower an expression, coercing &Concrete to &dyn Trait if needed.
  let lowered = ctx.lowerExpr(arg)
  if expectedType != nil and expectedType.isDynRef and arg.kind == ekUnary and arg.exprUnaryOp == tkAmp:
    let concreteType = ctx.resolveExprType(arg.exprUnaryOperand)
    var concreteName = ""
    if concreteType.kind == tkNamed:
      concreteName = concreteType.name
    elif concreteType.isPointer and concreteType.inner.len > 0 and concreteType.inner[0].kind == tkNamed:
      concreteName = concreteType.inner[0].name
    if concreteName != "":
      return hirDynRef(lowered, expectedType.name, concreteName, arg.loc)
  return lowered

proc lowerCallArgs(ctx: var LowerCtx, calleeExpr: Expr, argExprs: seq[Expr]): seq[HirNode] =
  ## Lower call arguments with &Concrete -> &dyn Trait coercion.
  var paramTypes: seq[Type] = @[]
  let calleeType = ctx.resolveExprType(calleeExpr)
  if calleeType.kind == tkFunc and calleeType.inner.len > 1:
    paramTypes = calleeType.inner[0..^2]
  for i, arg in argExprs:
    let expected = if i < paramTypes.len: paramTypes[i] else: nil
    result.add(ctx.lowerExprWithDynRefCoerce(arg, expected))

proc findMethodEntry(ctx: LowerCtx, typeName: string): (string, seq[MethodInfo]) =
  if ctx.methodTable.hasKey(typeName):
    return (typeName, ctx.methodTable[typeName])
  for i in countdown(typeName.len - 1, 1):
    let prefix = typeName[0..<i]
    if ctx.methodTable.hasKey(prefix):
      return (prefix, ctx.methodTable[prefix])
  return ("", @[])

proc operatorMethodName(op: TokenKind): string =
  case op
  of tkPlus: "operator_add"
  of tkMinus: "operator_sub"
  of tkStar: "operator_mul"
  of tkSlash: "operator_div"
  of tkPercent: "operator_mod"
  of tkEq: "operator_eq"
  of tkNe: "operator_ne"
  of tkLt: "operator_lt"
  of tkLe: "operator_le"
  of tkGt: "operator_gt"
  of tkGe: "operator_ge"
  of tkAmp: "operator_bitand"
  of tkPipe: "operator_bitor"
  of tkCaret: "operator_xor"
  of tkShl: "operator_shl"
  of tkShr: "operator_shr"
  else: ""

proc tryLowerOperatorCall(ctx: var LowerCtx, op: TokenKind, leftExpr, rightExpr: Expr, typ: Type, loc: SourceLocation): HirNode =
  ## Try to lower a binary operator to a method call. Returns nil if no overload found.
  let methodName = operatorMethodName(op)
  if methodName == "": return nil
  let receiverType = ctx.resolveExprType(leftExpr)
  var receiverTypeName = ""
  if receiverType.kind == tkNamed:
    receiverTypeName = receiverType.name
    if ctx.typeSubst.hasKey(receiverTypeName):
      let substituted = ctx.typeSubst[receiverTypeName]
      if substituted.kind == tkNamed:
        receiverTypeName = substituted.name
      elif substituted.isPointer and substituted.inner.len > 0 and substituted.inner[0].kind == tkNamed:
        receiverTypeName = substituted.inner[0].name
  elif receiverType.kind in {tkInt, tkInt8, tkInt16, tkInt32, tkInt64,
                             tkUInt, tkUInt8, tkUInt16, tkUInt32, tkUInt64,
                             tkFloat32, tkFloat64, tkBool, tkStr, tkChar8}:
    receiverTypeName = receiverType.toString
  elif receiverType.isPointer and receiverType.inner.len > 0 and receiverType.inner[0].kind == tkNamed:
    receiverTypeName = receiverType.inner[0].name
  let (typeName, methods) = ctx.findMethodEntry(receiverTypeName)
  if typeName == "": return nil
  for minfo in methods:
    if minfo.name == methodName:
      var calleeName = typeName & "_" & methodName
      # Check generic method instantiation
      let recvTypeExpr = ctx.getReceiverTypeExpr(leftExpr)
      let (baseName, typeArgs) = ctx.extractGenericStructInfo(recvTypeExpr)
      if baseName != "" and baseName == typeName and minfo.decl.declFuncTypeParams.len > 0:
        calleeName = ctx.generateMethodInstance(calleeName, typeArgs)
      var args: seq[HirNode] = @[]
      let loweredReceiver = ctx.lowerExpr(leftExpr)
      if minfo.params.len > 0 and minfo.params[0].isPointer and not receiverType.isPointer:
        args.add(hirUnary(tkAmp, loweredReceiver, makePointer(receiverType), loc))
      else:
        args.add(loweredReceiver)
      args.add(ctx.lowerExpr(rightExpr))
      return hirCall(calleeName, args, typ, loc)
  return nil

proc tryLowerIndexCall(ctx: var LowerCtx, objExpr, idxExpr: Expr, typ: Type, loc: SourceLocation): HirNode =
  ## Try to lower arr[i] to operator_index_get(arr, i). Returns nil if no overload found.
  let receiverType = ctx.resolveExprType(objExpr)
  var receiverTypeName = ""
  if receiverType.kind == tkNamed:
    receiverTypeName = receiverType.name
    if ctx.typeSubst.hasKey(receiverTypeName):
      let substituted = ctx.typeSubst[receiverTypeName]
      if substituted.kind == tkNamed:
        receiverTypeName = substituted.name
      elif substituted.isPointer and substituted.inner.len > 0 and substituted.inner[0].kind == tkNamed:
        receiverTypeName = substituted.inner[0].name
  elif receiverType.kind in {tkInt, tkInt8, tkInt16, tkInt32, tkInt64,
                             tkUInt, tkUInt8, tkUInt16, tkUInt32, tkUInt64,
                             tkFloat32, tkFloat64, tkBool, tkStr, tkChar8}:
    receiverTypeName = receiverType.toString
  elif receiverType.isPointer and receiverType.inner.len > 0 and receiverType.inner[0].kind == tkNamed:
    receiverTypeName = receiverType.inner[0].name
  let (typeName, methods) = ctx.findMethodEntry(receiverTypeName)
  if typeName == "": return nil
  for minfo in methods:
    if minfo.name == "operator_index_get":
      var calleeName = typeName & "_operator_index_get"
      let recvTypeExpr = ctx.getReceiverTypeExpr(objExpr)
      let (baseName, typeArgs) = ctx.extractGenericStructInfo(recvTypeExpr)
      if baseName != "" and baseName == typeName and minfo.decl.declFuncTypeParams.len > 0:
        calleeName = ctx.generateMethodInstance(calleeName, typeArgs)
      var args: seq[HirNode] = @[]
      let loweredReceiver = ctx.lowerExpr(objExpr)
      if minfo.params.len > 0 and minfo.params[0].isPointer and not receiverType.isPointer:
        args.add(hirUnary(tkAmp, loweredReceiver, makePointer(receiverType), loc))
      else:
        args.add(loweredReceiver)
      args.add(ctx.lowerExpr(idxExpr))
      return hirCall(calleeName, args, typ, loc)
  return nil

proc lowerExpr(ctx: var LowerCtx, expr: Expr): HirNode =
  if expr == nil: return nil
  let loc = expr.loc
  let typ = ctx.resolveExprType(expr)

  case expr.kind
  of ekLiteral:
    return hirLit(expr.exprLit, typ, loc)

  of ekIdent:
    let name = expr.exprIdent
    # Capture rewriting: if inside closure and ident is captured
    if ctx.closureDepth > 0 and ctx.currentClosureExpr != nil and ctx.envInstanceName != "":
      let idx = ctx.currentClosureExpr.captureNames.find(name)
      if idx >= 0:
        let capType = if idx < ctx.currentClosureExpr.captureTypeKinds.len: Type(kind: TypeKind(ctx.currentClosureExpr.captureTypeKinds[idx])) else: makeInt()
        let base = hirVar(ctx.envInstanceName, makeNamed(""), loc)
        return HirNode(kind: hFieldAccess, fieldAccessName: name, fieldAccessBase: base, typ: capType, loc: loc)
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
    case expr.exprBinaryOp
    of tkAmpAmp:
      # Short-circuit &&: use if-then-else to avoid evaluating right when left is false
      let tmp = hirAlloca("__and_tmp_" & $ctx.varCounter, makeBool(), loc)
      inc ctx.varCounter
      let left = ctx.lowerExpr(expr.exprBinaryLeft)
      let thenBlock = hirBlock(@[hirStore(tmp, ctx.lowerExpr(expr.exprBinaryRight), loc)], nil, makeVoid(), loc)
      let falseTok = Token(kind: tkBoolLiteral, text: "false", loc: loc)
      let elseBlock = hirBlock(@[hirStore(tmp, hirLit(falseTok, makeBool(), loc), loc)], nil, makeVoid(), loc)
      let ifNode = hirIf(left, thenBlock, elseBlock, loc)
      return hirBlock(@[tmp, ifNode], hirLoad(tmp, makeBool(), loc), makeBool(), loc)
    of tkPipePipe:
      # Short-circuit ||: use if-then-else to avoid evaluating right when left is true
      let tmp = hirAlloca("__or_tmp_" & $ctx.varCounter, makeBool(), loc)
      inc ctx.varCounter
      let left = ctx.lowerExpr(expr.exprBinaryLeft)
      let trueTok = Token(kind: tkBoolLiteral, text: "true", loc: loc)
      let thenBlock = hirBlock(@[hirStore(tmp, hirLit(trueTok, makeBool(), loc), loc)], nil, makeVoid(), loc)
      let elseBlock = hirBlock(@[hirStore(tmp, ctx.lowerExpr(expr.exprBinaryRight), loc)], nil, makeVoid(), loc)
      let ifNode = hirIf(left, thenBlock, elseBlock, loc)
      return hirBlock(@[tmp, ifNode], hirLoad(tmp, makeBool(), loc), makeBool(), loc)
    else:
      let lowered = ctx.tryLowerOperatorCall(expr.exprBinaryOp, expr.exprBinaryLeft, expr.exprBinaryRight, typ, loc)
      if lowered != nil:
        return lowered
      let left = ctx.lowerExpr(expr.exprBinaryLeft)
      let right = ctx.lowerExpr(expr.exprBinaryRight)
      return hirBinary(expr.exprBinaryOp, left, right, typ, loc)

  of ekCall:
    # Method call desugaring: obj.method(args) → Type_method(obj, args)
    if expr.exprCallCallee.kind == ekField:
      let methodName = expr.exprCallCallee.exprFieldName
      let receiverExpr = expr.exprCallCallee.exprFieldObj
      let receiverType = ctx.resolveExprType(receiverExpr)
      var receiverTypeName = ""
      if receiverType.kind == tkNamed:
        receiverTypeName = receiverType.name
        if ctx.typeSubst.hasKey(receiverTypeName):
          let substituted = ctx.typeSubst[receiverTypeName]
          if substituted.kind == tkNamed:
            receiverTypeName = substituted.name
          elif substituted.isPointer and substituted.inner.len > 0 and substituted.inner[0].kind == tkNamed:
            receiverTypeName = substituted.inner[0].name
      elif receiverType.kind in {tkInt, tkInt8, tkInt16, tkInt32, tkInt64,
                                 tkUInt, tkUInt8, tkUInt16, tkUInt32, tkUInt64,
                                 tkFloat32, tkFloat64, tkBool, tkStr, tkChar8}:
        receiverTypeName = receiverType.toString
      elif receiverType.isPointer and receiverType.inner.len > 0 and receiverType.inner[0].kind == tkNamed:
        receiverTypeName = receiverType.inner[0].name

      # Look up method for receiver type specifically
      let (typeName, methods) = ctx.findMethodEntry(receiverTypeName)
      if typeName != "":
        for minfo in methods:
          if minfo.name == methodName:
            var calleeName = typeName & "_" & methodName
            # Check if this is a generic method on a generic struct instance
            let recvTypeExpr = ctx.getReceiverTypeExpr(receiverExpr)
            let (baseName, typeArgs) = ctx.extractGenericStructInfo(recvTypeExpr)
            if baseName != "" and baseName == typeName and minfo.decl.declFuncTypeParams.len > 0:
              calleeName = ctx.generateMethodInstance(calleeName, typeArgs)
            var args: seq[HirNode] = @[]
            let loweredReceiver = ctx.lowerExpr(receiverExpr)
            # Auto-address if method expects pointer but receiver is value
            if minfo.params.len > 0 and minfo.params[0].isPointer and not receiverType.isPointer:
              args.add(hirUnary(tkAmp, loweredReceiver, makePointer(receiverType), loc))
            else:
              args.add(loweredReceiver)
            let extraArgs = ctx.lowerCallArgs(expr.exprCallCallee, expr.exprCallArgs)
            for a in extraArgs:
              args.add(a)
            return hirCall(calleeName, args, typ, loc)

      # Trait object virtual dispatch: &dyn Trait -> method()
      if receiverType.kind == tkDynRef:
        let loweredReceiver = ctx.lowerExpr(receiverExpr)
        var args: seq[HirNode] = @[]
        args.add(loweredReceiver)
        let extraArgs = ctx.lowerCallArgs(expr.exprCallCallee, expr.exprCallArgs)
        for a in extraArgs:
          args.add(a)
        return hirDynCall(loweredReceiver, methodName, args, typ, loc)

      # Not a method call - treat as field access + call (function pointer)
      let callee = ctx.lowerExpr(expr.exprCallCallee)
      let args = ctx.lowerCallArgs(expr.exprCallCallee, expr.exprCallArgs)
      return HirNode(kind: hCallIndirect, callIndirectCallee: callee,
                     callIndirectArgs: args, typ: typ, loc: loc)

    # Generic function call: Max<int>(10, 20) → Max_int(10, 20)
    if expr.exprCallCallee.kind == ekGenericCall:
      let baseName = expr.exprCallCallee.exprGenericCallee
      let mangledName = ctx.generateMethodInstance(baseName, expr.exprCallCallee.exprGenericTypeArgs)
      let args = ctx.lowerCallArgs(expr.exprCallCallee, expr.exprCallArgs)
      return hirCall(mangledName, args, typ, loc)

    # Inferred generic function call: Max(10, 20) → Max_int(10, 20)
    if expr.exprCallInferredTypeArgs.len > 0:
      var calleeName = ""
      case expr.exprCallCallee.kind
      of ekIdent:
        calleeName = expr.exprCallCallee.exprIdent
        if ctx.importTable.hasKey(calleeName):
          calleeName = ctx.importTable[calleeName]
      of ekPath:
        calleeName = expr.exprCallCallee.exprPath.join("_")
      else: discard
      if calleeName != "":
        let mangledName = ctx.generateMethodInstance(calleeName, expr.exprCallInferredTypeArgs)
        let args = ctx.lowerCallArgs(expr.exprCallCallee, expr.exprCallArgs)
        return hirCall(mangledName, args, typ, loc)

    # Regular function call
    var calleeName = ""
    if expr.exprCallCallee.kind == ekIdent:
      calleeName = expr.exprCallCallee.exprIdent
      if ctx.importTable.hasKey(calleeName):
        calleeName = ctx.importTable[calleeName]
    elif expr.exprCallCallee.kind == ekPath:
      calleeName = expr.exprCallCallee.exprPath.join("_")
    let args = ctx.lowerCallArgs(expr.exprCallCallee, expr.exprCallArgs)
    if calleeName != "":
      return hirCall(calleeName, args, typ, loc)
    else:
      let callee = ctx.lowerExpr(expr.exprCallCallee)
      return HirNode(kind: hCallIndirect, callIndirectCallee: callee,
                     callIndirectArgs: args, typ: typ, loc: loc)

  of ekField:
    let objType = ctx.resolveExprType(expr.exprFieldObj)
    let base = ctx.lowerExpr(expr.exprFieldObj)
    # Simple enum .tag is the enum value itself
    if objType.kind == tkNamed and expr.exprFieldName == "tag":
      let sym = ctx.globalScope.lookup(objType.name)
      if sym != nil and sym.decl != nil and sym.decl.kind == dkEnum:
        var hasData = false
        for v in sym.decl.declEnumVariants:
          if v.fields.len > 0 or v.namedFields.len > 0:
            hasData = true
            break
        if not hasData:
          return base
    # Auto-dereference pointer types for field access
    if objType.isPointer:
      let arrowPtr = HirNode(kind: hArrowField, arrowFieldBase: base,
                             arrowFieldName: expr.exprFieldName,
                             typ: makePointer(typ), loc: loc)
      return HirNode(kind: hLoad, loadPtr: arrowPtr, typ: typ, loc: loc)
    let basePtr = HirNode(kind: hFieldPtr, fieldPtrBase: base,
                          fieldName: expr.exprFieldName,
                          typ: makePointer(typ), loc: loc)
    return HirNode(kind: hLoad, loadPtr: basePtr, typ: typ, loc: loc)

  of ekIndex:
    let baseType = ctx.resolveExprType(expr.exprIndexObj)
    if not baseType.isSlice:
      let lowered = ctx.tryLowerIndexCall(expr.exprIndexObj, expr.exprIndexIdx, typ, loc)
      if lowered != nil:
        return lowered
    let base = ctx.lowerExpr(expr.exprIndexObj)
    let idx = ctx.lowerExpr(expr.exprIndexIdx)
    if baseType.isSlice:
      let sliceIdx = HirNode(kind: hSliceIndex, sliceIndexBase: base,
                             sliceIndexIndex: idx,
                             sliceIndexBoundsCheck: expr.exprIndexBoundsCheck,
                             typ: typ, loc: loc)
      return sliceIdx
    let basePtr = HirNode(kind: hIndexPtr, indexPtrBase: base,
                          indexPtrIndex: idx, typ: makePointer(typ), loc: loc)
    return HirNode(kind: hLoad, loadPtr: basePtr, typ: typ, loc: loc)

  of ekAssign:
    # Check for operator_index_set overload
    if expr.exprAssignTarget.kind == ekIndex:
      let objExpr = expr.exprAssignTarget.exprIndexObj
      let idxExpr = expr.exprAssignTarget.exprIndexIdx
      let receiverType = ctx.resolveExprType(objExpr)
      var receiverTypeName = ""
      if receiverType.kind == tkNamed:
        receiverTypeName = receiverType.name
        if ctx.typeSubst.hasKey(receiverTypeName):
          let substituted = ctx.typeSubst[receiverTypeName]
          if substituted.kind == tkNamed:
            receiverTypeName = substituted.name
          elif substituted.isPointer and substituted.inner.len > 0 and substituted.inner[0].kind == tkNamed:
            receiverTypeName = substituted.inner[0].name
      elif receiverType.kind in {tkInt, tkInt8, tkInt16, tkInt32, tkInt64,
                                 tkUInt, tkUInt8, tkUInt16, tkUInt32, tkUInt64,
                                 tkFloat32, tkFloat64, tkBool, tkStr, tkChar8}:
        receiverTypeName = receiverType.toString
      elif receiverType.isPointer and receiverType.inner.len > 0 and receiverType.inner[0].kind == tkNamed:
        receiverTypeName = receiverType.inner[0].name
      let (typeName, methods) = ctx.findMethodEntry(receiverTypeName)
      if typeName != "":
        for minfo in methods:
          if minfo.name == "operator_index_set":
            var calleeName = typeName & "_operator_index_set"
            let recvTypeExpr = ctx.getReceiverTypeExpr(objExpr)
            let (baseName, typeArgs) = ctx.extractGenericStructInfo(recvTypeExpr)
            if baseName != "" and baseName == typeName and minfo.decl.declFuncTypeParams.len > 0:
              calleeName = ctx.generateMethodInstance(calleeName, typeArgs)
            var args: seq[HirNode] = @[]
            let loweredReceiver = ctx.lowerExpr(objExpr)
            if minfo.params.len > 0 and minfo.params[0].isPointer and not receiverType.isPointer:
              args.add(hirUnary(tkAmp, loweredReceiver, makePointer(receiverType), loc))
            else:
              args.add(loweredReceiver)
            args.add(ctx.lowerExpr(idxExpr))
            args.add(ctx.lowerExpr(expr.exprAssignValue))
            return hirCall(calleeName, args, makeVoid(), loc)
    let target = ctx.lowerExpr(expr.exprAssignTarget)
    let value = ctx.lowerExpr(expr.exprAssignValue)
    return HirNode(kind: hAssign, assignOp: expr.exprAssignOp,
                   assignTarget: target, assignValue: value,
                   typ: makeVoid(), loc: loc)

  of ekStructInit:
    var structName = expr.exprStructInitName
    if expr.exprStructInitTypeArgs.len > 0:
      var suffix = ""
      for i, targ in expr.exprStructInitTypeArgs:
        if i > 0: suffix.add("_")
        let argType = ctx.resolveTypeExpr(targ)
        suffix.add(argType.toString)
      structName = structName & "_" & suffix
    # Simple enum init: EnumName { tag: EnumName_Variant } -> EnumName_Variant
    var enumDecl: Decl = nil
    let enumSym = ctx.globalScope.lookup(structName)
    if enumSym != nil and enumSym.decl != nil and enumSym.decl.kind == dkEnum:
      enumDecl = enumSym.decl
    var isSimple = false
    if enumDecl != nil:
      for v in enumDecl.declEnumVariants:
        if v.fields.len > 0 or v.namedFields.len > 0:
          isSimple = true
          break
      isSimple = not isSimple
    if isSimple and expr.exprStructInitFields.len == 1 and expr.exprStructInitFields[0].name == "tag":
      let variantExpr = ctx.lowerExpr(expr.exprStructInitFields[0].value)
      return variantExpr
    var fields: seq[tuple[name: string, value: HirNode]] = @[]
    for f in expr.exprStructInitFields:
      fields.add((f.name, ctx.lowerExpr(f.value)))
    return HirNode(kind: hStructInit, structInitName: structName,
                   structInitFields: fields, typ: typ, loc: loc)

  of ekSlice:
    var elems: seq[HirNode] = @[]
    for e in expr.exprSliceElements:
      elems.add(ctx.lowerExpr(e))
    return HirNode(kind: hSliceInit, sliceInitElements: elems,
                   sliceInitLen: elems.len, typ: typ, loc: loc)

  of ekRange:
    let lo = ctx.lowerExpr(expr.exprRangeLo)
    let hi = ctx.lowerExpr(expr.exprRangeHi)
    return HirNode(kind: hRange, rangeLo: lo, rangeHi: hi,
                   rangeInclusive: expr.exprRangeInclusive, typ: typ, loc: loc)

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

  of ekTry:
    let operand = ctx.lowerExpr(expr.exprTryOperand)
    let operandType = ctx.resolveExprType(expr.exprTryOperand)

    var typeName = ""
    var errTag = ""
    var okField = ""
    if operandType.kind == tkNamed:
      typeName = operandType.name
      case typeName
      of "Result":
        errTag = "Result_Err"
        okField = "Ok_0"
      of "Option":
        errTag = "Option_None"
        okField = "Some_0"
      else:
        errTag = typeName & "_Err"
        okField = "Ok_0"
    else:
      errTag = "Result_Err"
      okField = "Ok_0"
      typeName = "Result"

    let tmpName = ctx.freshTryVar()
    let tmpAlloca = hirAlloca(tmpName, operandType, loc)
    let tmpVar = hirVar(tmpName, operandType, loc)
    let tmpStore = hirStore(tmpVar, operand, loc)

    let tagPtr = HirNode(kind: hFieldPtr, fieldPtrBase: tmpVar, fieldName: "tag",
                         typ: makePointer(makeNamed(typeName & "_Tag")), loc: loc)
    let tagLoad = HirNode(kind: hLoad, loadPtr: tagPtr,
                          typ: makeNamed(typeName & "_Tag"), loc: loc)
    let errConst = hirVar(errTag, makeNamed(typeName & "_Tag"), loc)
    let cond = hirBinary(tkEq, tagLoad, errConst, makeBool(), loc)

    let retNode = hirReturn(tmpVar, loc)
    let thenBlock = hirBlock(@[retNode], nil, makeVoid(), loc)
    let ifNode = HirNode(kind: hIf, ifCond: cond, ifThen: thenBlock,
                         ifElse: nil, typ: makeVoid(), loc: loc)

    let dataPtr = HirNode(kind: hFieldPtr, fieldPtrBase: tmpVar, fieldName: "data",
                          typ: makePointer(makeNamed(typeName & "_Data")), loc: loc)
    let dataLoad = HirNode(kind: hLoad, loadPtr: dataPtr,
                           typ: makeNamed(typeName & "_Data"), loc: loc)
    let okPtr = HirNode(kind: hFieldPtr, fieldPtrBase: dataLoad, fieldName: okField,
                        typ: makePointer(makeInt()), loc: loc)
    let okLoad = HirNode(kind: hLoad, loadPtr: okPtr, typ: makeInt(), loc: loc)

    ctx.pendingStmts.add(tmpAlloca)
    ctx.pendingStmts.add(tmpStore)
    ctx.pendingStmts.add(ifNode)
    return okLoad

  of ekUnwrap:
    let operand = ctx.lowerExpr(expr.exprUnwrapOperand)
    let operandType = ctx.resolveExprType(expr.exprUnwrapOperand)

    var errTag = "Result_Err"
    var typeName = "Result"
    if operandType.kind == tkNamed:
      typeName = operandType.name
      if typeName == "Option":
        errTag = "Option_None"

    let tmpName = ctx.freshTryVar()
    let tmpAlloca = hirAlloca(tmpName, operandType, loc)
    let tmpVar = hirVar(tmpName, makePointer(operandType), loc)
    let tmpStore = hirStore(tmpVar, operand, loc)

    let tagPtr = HirNode(kind: hFieldPtr, fieldPtrBase: tmpVar, fieldName: "tag",
                          typ: makePointer(makeNamed(typeName & "_Tag")), loc: loc)
    let tagLoad = HirNode(kind: hLoad, loadPtr: tagPtr,
                           typ: makeNamed(typeName & "_Tag"), loc: loc)
    let errConst = hirVar(errTag, makeNamed(typeName & "_Tag"), loc)
    let cond = hirBinary(tkEq, tagLoad, errConst, makeBool(), loc)

    # On error: call bux_panic("unwrap failed")
    let panicTok = Token(kind: tkStringLiteral, text: "\"unwrap failed\"", loc: loc)
    let panicMsg = HirNode(kind: hLit, litToken: panicTok, typ: makeStr(), loc: loc)
    let panicCall = hirCall("bux_panic", @[panicMsg], makeVoid(), loc)
    let thenBlock = hirBlock(@[panicCall], nil, makeVoid(), loc)
    let ifNode = HirNode(kind: hIf, ifCond: cond, ifThen: thenBlock,
                          ifElse: nil, typ: makeVoid(), loc: loc)

    # Extract the Ok/Some value
    let dataPtr = HirNode(kind: hFieldPtr, fieldPtrBase: tmpVar, fieldName: "data",
                           typ: makePointer(makeNamed(typeName & "_Data")), loc: loc)
    let dataLoad = HirNode(kind: hLoad, loadPtr: dataPtr,
                            typ: makeNamed(typeName & "_Data"), loc: loc)
    let okPtr = HirNode(kind: hFieldPtr, fieldPtrBase: dataLoad, fieldName: "Ok_0",
                         typ: makePointer(makeInt()), loc: loc)
    let okLoad = HirNode(kind: hLoad, loadPtr: okPtr, typ: makeInt(), loc: loc)

    ctx.pendingStmts.add(tmpAlloca)
    ctx.pendingStmts.add(tmpStore)
    ctx.pendingStmts.add(ifNode)
    return okLoad

  of ekMatch:
    let subject = ctx.lowerExpr(expr.exprMatchSubject)
    var arms: seq[HirMatchArm] = @[]
    for arm in expr.exprMatchArms:
      arms.add(HirMatchArm(pattern: arm.pattern, body: ctx.lowerExpr(arm.body)))
    return lowerMatch(ctx, subject, arms, typ, loc)

  of ekSizeOf:
    let ty = ctx.resolveTypeExpr(expr.exprSizeOfType)
    return HirNode(kind: hSizeOf, sizeOfType: ty, typ: makeInt(), loc: loc)

  of ekIntrinsic:
    return HirNode(kind: hLit, litToken: Token(kind: tkStringLiteral, text: "\"\"", loc: loc),
                   typ: makeStr(), loc: loc)

  of ekSpawn:
    var calleeName = ""
    if expr.exprSpawnCallee.kind == ekIdent:
      calleeName = expr.exprSpawnCallee.exprIdent
    elif expr.exprSpawnCallee.kind == ekPath:
      calleeName = expr.exprSpawnCallee.exprPath.join("_")
    var args: seq[HirNode] = @[]
    for arg in expr.exprSpawnArgs:
      args.add(ctx.lowerExpr(arg))
    return HirNode(kind: hSpawn, spawnCallee: calleeName, spawnArgs: args,
                   spawnAsync: expr.exprSpawnAsync,
                   typ: makePointer(makeVoid()), loc: loc)

  of ekAwait:
    let lowered = ctx.lowerExpr(expr.exprAwaitOperand)
    return hirCall("bux_async_await", @[lowered], makePointer(makeVoid()), loc)

  of ekBorrow:
    # borrow &mut expr — lowered to the operand directly (borrow is a no-op in HIR)
    # The borrow checker validates before lowering
    return ctx.lowerExpr(expr.exprBorrowOperand)

  of ekStringInterp:
    # Desugar string interpolation to chained String_Concat calls with conversions
    var resultNode: HirNode = nil
    for i in 0 ..< expr.exprInterpExprs.len:
      let textPart = expr.exprInterpTexts[i]
      let exprPart = expr.exprInterpExprs[i]
      # Text literal
      var textNode = HirNode(kind: hLit,
        litToken: Token(kind: tkStringLiteral, text: "\"" & textPart & "\"", loc: loc),
        typ: makeStr(), loc: loc)
      if resultNode == nil:
        resultNode = textNode
      else:
        resultNode = hirCall("String_Concat", @[resultNode, textNode], makeStr(), loc)
      # Expression part with conversion if needed
      let loweredExpr = ctx.lowerExpr(exprPart)
      let exprType = ctx.resolveExprType(exprPart)
      var convertedExpr = loweredExpr
      if exprType.kind == tkInt or exprType.kind == tkInt8 or exprType.kind == tkInt16 or
         exprType.kind == tkInt32 or exprType.kind == tkInt64 or
         exprType.kind == tkUInt or exprType.kind == tkUInt8 or exprType.kind == tkUInt16 or
         exprType.kind == tkUInt32 or exprType.kind == tkUInt64:
        convertedExpr = hirCall("String_FromInt", @[loweredExpr], makeStr(), loc)
      elif exprType.kind == tkFloat32 or exprType.kind == tkFloat64:
        convertedExpr = hirCall("String_FromFloat", @[loweredExpr], makeStr(), loc)
      elif exprType.kind == tkBool:
        convertedExpr = hirCall("String_FromBool", @[loweredExpr], makeStr(), loc)
      elif exprType.kind == tkStr:
        discard  # already a string
      resultNode = hirCall("String_Concat", @[resultNode, convertedExpr], makeStr(), loc)
    # Add final text part
    let lastText = expr.exprInterpTexts[^1]
    var lastTextNode = HirNode(kind: hLit,
      litToken: Token(kind: tkStringLiteral, text: "\"" & lastText & "\"", loc: loc),
      typ: makeStr(), loc: loc)
    if resultNode == nil:
      resultNode = lastTextNode
    else:
      resultNode = hirCall("String_Concat", @[resultNode, lastTextNode], makeStr(), loc)
    return resultNode

  of ekClosure:
    let f = ctx.lowerClosureFunc(expr)
    return hirUnary(tkAmp, hirVar(f.name, makeFunc(@[], makeVoid()), loc), typ, loc)

  else:
    return HirNode(kind: hLit, litToken: Token(kind: tkIntLiteral, text: "0", loc: loc),
                   typ: makeVoid(), loc: loc)

proc lowerStmt(ctx: var LowerCtx, stmt: Stmt): HirNode =
  if stmt == nil: return nil
  let loc = stmt.loc

  case stmt.kind
  of skExpr:
    return ctx.flushPending(ctx.lowerExpr(stmt.stmtExpr))

  of skLet:
    var initHir: HirNode = nil
    if stmt.stmtLetInit != nil:
      initHir = ctx.lowerExpr(stmt.stmtLetInit)
    let allocaType = if stmt.stmtLetType != nil:
      case stmt.stmtLetType.kind
      of tekNamed:
        ctx.resolveTypeExpr(stmt.stmtLetType)
      of tekOwn:
        ctx.resolveTypeExpr(stmt.stmtLetType.pointerPointee)
      of tekPointer:
        let pointeeType = ctx.resolveTypeExpr(stmt.stmtLetType.pointerPointee)
        makePointer(pointeeType)
      of tekSlice:
        let elemType = ctx.resolveTypeExpr(stmt.stmtLetType.sliceElement)
        makeSlice(elemType)
      of tekFunc:
        var params: seq[Type] = @[]
        for p in stmt.stmtLetType.funcParams:
          params.add(ctx.resolveTypeExpr(p))
        let ret = if stmt.stmtLetType.funcRet != nil: ctx.resolveTypeExpr(stmt.stmtLetType.funcRet) else: makeVoid()
        makeFunc(params, ret)
      else: makeUnknown()
    elif stmt.stmtLetInit != nil:
      ctx.resolveExprType(stmt.stmtLetInit)
    else:
      makeUnknown()

    let alloca = hirAlloca(stmt.stmtLetName, allocaType, loc)
    let varNode = hirVar(stmt.stmtLetName, makePointer(allocaType), loc)
    # Track type expr for generic method inference
    if stmt.stmtLetType != nil:
      ctx.varTypeExprs[stmt.stmtLetName] = stmt.stmtLetType
    elif stmt.stmtLetInit != nil and stmt.stmtLetInit.kind == ekStructInit:
      ctx.varTypeExprs[stmt.stmtLetName] = TypeExpr(
        kind: tekNamed,
        loc: stmt.stmtLetInit.loc,
        typeName: stmt.stmtLetInit.exprStructInitName,
        typeArgs: stmt.stmtLetInit.exprStructInitTypeArgs
      )
    var stmts = ctx.pendingStmts
    ctx.pendingStmts = @[]
    stmts.add(alloca)
    if initHir != nil:
      let store = hirStore(varNode, initHir, loc)
      stmts.add(store)
    # If init is a closure with captures, emit capture assignments
    if stmt.stmtLetInit != nil and stmt.stmtLetInit.kind == ekClosure and stmt.stmtLetInit.captureCount > 0:
      let closureIdx = ctx.varCounter - 1
      let envInst = "__closure_env_instance_" & $closureIdx
      var capStmts: seq[HirNode] = @[]
      for i in 0 ..< stmt.stmtLetInit.captureCount:
        let capName = stmt.stmtLetInit.captureNames[i]
        let capType = if i < stmt.stmtLetInit.captureTypeKinds.len: Type(kind: TypeKind(stmt.stmtLetInit.captureTypeKinds[i])) else: makeInt()
        let base = hirVar(envInst, makeNamed(""), loc)
        let field = HirNode(kind: hFieldAccess, fieldAccessName: capName, fieldAccessBase: base, typ: capType, loc: loc)
        let val = hirVar(capName, capType, loc)
        capStmts.add(hirAssign(field, val, loc))
      # Prepend capture assignments before the let
      var allStmts = capStmts
      allStmts.add(stmts)
      return hirBlock(allStmts, nil, makeVoid(), loc)
    return hirBlock(stmts, nil, makeVoid(), loc)

  of skReturn:
    let value = if stmt.stmtReturnValue != nil: ctx.lowerExpr(stmt.stmtReturnValue) else: nil
    var stmts = ctx.pendingStmts
    ctx.pendingStmts = @[]
    # Add defers in reverse order (LIFO)
    for i in countdown(ctx.deferStmts.len - 1, 0):
      stmts.add(ctx.deferStmts[i])
    stmts.add(hirReturn(value, loc))
    return hirBlock(stmts, nil, makeVoid(), loc)

  of skIf:
    let cond = ctx.lowerExpr(stmt.stmtIfCond)
    let thenBlock = ctx.lowerBlock(stmt.stmtIfThen)
    var elseBlock: HirNode = nil
    if stmt.stmtIfElseIfs.len > 0:
      # Desugar else-if chain, attaching else block if present
      var current: HirNode = nil
      if stmt.stmtIfElse != nil:
        current = ctx.lowerBlock(stmt.stmtIfElse)
      for i in countdown(stmt.stmtIfElseIfs.len - 1, 0):
        let elifBranch = stmt.stmtIfElseIfs[i]
        let elifCond = ctx.lowerExpr(elifBranch.cond)
        let elifBlock = ctx.lowerBlock(elifBranch.blk)
        current = HirNode(kind: hIf, ifCond: elifCond, ifThen: elifBlock,
                         ifElse: current, typ: makeVoid(), loc: elifBranch.loc)
      elseBlock = current
    elif stmt.stmtIfElse != nil:
      elseBlock = ctx.lowerBlock(stmt.stmtIfElse)
    return ctx.flushPending(HirNode(kind: hIf, ifCond: cond, ifThen: thenBlock, ifElse: elseBlock,
                   typ: makeVoid(), loc: loc))

  of skWhile:
    let cond = ctx.lowerExpr(stmt.stmtWhileCond)
    let body = ctx.lowerBlock(stmt.stmtWhileBody)
    return ctx.flushPending(HirNode(kind: hWhile, whileCond: cond, whileBody: body,
                   typ: makeVoid(), loc: loc))

  of skLoop:
    let body = ctx.lowerBlock(stmt.stmtLoopBody)
    return ctx.flushPending(HirNode(kind: hLoop, loopBody: body, typ: makeVoid(), loc: loc))

  of skBreak:
    return ctx.flushPending(HirNode(kind: hBreak, breakLabel: stmt.stmtBreakLabel,
                   typ: makeVoid(), loc: loc))

  of skStaticAssert, skComptime:
    # Compile-time only: evaluated in sema, no runtime code
    return nil

  of skEmit:
    if stmt.stmtEmitEvaluated.len > 0:
      return hirEmit(stmt.stmtEmitEvaluated, loc)
    return nil

  of skContinue:
    return ctx.flushPending(HirNode(kind: hContinue, continueLabel: stmt.stmtContinueLabel,
                   typ: makeVoid(), loc: loc))

  of skFor:
    let iterExpr = stmt.stmtForIter
    let body = stmt.stmtForBody
    let varName = stmt.stmtForVar
    let loc = stmt.loc
    
    # Range-based for: for i in lo..hi { body }
    if iterExpr.kind == ekRange:
      let lo = ctx.lowerExpr(iterExpr.exprRangeLo)
      let hi = ctx.lowerExpr(iterExpr.exprRangeHi)
      let inclusive = iterExpr.exprRangeInclusive
      
      # Determine loop variable type from range bounds
      let varType = ctx.resolveExprType(iterExpr.exprRangeLo)
      
      # Create: var i = lo; while i < hi { body; i = i + 1; }
      let initStmt = hirAlloca(varName, varType, loc)
      let varNode = hirVar(varName, makePointer(varType), loc)
      let initStore = hirStore(varNode, lo, loc)
      
      let readI = hirVar(varName, varType, loc)
      let condOp = if inclusive: tkLe else: tkLt
      let cond = HirNode(kind: hBinary, binaryOp: condOp,
                         binaryLeft: readI, binaryRight: hi,
                         typ: makeBool(), loc: loc)
      
      var bodyStmts: seq[HirNode] = @[]
      bodyStmts.add(ctx.lowerBlock(body))
      
      let readI2 = hirVar(varName, varType, loc)
      let one = hirLit(Token(kind: tkIntLiteral, text: "1", loc: loc), varType, loc)
      let inc = HirNode(kind: hBinary, binaryOp: tkPlus,
                        binaryLeft: readI2, binaryRight: one,
                        typ: varType, loc: loc)
      bodyStmts.add(hirStore(varNode, inc, loc))
      
      let whileBody = hirBlock(bodyStmts, nil, makeVoid(), loc)
      let whileNode = HirNode(kind: hWhile, whileCond: cond, whileBody: whileBody,
                             typ: makeVoid(), loc: loc)
      
      # Wrap in a block so loop variable doesn't leak into outer scope
      let forBlock = hirBlock(@[initStmt, initStore, whileNode], nil, makeVoid(), loc, isScope = true)
      return ctx.flushPending(forBlock)
    
    # Generic iterator for loop (simplified - just infinite loop for now)
    let loweredIter = ctx.lowerExpr(iterExpr)
    let loweredBody = ctx.lowerBlock(body)
    return ctx.flushPending(HirNode(kind: hLoop, loopBody: loweredBody, typ: makeVoid(), loc: loc))

  of skDoWhile:
    let body = ctx.lowerBlock(stmt.stmtDoWhileBody)
    let cond = ctx.lowerExpr(stmt.stmtDoWhileCond)
    let whileNode = HirNode(kind: hWhile, whileCond: cond, whileBody: body,
                           typ: makeVoid(), loc: loc)
    return ctx.flushPending(HirNode(kind: hBlock, blockStmts: @[body, whileNode],
                   blockExpr: nil, typ: makeVoid(), loc: loc))

  of skMatch:
    let subject = ctx.lowerExpr(stmt.stmtMatchSubject)
    var arms: seq[HirMatchArm] = @[]
    for arm in stmt.stmtMatchArms:
      arms.add(HirMatchArm(pattern: arm.pattern, body: ctx.lowerExpr(arm.body)))
    return ctx.flushPending(HirNode(kind: hMatch, matchSubject: subject, matchArms: arms,
                   typ: makeVoid(), loc: loc))

  of skSwitch:
    let subject = ctx.lowerExpr(stmt.stmtSwitchExpr)
    var current: HirNode = nil
    # Build if-else chain from bottom up (default first)
    if stmt.stmtSwitchDefault != nil:
      current = ctx.lowerBlock(stmt.stmtSwitchDefault)
    # Cases in reverse order
    for i in countdown(stmt.stmtSwitchCases.len - 1, 0):
      let caseBranch = stmt.stmtSwitchCases[i]
      let caseVal = ctx.lowerExpr(caseBranch.caseValue)
      let caseBody = ctx.lowerBlock(caseBranch.caseBody)
      let cond = HirNode(kind: hBinary, binaryOp: tkEq,
                         binaryLeft: subject, binaryRight: caseVal,
                         typ: makeBool(), loc: caseBranch.loc)
      current = HirNode(kind: hIf, ifCond: cond, ifThen: caseBody, ifElse: current,
                        typ: makeVoid(), loc: caseBranch.loc)
    return ctx.flushPending(current)

  of skDefer:
    let body = ctx.lowerExpr(stmt.stmtDeferBody)
    ctx.deferStmts.add(body)
    return nil

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
  return hirBlock(stmts, expr, if expr != nil: expr.typ else: makeVoid(), blk.loc, isScope = true)

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
      pType = substituteType(ctx, p.ptype, ctx.typeSubst)
    params.add((p.name, pType))

  var retType = makeVoid()
  if funcReturnType != nil:
    retType = substituteType(ctx, funcReturnType, ctx.typeSubst)

  let oldFuncDecl = ctx.currentFuncDecl
  let oldFuncRetType = ctx.currentFuncRetType
  let oldVarTypeExprs = ctx.varTypeExprs
  ctx.currentFuncRetType = retType
  ctx.currentFuncDecl = decl
  ctx.varTypeExprs = initTable[string, TypeExpr]()  # Clear local vars for new function
  # Add parameters to varTypeExprs after clearing so they are visible in the body.
  for p in funcParams:
    if p.ptype != nil:
      ctx.varTypeExprs[p.name] = p.ptype
  var body = if funcBody != nil: ctx.lowerBlock(funcBody) else: nil
  
  # Inject remaining defers at end of function (for implicit return)
  if ctx.deferStmts.len > 0 and body != nil and body.kind == hBlock:
    # Only add if last statement is not already a return (defers already injected there)
    var hasReturn = false
    if body.blockStmts.len > 0 and body.blockStmts[^1].kind == hReturn:
      hasReturn = true
    elif body.blockStmts.len > 0 and body.blockStmts[^1].kind == hBlock:
      # Check nested block's last statement
      let last = body.blockStmts[^1]
      if last.blockStmts.len > 0 and last.blockStmts[^1].kind == hReturn:
        hasReturn = true
    if not hasReturn:
      for i in countdown(ctx.deferStmts.len - 1, 0):
        body.blockStmts.add(ctx.deferStmts[i])
    ctx.deferStmts = @[]
  
  ctx.currentFuncDecl = oldFuncDecl
  ctx.currentFuncRetType = oldFuncRetType
  ctx.varTypeExprs = oldVarTypeExprs

  result = HirFunc(name: funcName, params: params, retType: retType,
                   body: body, isPublic: decl.isPublic)
  
  # Restore old substitution
  ctx.typeSubst = oldSubst

proc generateMethodInstance(ctx: var LowerCtx, baseMethodName: string, typeArgs: seq[TypeExpr]): string =
  if not ctx.genericFuncs.hasKey(baseMethodName):
    return baseMethodName
  let genericDecl = ctx.genericFuncs[baseMethodName]
  if genericDecl.declFuncTypeParams.len == 0:
    return baseMethodName
  var subst = initTable[string, Type]()
  var typeSuffix = ""
  var typeArgIdx = 0
  for i, tp in genericDecl.declFuncTypeParams:
    if tp.isLifetime: continue
    if typeArgIdx > 0: typeSuffix.add("_")
    if typeArgIdx < typeArgs.len:
      let argType = ctx.resolveTypeExpr(typeArgs[typeArgIdx])
      subst[tp.name] = argType
      typeSuffix.add(argType.toString)
    else:
      typeSuffix.add("unknown")
    inc(typeArgIdx)
  let mangledName = baseMethodName & "_" & typeSuffix
  if not ctx.generatedFuncInsts.hasKey(mangledName):
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
    let oldSubst = ctx.typeSubst
    ctx.typeSubst = subst
    ctx.extraFuncs.add(ctx.lowerFunc(specDecl))
    ctx.typeSubst = oldSubst
    ctx.generatedFuncInsts[mangledName] = true
  return mangledName

proc lowerClosureFunc(ctx: var LowerCtx, expr: Expr): HirFunc =
  let loc = expr.loc
  let name = "__closure_" & $ctx.varCounter
  inc ctx.varCounter
  var f = HirFunc(name: name, isPublic: false)
  # Copy capture metadata
  if expr.captureCount > 0:
    f.captureNames = expr.captureNames
    for tk in expr.captureTypeKinds:
      f.captureTypes.add(Type(kind: TypeKind(tk)))
    f.envStructName = "__closure_env_" & $(ctx.varCounter - 1)
    f.envInstanceName = "__closure_env_instance_" & $(ctx.varCounter - 1)
  # Params
  for p in expr.exprClosureParams:
    f.params.add((name: p.name, typ: if p.ptype != nil: ctx.resolveTypeExpr(p.ptype) else: makeUnknown()))
  # Return type
  if expr.exprClosureReturnType != nil:
    f.retType = ctx.resolveTypeExpr(expr.exprClosureReturnType)
  else:
    f.retType = makeVoid()
  # Body with closure rewriting
  let savedDepth = ctx.closureDepth
  let savedExpr = ctx.currentClosureExpr
  let savedEnv = ctx.envInstanceName
  ctx.closureDepth = ctx.closureDepth + 1
  ctx.currentClosureExpr = expr
  ctx.envInstanceName = f.envInstanceName
  if expr.exprClosureBody != nil:
    f.body = ctx.lowerBlock(expr.exprClosureBody)
  ctx.closureDepth = savedDepth
  ctx.currentClosureExpr = savedExpr
  ctx.envInstanceName = savedEnv
  ctx.extraFuncs.add(f)
  return f

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


  # First pass: collect generic functions and generic structs
  for decl in module.items:
    if decl.kind == dkFunc and decl.declFuncTypeParams.len > 0:
      ctx.genericFuncs[decl.declFuncName] = decl
    if decl.kind == dkStruct and decl.declStructTypeParams.len > 0:
      ctx.genericStructs[decl.declStructName] = decl
    if decl.kind == dkImpl and decl.declImplTypeParams.len > 0:
      let typeName = decl.declImplTypeName
      for methodDecl in decl.declImplMethods:
        if methodDecl.kind == dkFunc:
          let mangledName = typeName & "_" & methodDecl.declFuncName
          ctx.genericFuncs[mangledName] = methodDecl

  # Second pass: lower all non-generic functions
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
      # Add associated type substitutions for this impl block
      var oldAssocSubst = initTable[string, Type]()
      for assoc in decl.declImplAssocTypes:
        let resolved = ctx.resolveTypeExpr(assoc.typ)
        if ctx.typeSubst.hasKey(assoc.name):
          oldAssocSubst[assoc.name] = ctx.typeSubst[assoc.name]
        ctx.typeSubst[assoc.name] = resolved
      for methodDecl in decl.declImplMethods:
        if methodDecl.kind == dkFunc:
          # Skip generic methods — they are monomorphized via generateMethodInstance
          if methodDecl.declFuncTypeParams.len > 0:
            continue
          var hf = ctx.lowerFunc(methodDecl)
          hf.name = decl.declImplTypeName & "_" & hf.name
          funcs.add(hf)
      # Restore old substitutions
      for name, typ in oldAssocSubst:
        ctx.typeSubst[name] = typ
      for assoc in decl.declImplAssocTypes:
        if not oldAssocSubst.hasKey(assoc.name):
          ctx.typeSubst.del(assoc.name)
    of dkStruct:
      if decl.declStructTypeParams.len == 0:  # Skip generic structs — monomorphized separately
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

  # Add monomorphized generic structs
  for s in ctx.extraStructs:
    structs.add(s)

  # Add monomorphized generic methods
  for f in ctx.extraFuncs:
    funcs.add(f)

  # Collect interface info for vtable generation
  var ifaceInfos: seq[tuple[name: string, hasAssocTypes: bool, methods: seq[tuple[name: string, params: seq[Type], ret: Type]]]] = @[]
  for ifaceName, ifaceDecl in sema.interfaceTable:
    var methods: seq[tuple[name: string, params: seq[Type], ret: Type]] = @[]
    for m in ifaceDecl.declInterfaceMethods:
      var params: seq[Type] = @[]
      for p in m.declFuncParams:
        params.add(ctx.resolveTypeExpr(p.ptype))
      let ret = if m.declFuncReturnType != nil: ctx.resolveTypeExpr(m.declFuncReturnType) else: makeVoid()
      methods.add((m.declFuncName, params, ret))
    ifaceInfos.add((ifaceName, ifaceDecl.declInterfaceAssocTypes.len > 0, methods))

  # Collect vtable instances: which concrete types implement which interfaces
  var vtableInfos: seq[tuple[interfaceName: string, concreteType: string, methodNames: seq[string], hasAssocTypes: bool]] = @[]
  for ifaceName, ifaceDecl in sema.interfaceTable:
    let requiredMethods = ifaceDecl.declInterfaceMethods
    let hasAssoc = ifaceDecl.declInterfaceAssocTypes.len > 0
    for typeName, methods in sema.methodTable:
      var allFound = true
      var methodNames: seq[string] = @[]
      for req in requiredMethods:
        var found = false
        for avail in methods:
          if avail.name == req.declFuncName:
            # Skip generic methods — they have no concrete C function to put in vtable
            if avail.decl.declFuncTypeParams.len > 0:
              break
            found = true
            methodNames.add(req.declFuncName)
            break
        if not found:
          allFound = false
          break
      if allFound:
        vtableInfos.add((ifaceName, typeName, methodNames, hasAssoc))

  result = HirModule(funcs: funcs, externFuncs: externFuncs, structs: structs, enums: enums, consts: consts, interfaces: ifaceInfos, vtables: vtableInfos)
