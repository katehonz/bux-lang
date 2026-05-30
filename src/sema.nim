import std/[strformat, tables, sequtils, strutils]
import ast, types, scope, source_location, token

type
  SemaDiagnosticSeverity* = enum
    sdsWarning
    sdsError

  SemaDiagnostic* = object
    severity*: SemaDiagnosticSeverity
    loc*: SourceLocation
    message*: string

  SemaResult* = object
    diagnostics*: seq[SemaDiagnostic]

  MethodInfo* = object
    name*: string
    decl*: Decl
    params*: seq[Type]
    retType*: Type

  Sema* = object
    module*: Module
    globalScope*: Scope
    diagnostics*: seq[SemaDiagnostic]
    # Built-in type mapping from name to Type
    typeTable*: Table[string, Type]
    # Type name -> list of methods (from extend blocks)
    methodTable*: Table[string, seq[MethodInfo]]
    # Interface name -> interface decl
    interfaceTable*: Table[string, Decl]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc emitError(sema: var Sema, loc: SourceLocation, message: string) =
  sema.diagnostics.add(SemaDiagnostic(severity: sdsError, loc: loc, message: message))

proc emitWarning(sema: var Sema, loc: SourceLocation, message: string) =
  sema.diagnostics.add(SemaDiagnostic(severity: sdsWarning, loc: loc, message: message))

proc hasErrors*(res: SemaResult): bool =
  for d in res.diagnostics:
    if d.severity == sdsError:
      return true
  return false

# ---------------------------------------------------------------------------
# Type resolution from AST TypeExpr
# ---------------------------------------------------------------------------

proc resolveType(sema: var Sema, te: TypeExpr): Type =
  if te == nil:
    return makeUnknown()
  case te.kind
  of tekNamed:
    let name = te.typeName
    case name
    of "void": return makeVoid()
    of "bool": return makeBool()
    of "bool8": return makeBool8()
    of "bool16": return makeBool16()
    of "bool32": return makeBool32()
    of "char8": return makeChar8()
    of "char16": return makeChar16()
    of "char32": return makeChar32()
    of "String", "str": return makeStr()
    of "int8": return makeInt8()
    of "int16": return makeInt16()
    of "int32": return makeInt32()
    of "int64": return makeInt64()
    of "int": return makeInt()
    of "uint8": return makeUInt8()
    of "uint16": return makeUInt16()
    of "uint32": return makeUInt32()
    of "uint64": return makeUInt64()
    of "uint": return makeUInt()
    of "float32": return makeFloat32()
    of "float64": return makeFloat64()
    of "float": return makeFloat64()
    else:
      if sema.typeTable.hasKey(name):
        return sema.typeTable[name]
      return makeNamed(name)
  of tekPath:
    let fullName = te.pathSegments.join("::")
    return makeNamed(fullName)
  of tekPointer:
    return makePointer(sema.resolveType(te.pointerPointee))
  of tekSlice:
    let elemType = sema.resolveType(te.sliceElement)
    return makeSlice(elemType)
  of tekTuple:
    var elems: seq[Type] = @[]
    for e in te.tupleElements:
      elems.add(sema.resolveType(e))
    return makeTuple(elems)
  of tekSelf:
    return makeNamed("self")

# ---------------------------------------------------------------------------
# First pass: collect global symbols
# ---------------------------------------------------------------------------

proc collectGlobals*(sema: var Sema) =
  for decl in sema.module.items:
    case decl.kind
    of dkFunc:
      let sym = Symbol(kind: skFunc, name: decl.declFuncName, decl: decl,
                       isPublic: decl.isPublic)
      # Build function type from params and return
      var params: seq[Type] = @[]
      for p in decl.declFuncParams:
        params.add(sema.resolveType(p.ptype))
      let retType = if decl.declFuncReturnType != nil: sema.resolveType(decl.declFuncReturnType) else: makeVoid()
      sym.typ = makeFunc(params, retType)
      if not sema.globalScope.define(sym):
        sema.emitError(decl.loc, &"duplicate symbol '{decl.declFuncName}'")
    of dkExternFunc:
      let sym = Symbol(kind: skFunc, name: decl.declExtFuncName, decl: decl,
                       isPublic: decl.isPublic)
      var params: seq[Type] = @[]
      for p in decl.declExtFuncParams:
        params.add(sema.resolveType(p.ptype))
      let retType = if decl.declExtFuncReturnType != nil: sema.resolveType(decl.declExtFuncReturnType) else: makeVoid()
      sym.typ = makeFunc(params, retType)
      if not sema.globalScope.define(sym):
        sema.emitError(decl.loc, &"duplicate symbol '{decl.declExtFuncName}'")
    of dkStruct:
      let t = makeNamed(decl.declStructName)
      let sym = Symbol(kind: skType, name: decl.declStructName, typ: t,
                       decl: decl, isPublic: decl.isPublic)
      if not sema.globalScope.define(sym):
        sema.emitError(decl.loc, &"duplicate symbol '{decl.declStructName}'")
      sema.typeTable[decl.declStructName] = t
    of dkEnum:
      let t = makeNamed(decl.declEnumName)
      let sym = Symbol(kind: skType, name: decl.declEnumName, typ: t,
                       decl: decl, isPublic: decl.isPublic)
      if not sema.globalScope.define(sym):
        sema.emitError(decl.loc, &"duplicate symbol '{decl.declEnumName}'")
      sema.typeTable[decl.declEnumName] = t
      # For algebraic enums, add variant constants with _Tag type
      for variant in decl.declEnumVariants:
        let variantName = decl.declEnumName & "_" & variant.name
        let variantType = makeNamed(decl.declEnumName & "_Tag")
        let variantSym = Symbol(kind: skConst, name: variantName, typ: variantType,
                                decl: decl, isPublic: decl.isPublic)
        discard sema.globalScope.define(variantSym)
    of dkUnion:
      let t = makeNamed(decl.declUnionName)
      let sym = Symbol(kind: skType, name: decl.declUnionName, typ: t,
                       decl: decl, isPublic: decl.isPublic)
      if not sema.globalScope.define(sym):
        sema.emitError(decl.loc, &"duplicate symbol '{decl.declUnionName}'")
      sema.typeTable[decl.declUnionName] = t
    of dkConst:
      let sym = Symbol(kind: skConst, name: decl.declConstName,
                       typ: sema.resolveType(decl.declConstType),
                       decl: decl, isPublic: decl.isPublic)
      if not sema.globalScope.define(sym):
        sema.emitError(decl.loc, &"duplicate symbol '{decl.declConstName}'")
    of dkTypeAlias:
      let t = sema.resolveType(decl.declAliasType)
      let sym = Symbol(kind: skType, name: decl.declAliasName, typ: t,
                       decl: decl, isPublic: decl.isPublic)
      if not sema.globalScope.define(sym):
        sema.emitError(decl.loc, &"duplicate symbol '{decl.declAliasName}'")
      sema.typeTable[decl.declAliasName] = t
    of dkUse:
      # Imports: register imported names into scope
      if decl.declUsePath.len > 0:
        case decl.declUseKind
        of ukMulti:
          for name in decl.declUseNames:
            if sema.globalScope.lookup(name) == nil:
              let sym = Symbol(kind: skFunc, name: name, typ: makeUnknown(), isPublic: true)
              discard sema.globalScope.define(sym)
        of ukGlob:
          let name = decl.declUsePath[^1]
          if sema.globalScope.lookup(name) == nil:
            let sym = Symbol(kind: skModule, name: name, typ: makeUnknown(), isPublic: true)
            discard sema.globalScope.define(sym)
        of ukSingle:
          let name = decl.declUsePath[^1]
          if sema.globalScope.lookup(name) == nil:
            let sym = Symbol(kind: skFunc, name: name, typ: makeUnknown(), isPublic: true)
            discard sema.globalScope.define(sym)
    of dkInterface:
      # Register interface for conformance checking
      sema.interfaceTable[decl.declInterfaceName] = decl
      let t = makeNamed(decl.declInterfaceName)
      let sym = Symbol(kind: skType, name: decl.declInterfaceName, typ: t,
                       decl: decl, isPublic: decl.isPublic)
      if not sema.globalScope.define(sym):
        sema.emitError(decl.loc, &"duplicate symbol '{decl.declInterfaceName}'")
      sema.typeTable[decl.declInterfaceName] = t
    of dkImpl:
      # Register methods for the type
      let typeName = decl.declImplTypeName
      if not sema.methodTable.hasKey(typeName):
        sema.methodTable[typeName] = @[]
      for methodDecl in decl.declImplMethods:
        if methodDecl.kind == dkFunc:
          var params: seq[Type] = @[]
          for p in methodDecl.declFuncParams:
            params.add(sema.resolveType(p.ptype))
          let retType = if methodDecl.declFuncReturnType != nil:
            sema.resolveType(methodDecl.declFuncReturnType)
          else:
            makeVoid()
          let info = MethodInfo(
            name: methodDecl.declFuncName,
            decl: methodDecl,
            params: params,
            retType: retType
          )
          sema.methodTable[typeName].add(info)
          # Also register as a global function: TypeName_MethodName
          let mangledName = typeName & "_" & methodDecl.declFuncName
          let sym = Symbol(kind: skFunc, name: mangledName, decl: methodDecl,
                           isPublic: true)
          sym.typ = makeFunc(params, retType)
          discard sema.globalScope.define(sym)
    else:
      discard

# ---------------------------------------------------------------------------
# Expression type checking
# ---------------------------------------------------------------------------

proc checkExpr(sema: var Sema, expr: Expr, scope: Scope): Type
proc checkStmt(sema: var Sema, stmt: Stmt, scope: Scope): Type

proc extractPatternBindings(sema: var Sema, pat: Pattern, scope: Scope) =
  ## Add pattern-bound identifiers to scope with unknown type (best-effort)
  if pat == nil: return
  case pat.kind
  of pkIdent:
    let sym = Symbol(kind: skVar, name: pat.patIdent, typ: makeUnknown(), isMutable: false)
    discard scope.define(sym)
  of pkEnum:
    for arg in pat.patEnumArgs:
      sema.extractPatternBindings(arg, scope)
    for nf in pat.patEnumNamed:
      sema.extractPatternBindings(nf.pattern, scope)
  of pkTuple:
    for elem in pat.patTupleElements:
      sema.extractPatternBindings(elem, scope)
  of pkStruct:
    for f in pat.patStructFields:
      sema.extractPatternBindings(f.pattern, scope)
  of pkGuarded:
    sema.extractPatternBindings(pat.patGuardedInner, scope)
  else:
    discard

proc checkExprList(sema: var Sema, exprs: seq[Expr], scope: Scope): seq[Type] =
  for e in exprs:
    result.add(sema.checkExpr(e, scope))

proc checkExpr(sema: var Sema, expr: Expr, scope: Scope): Type =
  if expr == nil:
    return makeUnknown()
  case expr.kind
  of ekLiteral:
    case expr.exprLit.kind
    of tkIntLiteral: return makeInt()
    of tkFloatLiteral: return makeFloat64()
    of tkStringLiteral: return makeStr()
    of tkCharLiteral: return makeChar32()
    of tkBoolLiteral: return makeBool()
    of tkNull: return makePointer(makeUnknown())
    else: return makeUnknown()
  of ekIdent:
    let sym = scope.lookup(expr.exprIdent)
    if sym == nil:
      sema.emitError(expr.loc, &"undeclared identifier '{expr.exprIdent}'")
      return makeUnknown()
    if sym.typ == nil:
      return makeUnknown()
    return sym.typ
  of ekSelf:
    return makeNamed("self")
  of ekPath:
    let fullName = expr.exprPath.join("::")
    let sym = scope.lookup(fullName)
    if sym != nil:
      return sym.typ
    # Try looking up the first segment
    let first = scope.lookup(expr.exprPath[0])
    if first == nil:
      sema.emitError(expr.loc, &"undeclared identifier '{expr.exprPath[0]}'")
      return makeUnknown()
    return first.typ
  of ekUnary:
    let operandType = sema.checkExpr(expr.exprUnaryOperand, scope)
    case expr.exprUnaryOp
    of tkBang:
      if not operandType.isBool:
        sema.emitError(expr.loc, "'!' requires bool operand")
      return makeBool()
    of tkMinus, tkTilde:
      if not operandType.isNumeric:
        sema.emitError(expr.loc, "unary '-' requires numeric operand")
      return operandType
    of tkStar:
      if not operandType.isPointer:
        sema.emitError(expr.loc, "dereference requires pointer operand")
        return makeUnknown()
      return operandType.inner[0]
    of tkAmp:
      return makePointer(operandType)
    else:
      return operandType
  of ekPostfix:
    let operandType = sema.checkExpr(expr.exprPostfixOperand, scope)
    case expr.exprPostfixOp
    of tkPlusPlus, tkMinusMinus:
      if not operandType.isNumeric:
        sema.emitError(expr.loc, "increment/decrement requires numeric operand")
      return operandType
    else:
      return operandType
  of ekBinary:
    let left = sema.checkExpr(expr.exprBinaryLeft, scope)
    let right = sema.checkExpr(expr.exprBinaryRight, scope)
    case expr.exprBinaryOp
    of tkPlus, tkMinus, tkStar, tkSlash, tkPercent, tkStarStar:
      if not left.isNumeric or not right.isNumeric:
        sema.emitError(expr.loc, &"arithmetic operator requires numeric operands ({left.toString}, {right.toString})")
        return makeUnknown()
      # Result type is the wider of the two
      if left.isFloat or right.isFloat:
        if left.kind == tkFloat64 or right.kind == tkFloat64:
          return makeFloat64()
        return makeFloat32()
      return left
    of tkAmp, tkPipe, tkCaret, tkShl, tkShr:
      if not left.isInteger or not right.isInteger:
        sema.emitError(expr.loc, "bitwise operator requires integer operands")
      return left
    of tkAmpAmp, tkPipePipe:
      if not left.isBool or not right.isBool:
        sema.emitError(expr.loc, "logical operator requires bool operands")
      return makeBool()
    of tkEq, tkNe, tkLt, tkLe, tkGt, tkGe:
      if not left.isAssignableTo(right) and not right.isAssignableTo(left):
        sema.emitError(expr.loc, &"cannot compare types {left.toString} and {right.toString}")
      return makeBool()
    else:
      return makeUnknown()
  of ekAssign:
    let target = sema.checkExpr(expr.exprAssignTarget, scope)
    let value = sema.checkExpr(expr.exprAssignValue, scope)
    if not value.isAssignableTo(target):
      sema.emitError(expr.loc, &"cannot assign {value.toString} to {target.toString}")
    return target
  of ekTernary:
    let cond = sema.checkExpr(expr.exprTernaryCond, scope)
    if not cond.isBool:
      sema.emitError(expr.loc, "ternary condition must be bool")
    let thenType = sema.checkExpr(expr.exprTernaryThen, scope)
    let elseType = sema.checkExpr(expr.exprTernaryElse, scope)
    if thenType != elseType:
      sema.emitError(expr.loc, "ternary branches must have same type")
    return thenType
  of ekRange:
    let lo = sema.checkExpr(expr.exprRangeLo, scope)
    let hi = sema.checkExpr(expr.exprRangeHi, scope)
    if lo != hi:
      sema.emitError(expr.loc, "range bounds must have same type")
    return makeRange(lo)
  of ekCall:
    if expr.exprCallCallee == nil:
      sema.emitError(expr.loc, "internal error: nil callee in call expression")
      return makeUnknown()

    # Check for generic function call: Max<int>(10, 20)
    if expr.exprCallCallee.kind == ekGenericCall:
      let sym = scope.lookup(expr.exprCallCallee.exprGenericCallee)
      if sym == nil:
        sema.emitError(expr.loc, &"undeclared identifier '{expr.exprCallCallee.exprGenericCallee}'")
        return makeUnknown()
      if sym.typ != nil and sym.typ.kind == tkFunc:
        # Get the return type and substitute type parameters
        let retType = sym.typ.inner[^1]
        if retType.kind == tkNamed:
          # Check if this is a type parameter
          let sym2 = sema.globalScope.lookup(expr.exprCallCallee.exprGenericCallee)
          if sym2 != nil and sym2.decl != nil and sym2.decl.kind == dkFunc:
            let typeParams = sym2.decl.declFuncTypeParams
            for i, tp in typeParams:
              if retType.name == tp and i < expr.exprCallCallee.exprGenericTypeArgs.len:
                # Substitute with concrete type
                let concreteType = expr.exprCallCallee.exprGenericTypeArgs[i]
                if concreteType.kind == tekNamed:
                  return sema.resolveType(concreteType)
        return retType
      return makeUnknown()

    # Check for method call: obj.method(args)
    if expr.exprCallCallee.kind == ekField:
      let receiver = sema.checkExpr(expr.exprCallCallee.exprFieldObj, scope)
      let methodName = expr.exprCallCallee.exprFieldName
      var argTypes = sema.checkExprList(expr.exprCallArgs, scope)
      
      # Try to find method for receiver type
      var typeName = ""
      if receiver.kind == tkNamed:
        typeName = receiver.name
      elif receiver.isPointer and receiver.inner.len > 0 and receiver.inner[0].kind == tkNamed:
        typeName = receiver.inner[0].name
      
      if typeName != "" and sema.methodTable.hasKey(typeName):
        for minfo in sema.methodTable[typeName]:
          if minfo.name == methodName:
            # Found method - check arguments (skip self parameter)
            let expectedParams = minfo.params
            if argTypes.len + 1 < expectedParams.len:
              sema.emitError(expr.loc, &"too few arguments for method '{methodName}'")
            elif argTypes.len > expectedParams.len:
              sema.emitError(expr.loc, &"too many arguments for method '{methodName}'")
            else:
              for i in 0 ..< argTypes.len:
                let paramIdx = i + 1  # skip self
                if paramIdx < expectedParams.len:
                  if not argTypes[i].isAssignableTo(expectedParams[paramIdx]):
                    sema.emitError(expr.loc, &"argument {i+1}: expected {expectedParams[paramIdx].toString}, got {argTypes[i].toString}")
            return minfo.retType
      
      # Not a method - treat as function pointer field
      let fieldType = sema.checkExpr(expr.exprCallCallee, scope)
      if fieldType.kind == tkFunc:
        let expectedParams = fieldType.inner[0..^2]
        if argTypes.len != expectedParams.len:
          sema.emitError(expr.loc, &"expected {expectedParams.len} arguments, got {argTypes.len}")
        return fieldType.inner[^1]
      else:
        sema.emitError(expr.loc, &"cannot call non-function field '{methodName}' on type {receiver.toString}")
        return makeUnknown()
    
    # Regular function call
    let calleeType = sema.checkExpr(expr.exprCallCallee, scope)
    var argTypes = sema.checkExprList(expr.exprCallArgs, scope)
    if calleeType.kind == tkFunc:
      let expectedParams = calleeType.inner[0..^2]
      if argTypes.len != expectedParams.len:
        sema.emitError(expr.loc, &"expected {expectedParams.len} arguments, got {argTypes.len}")
      else:
        for i in 0 ..< argTypes.len:
          if not argTypes[i].isAssignableTo(expectedParams[i]):
            sema.emitError(expr.loc, &"argument {i+1}: expected {expectedParams[i].toString}, got {argTypes[i].toString}")
      return calleeType.inner[^1]
    elif calleeType.kind == tkUnknown:
      return makeUnknown()
    else:
      sema.emitError(expr.loc, &"cannot call non-function type {calleeType.toString}")
      return makeUnknown()
  of ekGenericCall:
    # Generic function call: Max<int>(10, 20)
    # For now, just look up the function and return its return type
    let sym = scope.lookup(expr.exprGenericCallee)
    if sym == nil:
      sema.emitError(expr.loc, &"undeclared identifier '{expr.exprGenericCallee}'")
      return makeUnknown()
    if sym.typ != nil and sym.typ.kind == tkFunc:
      return sym.typ.inner[^1]
    return makeUnknown()
  of ekIndex:
    let obj = sema.checkExpr(expr.exprIndexObj, scope)
    let idx = sema.checkExpr(expr.exprIndexIdx, scope)
    if not idx.isInteger:
      sema.emitError(expr.loc, "index must be integer")
    if obj.isSlice:
      return obj.inner[0]
    elif obj.isPointer:
      return obj.inner[0]
    else:
      sema.emitError(expr.loc, "cannot index non-slice/non-pointer type")
      return makeUnknown()
  of ekField:
    let obj = sema.checkExpr(expr.exprFieldObj, scope)
    var objType = obj
    # Auto-dereference pointer types for field access
    if objType.kind == tkPointer and objType.inner.len > 0:
      objType = objType.inner[0]
    if objType.kind == tkNamed:
      # Check if this is a _Data union field access
      if objType.name.endsWith("_Data"):
        let enumName = objType.name[0..^6]  # Remove "_Data" suffix
        let enumSym = sema.globalScope.lookup(enumName)
        if enumSym != nil and enumSym.decl != nil and enumSym.decl.kind == dkEnum:
          # Look for the field in enum variants
          for variant in enumSym.decl.declEnumVariants:
            # Check positional fields: Ok_0, Ok_1, etc.
            for i, f in variant.fields:
              let fieldName = variant.name & "_" & $i
              if fieldName == expr.exprFieldName:
                return sema.resolveType(f)
            # Check named fields
            for nf in variant.namedFields:
              if nf.name == expr.exprFieldName:
                return sema.resolveType(nf.ftype)
          sema.emitError(expr.loc, &"union '{objType.name}' has no field '{expr.exprFieldName}'")
        else:
          sema.emitError(expr.loc, &"cannot access field on type {obj.toString}")
      else:
        let sym = sema.globalScope.lookup(objType.name)
        if sym != nil and sym.decl != nil:
          if sym.decl.kind == dkStruct:
            for f in sym.decl.declStructFields:
              if f.name == expr.exprFieldName:
                return sema.resolveType(f.ftype)
            sema.emitError(expr.loc, &"struct '{objType.name}' has no field '{expr.exprFieldName}'")
          elif sym.decl.kind == dkEnum:
            # Algebraic enum fields
            if expr.exprFieldName == "tag":
              return makeNamed(obj.name & "_Tag")
            elif expr.exprFieldName == "data":
              return makeNamed(obj.name & "_Data")
            else:
              sema.emitError(expr.loc, &"enum '{obj.name}' has no field '{expr.exprFieldName}'")
          elif sym.decl.kind == dkUnion:
            # Union fields
            for f in sym.decl.declUnionFields:
              if f.name == expr.exprFieldName:
                return sema.resolveType(f.ftype)
            sema.emitError(expr.loc, &"union '{obj.name}' has no field '{expr.exprFieldName}'")
          else:
            sema.emitError(expr.loc, &"cannot access field on type {obj.toString}")
        else:
          sema.emitError(expr.loc, &"cannot access field on type {obj.toString}")
    else:
      sema.emitError(expr.loc, &"cannot access field on type {obj.toString}")
    return makeUnknown()
  of ekStructInit:
    let sym = sema.globalScope.lookup(expr.exprStructInitName)
    if sym == nil or sym.kind != skType:
      sema.emitError(expr.loc, &"unknown struct type '{expr.exprStructInitName}'")
      return makeUnknown()
    return makeNamed(expr.exprStructInitName)
  of ekSlice:
    if expr.exprSliceElements.len == 0:
      return makeSlice(makeUnknown())
    let firstType = sema.checkExpr(expr.exprSliceElements[0], scope)
    for i in 1 ..< expr.exprSliceElements.len:
      let t = sema.checkExpr(expr.exprSliceElements[i], scope)
      if t != firstType:
        sema.emitError(expr.loc, "slice elements must have same type")
    return makeSlice(firstType)
  of ekTuple:
    var elems: seq[Type] = @[]
    for e in expr.exprTupleElements:
      elems.add(sema.checkExpr(e, scope))
    return makeTuple(elems)
  of ekCast:
    discard sema.checkExpr(expr.exprCastOperand, scope)
    return sema.resolveType(expr.exprCastType)
  of ekIs:
    discard sema.checkExpr(expr.exprIsOperand, scope)
    return makeBool()
  of ekBlock:
    var blockScope = newScope(scope)
    var lastType = makeVoid()
    for stmt in expr.exprBlock.stmts:
      lastType = sema.checkStmt(stmt, blockScope)
    return lastType
  of ekMatch:
    let subjectType = sema.checkExpr(expr.exprMatchSubject, scope)
    var resultType = makeUnknown()
    for arm in expr.exprMatchArms:
      var armScope = newScope(scope)
      sema.extractPatternBindings(arm.pattern, armScope)
      let armType = sema.checkExpr(arm.body, armScope)
      if resultType.isUnknown:
        resultType = armType
      elif armType != resultType and not armType.isUnknown:
        sema.emitError(arm.body.loc, "match arm type mismatch")
    return resultType
  of ekSizeOf:
    return makeInt()
  of ekIntrinsic:
    case expr.exprIntrinsic
    of ikLine, ikColumn: return makeInt()
    of ikFile, ikFunction, ikDate, ikTime, ikModule: return makeStr()
  of ekSpread:
    return sema.checkExpr(expr.exprSpreadOperand, scope)

# ---------------------------------------------------------------------------
# Statement type checking
# ---------------------------------------------------------------------------

proc checkStmt(sema: var Sema, stmt: Stmt, scope: Scope): Type =
  if stmt == nil:
    return makeVoid()
  case stmt.kind
  of skExpr:
    return sema.checkExpr(stmt.stmtExpr, scope)
  of skLet:
    let initType = sema.checkExpr(stmt.stmtLetInit, scope)
    let declaredType = if stmt.stmtLetType != nil: sema.resolveType(stmt.stmtLetType) else: initType
    if stmt.stmtLetType != nil and not initType.isAssignableTo(declaredType):
      sema.emitError(stmt.loc, &"cannot assign {initType.toString} to {declaredType.toString}")
    let sym = Symbol(kind: skVar, name: stmt.stmtLetName, typ: declaredType,
                     isMutable: stmt.stmtLetMut)
    if not scope.define(sym):
      sema.emitError(stmt.loc, &"duplicate variable '{stmt.stmtLetName}'")
    return makeVoid()
  of skIf:
    let condType = sema.checkExpr(stmt.stmtIfCond, scope)
    if not condType.isBool:
      sema.emitError(stmt.loc, "if condition must be bool")
    discard sema.checkStmt(Stmt(kind: skExpr, loc: stmt.stmtIfThen.loc, stmtExpr: Expr(kind: ekBlock, loc: stmt.stmtIfThen.loc, exprBlock: stmt.stmtIfThen)), scope)
    for elifBranch in stmt.stmtIfElseIfs:
      let elifCond = sema.checkExpr(elifBranch.cond, scope)
      if not elifCond.isBool:
        sema.emitError(elifBranch.cond.loc, "else-if condition must be bool")
      discard sema.checkStmt(Stmt(kind: skExpr, loc: elifBranch.blk.loc, stmtExpr: Expr(kind: ekBlock, loc: elifBranch.blk.loc, exprBlock: elifBranch.blk)), scope)
    if stmt.stmtIfElse != nil:
      discard sema.checkStmt(Stmt(kind: skExpr, loc: stmt.stmtIfElse.loc, stmtExpr: Expr(kind: ekBlock, loc: stmt.stmtIfElse.loc, exprBlock: stmt.stmtIfElse)), scope)
    return makeVoid()
  of skWhile:
    let condType = sema.checkExpr(stmt.stmtWhileCond, scope)
    if not condType.isBool:
      sema.emitError(stmt.loc, "while condition must be bool")
    discard sema.checkStmt(Stmt(kind: skExpr, loc: stmt.stmtWhileBody.loc, stmtExpr: Expr(kind: ekBlock, loc: stmt.stmtWhileBody.loc, exprBlock: stmt.stmtWhileBody)), scope)
    return makeVoid()
  of skDoWhile:
    discard sema.checkStmt(Stmt(kind: skExpr, loc: stmt.stmtDoWhileBody.loc, stmtExpr: Expr(kind: ekBlock, loc: stmt.stmtDoWhileBody.loc, exprBlock: stmt.stmtDoWhileBody)), scope)
    let condType = sema.checkExpr(stmt.stmtDoWhileCond, scope)
    if not condType.isBool:
      sema.emitError(stmt.loc, "do-while condition must be bool")
    return makeVoid()
  of skLoop:
    discard sema.checkStmt(Stmt(kind: skExpr, loc: stmt.stmtLoopBody.loc, stmtExpr: Expr(kind: ekBlock, loc: stmt.stmtLoopBody.loc, exprBlock: stmt.stmtLoopBody)), scope)
    return makeVoid()
  of skFor:
    discard sema.checkExpr(stmt.stmtForIter, scope)
    var forScope = newScope(scope)
    let iterSym = Symbol(kind: skVar, name: stmt.stmtForVar, typ: makeUnknown(), isMutable: true)
    discard forScope.define(iterSym)
    discard sema.checkStmt(Stmt(kind: skExpr, loc: stmt.stmtForBody.loc, stmtExpr: Expr(kind: ekBlock, loc: stmt.stmtForBody.loc, exprBlock: stmt.stmtForBody)), forScope)
    return makeVoid()
  of skMatch:
    discard sema.checkExpr(stmt.stmtMatchSubject, scope)
    for arm in stmt.stmtMatchArms:
      discard sema.checkExpr(arm.body, scope)
    return makeVoid()
  of skReturn:
    if stmt.stmtReturnValue != nil:
      discard sema.checkExpr(stmt.stmtReturnValue, scope)
    return makeVoid()
  of skBreak, skContinue:
    return makeVoid()
  of skDecl:
    # Local declaration inside block
    case stmt.stmtDecl.kind
    of dkFunc:
      sema.emitError(stmt.loc, "nested functions not yet supported")
    else:
      discard
    return makeVoid()

# ---------------------------------------------------------------------------
# Function body checking
# ---------------------------------------------------------------------------

proc checkFunc(sema: var Sema, decl: Decl) =
  if decl.declFuncBody == nil:
    return
  var funcScope = newScope(sema.globalScope)
  # Add parameters
  for p in decl.declFuncParams:
    let pType = sema.resolveType(p.ptype)
    let sym = Symbol(kind: skVar, name: p.name, typ: pType, isMutable: false)
    discard funcScope.define(sym)
  # Check body statements
  for stmt in decl.declFuncBody.stmts:
    discard sema.checkStmt(stmt, funcScope)

# ---------------------------------------------------------------------------
# Second pass: check all function bodies
# ---------------------------------------------------------------------------

proc checkBodies(sema: var Sema) =
  for decl in sema.module.items:
    case decl.kind
    of dkFunc:
      sema.checkFunc(decl)
    else:
      discard

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc analyze*(modu: Module): SemaResult =
  var sema = Sema(module: modu, globalScope: newScope())
  sema.collectGlobals()
  sema.checkBodies()
  result = SemaResult(diagnostics: sema.diagnostics)

proc analyzeFull*(modu: Module): tuple[result: SemaResult, sema: Sema] =
  ## Analyze module and return both result and full Sema context
  ## Use this when you need the Sema for lowering (method table, etc.)
  var sema = Sema(module: modu, globalScope: newScope())
  sema.collectGlobals()
  sema.checkBodies()
  result = (SemaResult(diagnostics: sema.diagnostics), sema)
