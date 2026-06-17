import std/[strformat, tables, strutils]
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

  CtValueKind = enum
    ctkVoid, ctkInt, ctkBool, ctkString

  CtValue = object
    case kind: CtValueKind
    of ctkVoid: discard
    of ctkInt: intVal: int64
    of ctkBool: boolVal: bool
    of ctkString: strVal: string

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
    # Borrow checker state
    checkedFunc*: bool  ## true inside @[Checked] function
    currentFuncIsAsync*: bool  ## true inside async func
    movedVars*: seq[string]  ## variables moved in current checked function
    currentRetType*: Type    ## return type of the function being checked
    closureDepth*: int       ## nesting depth inside closures
    currentClosureExpr*: Expr  ## current closure being analyzed
    closureScope*: Scope     ## scope at which the current closure was entered

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc unescapeStringLiteral*(s: string): string =
  ## Convert a raw string literal (with surrounding quotes and escape sequences)
  ## into the actual string value.
  result = s
  # Strip surrounding quotes
  if result.len >= 2 and result[0] == '"' and result[^1] == '"':
    result = result[1 ..< ^1]
  # Process escape sequences
  var i = 0
  var outStr = ""
  while i < result.len:
    if result[i] == '\\' and i + 1 < result.len:
      case result[i + 1]
      of '\\': outStr.add('\\')
      of '"': outStr.add('"')
      of '\'': outStr.add('\'')
      of 'n': outStr.add('\n')
      of 'r': outStr.add('\r')
      of 't': outStr.add('\t')
      of '0': outStr.add('\0')
      of 'x':
        if i + 3 < result.len:
          let hexStr = result[i + 2 .. i + 3]
          try:
            let code = parseHexInt(hexStr)
            outStr.add(chr(code))
            i += 2
          except ValueError:
            outStr.add(result[i])
        else:
          outStr.add(result[i])
      else:
        outStr.add(result[i + 1])
      i += 2
    else:
      outStr.add(result[i])
      inc i
  result = outStr

proc emitError(sema: var Sema, loc: SourceLocation, message: string) =
  sema.diagnostics.add(SemaDiagnostic(severity: sdsError, loc: loc, message: message))

proc hasErrors*(res: SemaResult): bool =
  for d in res.diagnostics:
    if d.severity == sdsError:
      return true
  return false

# ---------------------------------------------------------------------------
# Generic type inference helpers
# ---------------------------------------------------------------------------

proc typeExprReferencesTypeParam(te: TypeExpr, name: string): bool =
  ## Recursively check if a TypeExpr tree references a given type parameter name.
  if te == nil: return false
  case te.kind
  of tekNamed:
    if te.typeName == name: return true
    for arg in te.typeArgs:
      if typeExprReferencesTypeParam(arg, name): return true
  of tekPath:
    return false
  of tekSlice:
    return typeExprReferencesTypeParam(te.sliceElement, name)
  of tekOwn, tekPointer:
    return typeExprReferencesTypeParam(te.pointerPointee, name)
  of tekRef, tekMutRef:
    if te.refLifetime == name: return true
    return typeExprReferencesTypeParam(te.pointerPointee, name)
  of tekDynRef:
    return false
  of tekTuple:
    for elem in te.tupleElements:
      if typeExprReferencesTypeParam(elem, name): return true
  of tekFunc:
    for p in te.funcParams:
      if typeExprReferencesTypeParam(p, name): return true
    return typeExprReferencesTypeParam(te.funcRet, name)
  of tekSelf:
    return false

proc typeToTypeExpr*(t: Type): TypeExpr =
  ## Convert a resolved Type back to a TypeExpr for storage in inferred type args.
  case t.kind
  of tkInt: TypeExpr(kind: tekNamed, typeName: "int")
  of tkInt8: TypeExpr(kind: tekNamed, typeName: "int8")
  of tkInt16: TypeExpr(kind: tekNamed, typeName: "int16")
  of tkInt32: TypeExpr(kind: tekNamed, typeName: "int32")
  of tkInt64: TypeExpr(kind: tekNamed, typeName: "int64")
  of tkUInt: TypeExpr(kind: tekNamed, typeName: "uint")
  of tkUInt8: TypeExpr(kind: tekNamed, typeName: "uint8")
  of tkUInt16: TypeExpr(kind: tekNamed, typeName: "uint16")
  of tkUInt32: TypeExpr(kind: tekNamed, typeName: "uint32")
  of tkUInt64: TypeExpr(kind: tekNamed, typeName: "uint64")
  of tkFloat32: TypeExpr(kind: tekNamed, typeName: "float32")
  of tkFloat64: TypeExpr(kind: tekNamed, typeName: "float64")
  of tkBool: TypeExpr(kind: tekNamed, typeName: "bool")
  of tkStr: TypeExpr(kind: tekNamed, typeName: "String")
  of tkNamed:
    var args: seq[TypeExpr] = @[]
    for a in t.inner:
      args.add(typeToTypeExpr(a))
    return TypeExpr(kind: tekNamed, typeName: t.name, typeArgs: args)
  of tkPointer:
    if t.inner.len > 0:
      TypeExpr(kind: tekPointer, refLifetime: "", pointerPointee: typeToTypeExpr(t.inner[0]))
    else:
      TypeExpr(kind: tekNamed, typeName: "void")
  of tkRef:
    if t.inner.len > 0:
      TypeExpr(kind: tekRef, refLifetime: "", pointerPointee: typeToTypeExpr(t.inner[0]))
    else:
      TypeExpr(kind: tekNamed, typeName: "void")
  of tkMutRef:
    if t.inner.len > 0:
      TypeExpr(kind: tekMutRef, refLifetime: "", pointerPointee: typeToTypeExpr(t.inner[0]))
    else:
      TypeExpr(kind: tekNamed, typeName: "void")
  of tkVoid: TypeExpr(kind: tekNamed, typeName: "void")
  else: TypeExpr(kind: tekNamed, typeName: t.toString)

proc substituteTypeInType(sema: var Sema, t: Type, subst: Table[string, Type]): Type =
  ## Recursively substitute type parameters in a resolved Type.
  if t == nil:
    return makeUnknown()
  case t.kind
  of tkTypeParam:
    if subst.hasKey(t.name):
      return subst[t.name]
    return t
  of tkPointer, tkRef, tkMutRef:
    if t.inner.len > 0:
      return Type(kind: t.kind, inner: @[sema.substituteTypeInType(t.inner[0], subst)])
    return t
  of tkSlice, tkRange:
    if t.inner.len > 0:
      return Type(kind: t.kind, inner: @[sema.substituteTypeInType(t.inner[0], subst)])
    return t
  of tkTuple:
    var elems: seq[Type] = @[]
    for e in t.inner:
      elems.add(sema.substituteTypeInType(e, subst))
    return makeTuple(elems)
  of tkFunc:
    var inner: seq[Type] = @[]
    for it in t.inner:
      inner.add(sema.substituteTypeInType(it, subst))
    return Type(kind: tkFunc, inner: inner)
  of tkNamed:
    if subst.hasKey(t.name):
      return subst[t.name]
    if t.inner.len > 0:
      var args: seq[Type] = @[]
      for a in t.inner:
        args.add(sema.substituteTypeInType(a, subst))
      return Type(kind: tkNamed, name: t.name, inner: args)
    return t
  else:
    return t

proc inferTypeArgs(sema: var Sema, funcDecl: Decl, argTypes: seq[Type],
                   loc: SourceLocation): seq[TypeExpr] =
  ## Infer type arguments from argument types for a generic function call.
  ## Returns empty seq if inference fails for any type parameter.
  result = @[]
  for tp in funcDecl.declFuncTypeParams:
    let tpName = tp.name
    # Lifetime params are inferred from ref lifetime positions
    if tp.isLifetime:
      var found = false
      for i, param in funcDecl.declFuncParams:
        if i >= argTypes.len: break
        if param.ptype.kind in {tekRef, tekMutRef} and param.ptype.refLifetime == tpName:
          found = true
          break
      if found:
        result.add(TypeExpr(kind: tekNamed, typeName: "lifetime"))
        continue
      # If not found in refs, treat as uninferrable
      return @[]
    var inferred: Type = nil
    for i, param in funcDecl.declFuncParams:
      if i >= argTypes.len: break
      # Skip pointer params — type param is inside the pointee and we cannot
      # structurally extract it (e.g., *Map<K,V> → arg is *Map<int,String>)
      if param.ptype.kind in {tekOwn, tekPointer}:
        continue
      if typeExprReferencesTypeParam(param.ptype, tpName):
        var argType = argTypes[i]
        # If type param is inside a ref/pointer pointee, unwrap the arg type
        if param.ptype.kind in {tekRef, tekMutRef, tekPointer} and
           typeExprReferencesTypeParam(param.ptype.pointerPointee, tpName) and
           argType.isPointer and argType.inner.len > 0:
          argType = argType.inner[0]
        if inferred == nil:
          inferred = argType
        elif inferred != argType:
          # Check if one is assignable to the other (wider type wins)
          if argTypes[i].isAssignableTo(inferred):
            discard  # inferred stays the same
          elif inferred.isAssignableTo(argTypes[i]):
            inferred = argTypes[i]
          else:
            sema.emitError(loc,
              &"conflicting types for type parameter '{tpName}': " &
              &"{inferred.toString} vs {argType.toString}")
            return @[]
    if inferred != nil and not inferred.isUnknown:
      result.add(typeToTypeExpr(inferred))
    else:
      # Cannot infer this type parameter from arguments
      return @[]

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
      if te.typeArgs.len > 0:
        var args: seq[Type] = @[]
        for arg in te.typeArgs:
          args.add(sema.resolveType(arg))
        return Type(kind: tkNamed, name: name, inner: args)
      if sema.typeTable.hasKey(name):
        return sema.typeTable[name]
      return makeNamed(name)
  of tekPath:
    let fullName = te.pathSegments.join("::")
    return makeNamed(fullName)
  of tekOwn:
    return sema.resolveType(te.pointerPointee)
  of tekPointer:
    return makePointer(sema.resolveType(te.pointerPointee))
  of tekRef:
    return makeRef(sema.resolveType(te.pointerPointee))
  of tekMutRef:
    return makeMutRef(sema.resolveType(te.pointerPointee))
  of tekDynRef:
    return makeDynRef(te.dynInterface)
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
  of tekFunc:
    var params: seq[Type] = @[]
    for p in te.funcParams:
      params.add(sema.resolveType(p))
    let ret = if te.funcRet != nil: sema.resolveType(te.funcRet) else: makeVoid()
    return makeFunc(params, ret)

# ---------------------------------------------------------------------------
# First pass: collect global symbols
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Compile-Time Function Execution (CTFE)
# ---------------------------------------------------------------------------

proc evalExpr(sema: Sema, expr: Expr, locals: Table[string, CtValue]): CtValue

proc evalBlock(sema: Sema, blk: Block, locals: Table[string, CtValue]): CtValue =
  var localVars = locals
  for stmt in blk.stmts:
    case stmt.kind
    of skLet:
      if stmt.stmtLetInit != nil:
        let val = sema.evalExpr(stmt.stmtLetInit, localVars)
        if val.kind in {ctkInt, ctkBool, ctkString}:
          localVars[stmt.stmtLetName] = val
    of skIf:
      let cond = sema.evalExpr(stmt.stmtIfCond, localVars)
      if cond.kind == ctkBool:
        if cond.boolVal:
          let res = sema.evalBlock(stmt.stmtIfThen, localVars)
          if res.kind != ctkVoid:
            return res
        elif stmt.stmtIfElse != nil:
          let res = sema.evalBlock(stmt.stmtIfElse, localVars)
          if res.kind != ctkVoid:
            return res
        # If condition is false and no else, continue to next statement
      else:
        return CtValue(kind: ctkVoid)
    of skReturn:
      if stmt.stmtReturnValue != nil:
        return sema.evalExpr(stmt.stmtReturnValue, localVars)
      return CtValue(kind: ctkVoid)
    of skExpr:
      let res = sema.evalExpr(stmt.stmtExpr, localVars)
      if res.kind != ctkVoid:
        return res
    of skStaticAssert:
      let cond = sema.evalExpr(stmt.stmtStaticAssertCond, localVars)
      if cond.kind != ctkBool or not cond.boolVal:
        var msg = "static assertion failed"
        if stmt.stmtStaticAssertMsg != nil:
          let msgVal = sema.evalExpr(stmt.stmtStaticAssertMsg, localVars)
          if msgVal.kind == ctkString:
            msg = msgVal.strVal
        # Note: we can't emitError here because evalBlock is used for const folding too
        # and we don't have access to sema diagnostics. For now, just return void.
        # In checkStmt we'll do the real error reporting.
        discard
    of skComptime:
      discard sema.evalBlock(stmt.stmtComptimeBlock, localVars)
    else:
      discard
  return CtValue(kind: ctkVoid)

proc evalExpr(sema: Sema, expr: Expr, locals: Table[string, CtValue]): CtValue =
  if expr == nil:
    return CtValue(kind: ctkVoid)
  case expr.kind
  of ekLiteral:
    case expr.exprLit.kind
    of tkIntLiteral:
      return CtValue(kind: ctkInt, intVal: parseBiggestInt(expr.exprLit.text))
    of tkBoolLiteral:
      return CtValue(kind: ctkBool, boolVal: expr.exprLit.text == "true")
    of tkStringLiteral:
      return CtValue(kind: ctkString, strVal: unescapeStringLiteral(expr.exprLit.text))
    else:
      return CtValue(kind: ctkVoid)
  of ekIdent:
    if locals.hasKey(expr.exprIdent):
      return locals[expr.exprIdent]
    # Check if it's a const global
    let sym = sema.globalScope.lookup(expr.exprIdent)
    if sym != nil and sym.decl != nil and sym.decl.kind == dkConst and sym.decl.declConstValue != nil:
      return sema.evalExpr(sym.decl.declConstValue, locals)
    return CtValue(kind: ctkVoid)
  of ekUnary:
    let operand = sema.evalExpr(expr.exprUnaryOperand, locals)
    case expr.exprUnaryOp
    of tkMinus:
      if operand.kind == ctkInt:
        return CtValue(kind: ctkInt, intVal: -operand.intVal)
    of tkBang:
      if operand.kind == ctkBool:
        return CtValue(kind: ctkBool, boolVal: not operand.boolVal)
    else:
      discard
    return CtValue(kind: ctkVoid)
  of ekBinary:
    let left = sema.evalExpr(expr.exprBinaryLeft, locals)
    let right = sema.evalExpr(expr.exprBinaryRight, locals)
    if left.kind == ctkInt and right.kind == ctkInt:
      case expr.exprBinaryOp
      of tkPlus: return CtValue(kind: ctkInt, intVal: left.intVal + right.intVal)
      of tkMinus: return CtValue(kind: ctkInt, intVal: left.intVal - right.intVal)
      of tkStar: return CtValue(kind: ctkInt, intVal: left.intVal * right.intVal)
      of tkSlash:
        if right.intVal != 0:
          return CtValue(kind: ctkInt, intVal: left.intVal div right.intVal)
      of tkPercent:
        if right.intVal != 0:
          return CtValue(kind: ctkInt, intVal: left.intVal mod right.intVal)
      of tkEq: return CtValue(kind: ctkBool, boolVal: left.intVal == right.intVal)
      of tkNe: return CtValue(kind: ctkBool, boolVal: left.intVal != right.intVal)
      of tkLt: return CtValue(kind: ctkBool, boolVal: left.intVal < right.intVal)
      of tkLe: return CtValue(kind: ctkBool, boolVal: left.intVal <= right.intVal)
      of tkGt: return CtValue(kind: ctkBool, boolVal: left.intVal > right.intVal)
      of tkGe: return CtValue(kind: ctkBool, boolVal: left.intVal >= right.intVal)
      else: discard
    elif left.kind == ctkBool and right.kind == ctkBool:
      case expr.exprBinaryOp
      of tkAmpAmp: return CtValue(kind: ctkBool, boolVal: left.boolVal and right.boolVal)
      of tkPipePipe: return CtValue(kind: ctkBool, boolVal: left.boolVal or right.boolVal)
      else: discard
    return CtValue(kind: ctkVoid)
  of ekTernary:
    let cond = sema.evalExpr(expr.exprTernaryCond, locals)
    if cond.kind == ctkBool:
      if cond.boolVal:
        return sema.evalExpr(expr.exprTernaryThen, locals)
      else:
        return sema.evalExpr(expr.exprTernaryElse, locals)
    return CtValue(kind: ctkVoid)
  of ekCall:
    # Try to evaluate const func calls
    if expr.exprCallCallee != nil and expr.exprCallCallee.kind == ekIdent:
      let funcName = expr.exprCallCallee.exprIdent
      let sym = sema.globalScope.lookup(funcName)
      if sym != nil and sym.decl != nil and sym.decl.kind == dkFunc and sym.decl.declFuncConst:
        # Evaluate arguments
        var argVals: seq[CtValue] = @[]
        for arg in expr.exprCallArgs:
          argVals.add(sema.evalExpr(arg, locals))
        # Build parameter locals
        var callLocals = locals
        for i, p in sym.decl.declFuncParams:
          if i < argVals.len:
            callLocals[p.name] = argVals[i]
        # Evaluate function body
        if sym.decl.declFuncBody != nil:
          return sema.evalBlock(sym.decl.declFuncBody, callLocals)
    return CtValue(kind: ctkVoid)
  of ekBlock:
    return sema.evalBlock(expr.exprBlock, locals)
  else:
    return CtValue(kind: ctkVoid)

proc constFoldConstDecl(sema: Sema, decl: Decl): bool =
  ## Try to evaluate a const declaration at compile time.
  ## Returns true if successful and modifies declConstValue to a literal.
  if decl.kind != dkConst: return false
  let val = sema.evalExpr(decl.declConstValue, initTable[string, CtValue]())
  case val.kind
  of ctkInt:
    decl.declConstValue = Expr(kind: ekLiteral, loc: decl.loc,
      exprLit: Token(kind: tkIntLiteral, text: $val.intVal, loc: decl.loc))
    return true
  of ctkBool:
    decl.declConstValue = Expr(kind: ekLiteral, loc: decl.loc,
      exprLit: Token(kind: tkBoolLiteral, text: $val.boolVal, loc: decl.loc))
    return true
  of ctkString:
    decl.declConstValue = Expr(kind: ekLiteral, loc: decl.loc,
      exprLit: Token(kind: tkStringLiteral, text: val.strVal, loc: decl.loc))
    return true
  of ctkVoid:
    return false

proc collectGlobals*(sema: var Sema) =
  for decl in sema.module.items:
    case decl.kind
    of dkFunc:
      let sym = Symbol(kind: skFunc, name: decl.declFuncName, decl: decl,
                       isPublic: decl.isPublic)
      # Temporarily add type parameters to type table for resolution
      var addedTypeParams: seq[string] = @[]
      for tp in decl.declFuncTypeParams:
        sema.typeTable[tp.name] = makeTypeParam(tp.name)
        addedTypeParams.add(tp.name)
      # Build function type from params and return
      var params: seq[Type] = @[]
      for p in decl.declFuncParams:
        params.add(sema.resolveType(p.ptype))
      let retType = if decl.declFuncReturnType != nil: sema.resolveType(decl.declFuncReturnType) else: makeVoid()
      sym.typ = makeFunc(params, retType)
      if not sema.globalScope.define(sym):
        let existing = sema.globalScope.lookup(decl.declFuncName)
        if existing != nil and existing.kind == skFunc:
          if existing.decl != nil and existing.decl.declFuncBody == nil and decl.declFuncBody != nil:
            # First was forward declaration, update with definition
            existing.decl = decl
            existing.typ = sym.typ
          elif decl.declFuncBody == nil:
            # New one is a forward declaration, existing already has it — skip
            discard
          else:
            sema.emitError(decl.loc, &"duplicate symbol '{decl.declFuncName}'")
        else:
          sema.emitError(decl.loc, &"duplicate symbol '{decl.declFuncName}'")
      # Auto-register func Type_Method(self: Type, ...) as a method
      if decl.declFuncParams.len > 0 and decl.declFuncParams[0].name == "self":
        var typeName = ""
        for i in countdown(decl.declFuncName.len - 1, 1):
          if decl.declFuncName[i] == '_':
            let prefix = decl.declFuncName[0..<i]
            let typeSym = sema.globalScope.lookup(prefix)
            if typeSym != nil and typeSym.kind == skType and typeSym.decl != nil and typeSym.decl.kind == dkStruct:
              typeName = prefix
              break
        if typeName != "":
          let methodName = decl.declFuncName[typeName.len + 1 .. ^1]
          if not sema.methodTable.hasKey(typeName):
            sema.methodTable[typeName] = @[]
          var minfo = MethodInfo(
            name: methodName,
            decl: decl,
            params: params,
            retType: retType
          )
          sema.methodTable[typeName].add(minfo)
      # Clean up type parameters
      for tp in addedTypeParams:
        sema.typeTable.del(tp)
    of dkExternFunc:
      let sym = Symbol(kind: skFunc, name: decl.declExtFuncName, decl: decl,
                       isPublic: decl.isPublic)
      var params: seq[Type] = @[]
      for p in decl.declExtFuncParams:
        params.add(sema.resolveType(p.ptype))
      let retType = if decl.declExtFuncReturnType != nil: sema.resolveType(decl.declExtFuncReturnType) else: makeVoid()
      sym.typ = makeFunc(params, retType)
      if not sema.globalScope.define(sym):
        # Allow duplicate extern func declarations (same func declared in multiple files)
        let existing = sema.globalScope.lookup(decl.declExtFuncName)
        if existing == nil or existing.kind != skFunc:
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
      # Check if algebraic or simple enum
      var hasData = false
      for variant in decl.declEnumVariants:
        if variant.fields.len > 0 or variant.namedFields.len > 0:
          hasData = true
          break
      # For algebraic enums, add variant constants with _Tag type
      # For simple enums, variant constants have the enum type itself
      for variant in decl.declEnumVariants:
        let variantName = decl.declEnumName & "_" & variant.name
        let variantType = if hasData: makeNamed(decl.declEnumName & "_Tag") else: makeNamed(decl.declEnumName)
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
      # Imports handled in second pass after all declarations are registered
      discard
    of dkInterface:
      # Register interface for conformance checking
      sema.interfaceTable[decl.declInterfaceName] = decl
      let t = makeNamed(decl.declInterfaceName)
      let sym = Symbol(kind: skType, name: decl.declInterfaceName, typ: t,
                       decl: decl, isPublic: decl.isPublic)
      if not sema.globalScope.define(sym):
        sema.emitError(decl.loc, &"duplicate symbol '{decl.declInterfaceName}'")
      sema.typeTable[decl.declInterfaceName] = t
      # Register associated types as type parameters (they get substituted in impl)
      for assoc in decl.declInterfaceAssocTypes:
        sema.typeTable[assoc] = makeTypeParam(assoc)
    of dkImpl:
      # Register methods for the type
      let typeName = decl.declImplTypeName
      let implTypeParams = decl.declImplTypeParams
      if not sema.methodTable.hasKey(typeName):
        sema.methodTable[typeName] = @[]
      # If impl has type params, temporarily add them to type table
      var addedTypeParams: seq[string] = @[]
      for tp in implTypeParams:
        sema.typeTable[tp.name] = makeTypeParam(tp.name)
        addedTypeParams.add(tp.name)
      for methodDecl in decl.declImplMethods:
        if methodDecl.kind == dkFunc:
          # Propagate impl type params to method for HIR lowering
          if implTypeParams.len > 0:
            methodDecl.declFuncTypeParams = implTypeParams
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
          if implTypeParams.len > 0:
            # Register as generic function for monomorphization
            sym.decl = methodDecl
          discard sema.globalScope.define(sym)
      # Clean up type parameters
      for tp in addedTypeParams:
        sema.typeTable.del(tp)
    else:
      discard
  # Second pass: evaluate const declarations after all functions are registered
  for decl in sema.module.items:
    if decl.kind == dkConst:
      discard sema.constFoldConstDecl(decl)
  # Third pass: register imports after all real declarations are known
  for decl in sema.module.items:
    if decl.kind == dkUse:
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

# ---------------------------------------------------------------------------
# Expression type checking
# ---------------------------------------------------------------------------

proc checkExpr(sema: var Sema, expr: Expr, scope: Scope): Type
proc checkStmt(sema: var Sema, stmt: Stmt, scope: Scope): Type

proc typeImplements(sema: Sema, t: Type, interfaceName: string): bool =
  ## Check if a type implements an interface by verifying all required methods exist.
  if t.isUnknown: return true
  let typeName = if t.kind == tkNamed: t.name elif t.isPointer and t.inner.len > 0 and t.inner[0].kind == tkNamed: t.inner[0].name else: ""
  if typeName == "": return false
  if not sema.interfaceTable.hasKey(interfaceName):
    return true  # Unknown interface — be permissive in bootstrap
  let iface = sema.interfaceTable[interfaceName]
  let requiredMethods = iface.declInterfaceMethods
  if not sema.methodTable.hasKey(typeName):
    return false
  let availableMethods = sema.methodTable[typeName]
  for req in requiredMethods:
    var found = false
    for avail in availableMethods:
      if avail.name == req.declFuncName:
        found = true
        break
    if not found:
      return false
  # Check associated types (permissive in bootstrap — just check if impl has them)
  for assoc in iface.declInterfaceAssocTypes:
    var found = false
    # Look for impl block that provides this associated type
    # This is a simplified check; full impl lookup would require tracking impl blocks
    found = true  # Be permissive in bootstrap
    if not found:
      return false
  return true

proc checkTraitBounds(sema: var Sema, funcDecl: Decl, inferredTypes: seq[Type], loc: SourceLocation) =
  ## Verify that inferred types satisfy their trait bounds.
  for i, tp in funcDecl.declFuncTypeParams:
    if i < inferredTypes.len and inferredTypes[i] != nil:
      for bound in tp.bounds:
        if not sema.typeImplements(inferredTypes[i], bound):
          sema.emitError(loc, &"type '{inferredTypes[i].toString}' does not implement trait '{bound}'")

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

proc resolveCallArgs(sema: var Sema, expr: Expr, calleeDecl: Decl, scope: Scope) =
  ## Reorder named args and inject defaults for missing positional args.
  if expr.kind != ekCall or calleeDecl == nil or calleeDecl.kind != dkFunc:
    return
  let params = calleeDecl.declFuncParams
  let providedArgs = expr.exprCallArgs
  let providedNames = expr.exprCallArgNames
  if providedNames.len == 0:
    # All positional — just inject defaults for trailing missing args
    if providedArgs.len < params.len:
      var newArgs = providedArgs
      var newNames = providedNames
      for i in providedArgs.len ..< params.len:
        if params[i].defaultValue != nil:
          newArgs.add(params[i].defaultValue)
          newNames.add("")
        else:
          sema.emitError(expr.loc, &"missing argument for parameter '{params[i].name}'")
          break
      expr.exprCallArgs = newArgs
      expr.exprCallArgNames = newNames
    return
  # Named args present
  var newArgs: seq[Expr] = @[]
  var newNames: seq[string] = @[]
  var usedNamed = false
  var namedArgMap: Table[string, Expr]
  # Collect named args and validate ordering
  for i in 0 ..< providedArgs.len:
    if providedNames[i] != "":
      usedNamed = true
      if providedNames[i] in namedArgMap:
        sema.emitError(expr.loc, &"duplicate named argument '{providedNames[i]}'")
        return
      namedArgMap[providedNames[i]] = providedArgs[i]
    else:
      if usedNamed:
        sema.emitError(expr.loc, "positional argument after named argument")
        return
  # Build final arg list in param order
  for i in 0 ..< params.len:
    if i < providedArgs.len and providedNames[i] == "":
      # Positional arg at expected position
      newArgs.add(providedArgs[i])
      newNames.add("")
    elif params[i].name in namedArgMap:
      newArgs.add(namedArgMap[params[i].name])
      newNames.add("")
    elif params[i].defaultValue != nil:
      newArgs.add(params[i].defaultValue)
      newNames.add("")
    else:
      sema.emitError(expr.loc, &"missing argument for parameter '{params[i].name}'")
      break
  expr.exprCallArgs = newArgs
  expr.exprCallArgNames = newNames

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
    if sema.checkedFunc and expr.exprIdent in sema.movedVars:
      sema.emitError(expr.loc, &"use of moved value '{expr.exprIdent}'")
      return makeUnknown()
    let sym = scope.lookup(expr.exprIdent)
    if sym == nil:
      sema.emitError(expr.loc, &"undeclared identifier '{expr.exprIdent}'")
      return makeUnknown()
    if sym.typ == nil:
      return makeUnknown()
    # Capture tracking
    if sema.closureDepth > 0 and sema.currentClosureExpr != nil and sema.closureScope != nil:
      let localSym = scope.lookupUpTo(expr.exprIdent, sema.closureScope)
      if localSym == nil and sym.kind == skVar:
        if expr.exprIdent notin sema.currentClosureExpr.captureNames:
          sema.currentClosureExpr.captureNames.add(expr.exprIdent)
          sema.currentClosureExpr.captureTypeKinds.add(sym.typ.kind.int)
          sema.currentClosureExpr.captureCount = sema.currentClosureExpr.captureNames.len
    return sym.typ
  of ekSelf:
    let sym = scope.lookup("self")
    if sym != nil and sym.typ != nil:
      return sym.typ
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
      return makeMutRef(operandType)
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
    # Operator overloading: check method table before builtin rules
    let opMethodName = case expr.exprBinaryOp
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
    if opMethodName != "" and left.kind == tkNamed and sema.methodTable.hasKey(left.name):
      for minfo in sema.methodTable[left.name]:
        if minfo.name == opMethodName:
          # Validate argument count (self + other)
          if minfo.params.len == 2:
            let otherType = minfo.params[1]
            if right.isAssignableTo(otherType) or otherType.isAssignableTo(right) or right.kind == tkUnknown:
              return minfo.retType
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
    # Borrow check: reinitialization after move — must happen before checkExpr on target
    if sema.checkedFunc and expr.exprAssignTarget.kind == ekIdent:
      let movedIdx = sema.movedVars.find(expr.exprAssignTarget.exprIdent)
      if movedIdx >= 0:
        sema.movedVars.delete(movedIdx)
    let target = sema.checkExpr(expr.exprAssignTarget, scope)
    let value = sema.checkExpr(expr.exprAssignValue, scope)
    if not value.isAssignableTo(target):
      sema.emitError(expr.loc, &"cannot assign {value.toString} to {target.toString}")
    # Borrow check: cannot write through &T (shared reference) in @[Checked] functions
    if sema.checkedFunc and expr.exprAssignTarget.kind == ekUnary and expr.exprAssignTarget.exprUnaryOp == tkStar:
      let ptrType = sema.checkExpr(expr.exprAssignTarget.exprUnaryOperand, scope)
      if ptrType.isRef:
        sema.emitError(expr.loc, "cannot assign through shared reference '&T' in checked function — use '&mut T' instead")
    # Borrow check: move tracking in assignment
    if sema.checkedFunc:
      if expr.exprAssignValue.kind == ekIdent:
        let valSym = scope.lookup(expr.exprAssignValue.exprIdent)
        if valSym != nil and valSym.isOwn:
          sema.movedVars.add(expr.exprAssignValue.exprIdent)
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
    var rangeType: Type = lo
    if lo == hi:
      rangeType = lo
    elif lo.isAssignableTo(hi):
      rangeType = hi
    elif hi.isAssignableTo(lo):
      rangeType = lo
    else:
      sema.emitError(expr.loc, "range bounds must have same type")
    return makeRange(rangeType)
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
        let retType = sym.typ.inner[^1]
        let sym2 = sema.globalScope.lookup(expr.exprCallCallee.exprGenericCallee)
        if sym2 != nil and sym2.decl != nil and sym2.decl.kind == dkFunc and
           sym2.decl.declFuncTypeParams.len > 0 and
           sym2.decl.declFuncReturnType != nil:
          let typeParams = sym2.decl.declFuncTypeParams
          var added: seq[string] = @[]
          for i, tp in typeParams:
            if i < expr.exprCallCallee.exprGenericTypeArgs.len:
              let concrete = sema.resolveType(expr.exprCallCallee.exprGenericTypeArgs[i])
              sema.typeTable[tp.name] = concrete
              added.add(tp.name)
          let resolvedRet = sema.resolveType(sym2.decl.declFuncReturnType)
          for tp in added:
            sema.typeTable.del(tp)
          return resolvedRet
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
      elif receiver.kind in {tkInt, tkInt8, tkInt16, tkInt32, tkInt64,
                             tkUInt, tkUInt8, tkUInt16, tkUInt32, tkUInt64,
                             tkFloat32, tkFloat64, tkBool, tkStr, tkChar8}:
        typeName = receiver.toString
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
                  if not argTypes[i].isAssignableTo(expectedParams[paramIdx]) and not (argTypes[i].kind in {TypeKind.tkUnknown, TypeKind.tkNamed, TypeKind.tkTypeParam}):
                    sema.emitError(expr.loc, &"argument {i+1}: expected {expectedParams[paramIdx].toString}, got {argTypes[i].toString}")
            return minfo.retType
      
      # Trait object virtual method call: &dyn Trait
      if receiver.kind == tkDynRef:
        let ifaceName = receiver.name
        if sema.interfaceTable.hasKey(ifaceName):
          let iface = sema.interfaceTable[ifaceName]
          for m in iface.declInterfaceMethods:
            if m.declFuncName == methodName:
              var paramTypes: seq[Type] = @[]
              for p in m.declFuncParams:
                paramTypes.add(sema.resolveType(p.ptype))
              if argTypes.len + 1 < paramTypes.len:
                sema.emitError(expr.loc, &"too few arguments for method '{methodName}'")
              elif argTypes.len > paramTypes.len:
                sema.emitError(expr.loc, &"too many arguments for method '{methodName}'")
              else:
                for i in 0 ..< argTypes.len:
                  let paramIdx = i + 1
                  if paramIdx < paramTypes.len:
                    if not argTypes[i].isAssignableTo(paramTypes[paramIdx]) and not (argTypes[i].kind in {TypeKind.tkUnknown, TypeKind.tkNamed, TypeKind.tkTypeParam}):
                      sema.emitError(expr.loc, &"argument {i+1}: expected {paramTypes[paramIdx].toString}, got {argTypes[i].toString}")
              return if m.declFuncReturnType != nil: sema.resolveType(m.declFuncReturnType) else: makeVoid()
      
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
    # Look up callee declaration early (needed for borrow checking and defaults)
    var calleeDecl: Decl = nil
    case expr.exprCallCallee.kind
    of ekIdent:
      let sym = scope.lookup(expr.exprCallCallee.exprIdent)
      if sym != nil: calleeDecl = sym.decl
    of ekPath:
      let fullName = expr.exprCallCallee.exprPath.join("::")
      let sym = scope.lookup(fullName)
      if sym != nil: calleeDecl = sym.decl
    else: discard
    # Resolve named args and inject defaults before type-checking args
    sema.resolveCallArgs(expr, calleeDecl, scope)
    var argTypes = sema.checkExprList(expr.exprCallArgs, scope)
    let isGenericFunc = calleeDecl != nil and calleeDecl.kind == dkFunc and calleeDecl.declFuncTypeParams.len > 0
    if calleeType.kind == tkFunc:
      let expectedParams = calleeType.inner[0..^2]
      if argTypes.len != expectedParams.len:
        sema.emitError(expr.loc, &"expected {expectedParams.len} arguments, got {argTypes.len}")
      elif not isGenericFunc:
        # Generic function arg checks are deferred until after type inference/monomorphization.
        for i in 0 ..< argTypes.len:
          if not argTypes[i].isAssignableTo(expectedParams[i]) and not (argTypes[i].kind in {TypeKind.tkUnknown, TypeKind.tkNamed, TypeKind.tkTypeParam}):
            sema.emitError(expr.loc, &"argument {i+1}: expected {expectedParams[i].toString}, got {argTypes[i].toString}")

        # Borrow check: reject double mutable borrow (alias analysis)
        if sema.checkedFunc:
          var mutRefArgs: seq[tuple[idx: int, name: string]] = @[]
          for i in 0 ..< argTypes.len:
            if expectedParams[i].isMutRef and i < expr.exprCallArgs.len:
              let arg = expr.exprCallArgs[i]
              if arg.kind == ekUnary and arg.exprUnaryOp == tkAmp and arg.exprUnaryOperand.kind == ekIdent:
                mutRefArgs.add((idx: i, name: arg.exprUnaryOperand.exprIdent))
          for i in 0 ..< mutRefArgs.len:
            for j in i+1 ..< mutRefArgs.len:
              if mutRefArgs[i].name == mutRefArgs[j].name:
                sema.emitError(expr.loc, &"mutable borrow conflict: arguments {mutRefArgs[i].idx+1} and {mutRefArgs[j].idx+1} both borrow '&mut {mutRefArgs[i].name}'")

          # Borrow check: track moved variables (own T)
          if calleeDecl != nil and calleeDecl.kind == dkFunc:
            for i in 0 ..< argTypes.len:
              if i < calleeDecl.declFuncParams.len and i < expr.exprCallArgs.len:
                if calleeDecl.declFuncParams[i].ptype.kind == tekOwn:
                  let arg = expr.exprCallArgs[i]
                  if arg.kind == ekIdent:
                    sema.movedVars.add(arg.exprIdent)

      # Check for inferred generic function call (no explicit type args)

      if calleeDecl != nil and calleeDecl.kind == dkFunc and
         calleeDecl.declFuncTypeParams.len > 0 and
         expr.exprCallInferredTypeArgs.len == 0 and
         expr.exprCallCallee.kind != ekGenericCall:
        let inferred = sema.inferTypeArgs(calleeDecl, argTypes, expr.loc)
        if inferred.len == calleeDecl.declFuncTypeParams.len:
          expr.exprCallInferredTypeArgs = inferred
          # Check trait bounds
          var inferredTypes: seq[Type] = @[]
          for te in inferred:
            inferredTypes.add(sema.resolveType(te))
          sema.checkTraitBounds(calleeDecl, inferredTypes, expr.loc)
          # Substitute return type using inferred type args
          if calleeDecl.declFuncReturnType != nil:
            var added: seq[string] = @[]
            for i, tp in calleeDecl.declFuncTypeParams:
              if i < inferred.len:
                let concrete = sema.resolveType(inferred[i])
                sema.typeTable[tp.name] = concrete
                added.add(tp.name)
            let retType = sema.resolveType(calleeDecl.declFuncReturnType)
            for tp in added:
              sema.typeTable.del(tp)
            return retType

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

    # Try method-table operator_index_get on a named receiver (possibly behind a pointer).
    var receiverNamed: Type = nil
    if obj.kind == tkNamed:
      receiverNamed = obj
    elif obj.isPointer and obj.inner.len > 0 and obj.inner[0].kind == tkNamed:
      receiverNamed = obj.inner[0]

    if receiverNamed != nil and sema.methodTable.hasKey(receiverNamed.name):
      for minfo in sema.methodTable[receiverNamed.name]:
        if minfo.name == "operator_index_get" and minfo.params.len == 2:
          var subst = initTable[string, Type]()
          if minfo.decl.declFuncTypeParams.len > 0 and receiverNamed.inner.len > 0:
            for i, tp in minfo.decl.declFuncTypeParams:
              if i < receiverNamed.inner.len:
                subst[tp.name] = receiverNamed.inner[i]
          let idxType = sema.substituteTypeInType(minfo.params[1], subst)
          if idx.isAssignableTo(idxType) or idxType.isAssignableTo(idx) or idx.kind == tkUnknown:
            return sema.substituteTypeInType(minfo.retType, subst)

    if obj.isSlice:
      if sema.checkedFunc:
        expr.exprIndexBoundsCheck = true
      return obj.inner[0]
    elif obj.isPointer:
      return obj.inner[0]
    elif obj.kind == tkStr:
      return makeChar8()
    else:
      sema.emitError(expr.loc, "cannot index non-slice/non-pointer type")
      return makeUnknown()
  of ekField:
    let obj = sema.checkExpr(expr.exprFieldObj, scope)
    var objType = obj
    # Auto-dereference pointer/reference types for field access
    if objType.kind in {tkPointer, tkRef, tkMutRef} and objType.inner.len > 0:
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
            var subst = initTable[string, Type]()
            for i, tp in sym.decl.declStructTypeParams:
              if i < objType.inner.len:
                subst[tp.name] = objType.inner[i]
            for f in sym.decl.declStructFields:
              if f.name == expr.exprFieldName:
                return sema.substituteTypeInType(sema.resolveType(f.ftype), subst)
            sema.emitError(expr.loc, &"struct '{objType.name}' has no field '{expr.exprFieldName}'")
          elif sym.decl.kind == dkEnum:
            # Algebraic enum fields
            var hasData = false
            for v in sym.decl.declEnumVariants:
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
              sema.emitError(expr.loc, &"enum '{objType.name}' has no field '{expr.exprFieldName}'")
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
    elif objType.kind == tkDynRef:
      # Trait object: methods come from the interface
      let ifaceName = objType.name
      if sema.interfaceTable.hasKey(ifaceName):
        let iface = sema.interfaceTable[ifaceName]
        for m in iface.declInterfaceMethods:
          if m.declFuncName == expr.exprFieldName:
            # Build function type from method signature
            var paramTypes: seq[Type] = @[]
            for p in m.declFuncParams:
              paramTypes.add(sema.resolveType(p.ptype))
            let retType = if m.declFuncReturnType != nil: sema.resolveType(m.declFuncReturnType) else: makeVoid()
            return makeFunc(paramTypes, retType)
        sema.emitError(expr.loc, &"interface '{ifaceName}' has no method '{expr.exprFieldName}'")
      else:
        sema.emitError(expr.loc, &"unknown interface '{ifaceName}'")
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
  of ekTry:
    discard sema.checkExpr(expr.exprTryOperand, scope)
    # For now, assume Result<int, String> -> int
    # TODO: check operand is Result/Option and current function returns same type
    return makeInt()
  of ekUnwrap:
    discard sema.checkExpr(expr.exprUnwrapOperand, scope)
    # Unwrap: extract Ok value or panic on Err
    return makeInt()
  of ekBlock:
    var blockScope = newScope(scope)
    var lastType = makeVoid()
    for stmt in expr.exprBlock.stmts:
      lastType = sema.checkStmt(stmt, blockScope)
    return lastType
  of ekMatch:
    discard sema.checkExpr(expr.exprMatchSubject, scope)
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
  of ekSpawn:
    discard sema.checkExpr(expr.exprSpawnCallee, scope)
    for arg in expr.exprSpawnArgs:
      discard sema.checkExpr(arg, scope)
    # Determine if callee is async
    var calleeName = ""
    case expr.exprSpawnCallee.kind
    of ekIdent:
      calleeName = expr.exprSpawnCallee.exprIdent
    of ekPath:
      calleeName = expr.exprSpawnCallee.exprPath.join("_")
    else: discard
    if calleeName != "":
      let sym = sema.globalScope.lookup(calleeName)
      if sym != nil and sym.decl != nil and sym.decl.kind == dkFunc and sym.decl.declFuncIsAsync:
        expr.exprSpawnAsync = true
    return makePointer(makeVoid())
  of ekAwait:
    discard sema.checkExpr(expr.exprAwaitOperand, scope)
    # await on a task handle returns *void (result pointer)
    return makePointer(makeVoid())
  of ekBorrow:
    let operand = sema.checkExpr(expr.exprBorrowOperand, scope)
    # borrow &mut expr returns the same type as the original (reference)
    # The borrow is tracked in the borrow checker
    if sema.checkedFunc and expr.exprBorrowMutable:
      # Track: variable "operand" is mutably borrowed here
      # For now, just validate the type
      discard
    return operand
  of ekSpread:
    return sema.checkExpr(expr.exprSpreadOperand, scope)
  of ekStringInterp:
    for e in expr.exprInterpExprs:
      discard sema.checkExpr(e, scope)
    return makeStr()
  of ekClosure:
    let savedRetType = sema.currentRetType
    let savedClosureDepth = sema.closureDepth
    let savedClosureExpr = sema.currentClosureExpr
    let savedClosureScope = sema.closureScope
    let childScope = Scope(parent: scope)
    sema.closureDepth = sema.closureDepth + 1
    sema.currentClosureExpr = expr
    sema.closureScope = childScope
    expr.captureCount = 0
    expr.captureNames = @[]
    expr.captureTypeKinds = @[]
    sema.currentRetType = if expr.exprClosureReturnType != nil: sema.resolveType(expr.exprClosureReturnType) else: makeUnknown()
    # Register params
    for p in expr.exprClosureParams:
      let ptype = if p.ptype != nil: sema.resolveType(p.ptype) else: makeUnknown()
      discard childScope.define(Symbol(kind: skVar, name: p.name, typ: ptype))
    # Check body
    if expr.exprClosureBody != nil:
      for stmt in expr.exprClosureBody.stmts:
        discard sema.checkStmt(stmt, childScope)
    sema.currentRetType = savedRetType
    sema.closureDepth = savedClosureDepth
    sema.currentClosureExpr = savedClosureExpr
    sema.closureScope = savedClosureScope
    # Build function type
    var params: seq[Type] = @[]
    for p in expr.exprClosureParams:
      params.add(if p.ptype != nil: sema.resolveType(p.ptype) else: makeUnknown())
    let retType = if expr.exprClosureReturnType != nil: sema.resolveType(expr.exprClosureReturnType) else: makeVoid()
    return makeFunc(params, retType)

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
    var initType: Type = makeVoid()
    if stmt.stmtLetInit != nil:
      initType = sema.checkExpr(stmt.stmtLetInit, scope)
    let declaredType = if stmt.stmtLetType != nil: sema.resolveType(stmt.stmtLetType) else: initType
    if stmt.stmtLetInit != nil and stmt.stmtLetType != nil and not initType.isAssignableTo(declaredType) and not (initType.kind in {TypeKind.tkUnknown, TypeKind.tkNamed, TypeKind.tkTypeParam}):
      sema.emitError(stmt.loc, &"cannot assign {initType.toString} to {declaredType.toString}")
    if stmt.stmtLetInit == nil and stmt.stmtLetType == nil:
      sema.emitError(stmt.loc, "variable must have either type annotation or initializer")
    let isOwnVar = stmt.stmtLetType != nil and stmt.stmtLetType.kind == tekOwn
    let sym = Symbol(kind: skVar, name: stmt.stmtLetName, typ: declaredType,
                     isMutable: stmt.stmtLetMut, isOwn: isOwnVar)
    if not scope.define(sym):
      sema.emitError(stmt.loc, &"duplicate variable '{stmt.stmtLetName}'")
    # Borrow check: move tracking in let/var initialization
    if sema.checkedFunc and stmt.stmtLetInit != nil and stmt.stmtLetInit.kind == ekIdent:
      let initSym = scope.lookup(stmt.stmtLetInit.exprIdent)
      if initSym != nil and initSym.isOwn:
        sema.movedVars.add(stmt.stmtLetInit.exprIdent)
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
    let iterExpr = stmt.stmtForIter
    let collType = sema.checkExpr(iterExpr, scope)
    var forScope = newScope(scope)
    var iterTyp = makeUnknown()
    if iterExpr.kind == ekRange:
      iterTyp = sema.checkExpr(iterExpr.exprRangeLo, scope)
    elif collType.kind == tkNamed and collType.inner.len > 0:
      iterTyp = collType.inner[0]
    elif collType.isPointer and collType.inner.len > 0 and collType.inner[0].kind == tkNamed and collType.inner[0].inner.len > 0:
      iterTyp = collType.inner[0].inner[0]
    let iterSym = Symbol(kind: skVar, name: stmt.stmtForVar, typ: iterTyp, isMutable: true)
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
      if sema.checkedFunc and stmt.stmtReturnValue.kind == ekIdent:
        let retSym = scope.lookup(stmt.stmtReturnValue.exprIdent)
        if retSym != nil and retSym.isOwn:
          sema.movedVars.add(stmt.stmtReturnValue.exprIdent)
    return makeVoid()
  of skBreak, skContinue:
    return makeVoid()
  of skStaticAssert:
    let condType = sema.checkExpr(stmt.stmtStaticAssertCond, scope)
    if not condType.isBool:
      sema.emitError(stmt.loc, "static_assert condition must be bool")
    let condVal = sema.evalExpr(stmt.stmtStaticAssertCond, initTable[string, CtValue]())
    if condVal.kind == ctkBool and not condVal.boolVal:
      var msg = "static assertion failed"
      if stmt.stmtStaticAssertMsg != nil:
        let msgVal = sema.evalExpr(stmt.stmtStaticAssertMsg, initTable[string, CtValue]())
        if msgVal.kind == ctkString:
          msg = msgVal.strVal
      sema.emitError(stmt.loc, msg)
    return makeVoid()
  of skComptime:
    discard sema.evalBlock(stmt.stmtComptimeBlock, initTable[string, CtValue]())
    return makeVoid()
  of skEmit:
    let exprType = sema.checkExpr(stmt.stmtEmitExpr, scope)
    # Try to evaluate at compile time; if it evaluates to a string, we're good
    let val = sema.evalExpr(stmt.stmtEmitExpr, initTable[string, CtValue]())
    if val.kind == ctkString:
      stmt.stmtEmitEvaluated = val.strVal
    elif not exprType.isUnknown and exprType.kind != tkStr:
      sema.emitError(stmt.loc, "#emit requires a string expression")
    return makeVoid()
  of skDefer:
    discard sema.checkExpr(stmt.stmtDeferBody, scope)
    return makeVoid()
  of skSwitch:
    discard sema.checkExpr(stmt.stmtSwitchExpr, scope)
    for caseBranch in stmt.stmtSwitchCases:
      discard sema.checkExpr(caseBranch.caseValue, scope)
      discard sema.checkStmt(Stmt(kind: skExpr, loc: caseBranch.caseBody.loc, stmtExpr: Expr(kind: ekBlock, loc: caseBranch.caseBody.loc, exprBlock: caseBranch.caseBody)), scope)
    if stmt.stmtSwitchDefault != nil:
      discard sema.checkStmt(Stmt(kind: skExpr, loc: stmt.stmtSwitchDefault.loc, stmtExpr: Expr(kind: ekBlock, loc: stmt.stmtSwitchDefault.loc, exprBlock: stmt.stmtSwitchDefault)), scope)
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
  # Skip body type-checking for generic functions — their bodies contain
  # type parameters that cannot be fully resolved until monomorphization.
  if decl.declFuncTypeParams.len > 0:
    return
  let wasChecked = sema.checkedFunc
  let wasAsync = sema.currentFuncIsAsync
  sema.checkedFunc = "Checked" in decl.declAttrs
  sema.currentFuncIsAsync = decl.declFuncIsAsync
  if sema.checkedFunc:
    sema.movedVars = @[]
  var funcScope = newScope(sema.globalScope)
  # Add type parameters to type table for resolution
  var addedTypeParams: seq[string] = @[]
  for tp in decl.declFuncTypeParams:
    sema.typeTable[tp.name] = makeTypeParam(tp.name)
    addedTypeParams.add(tp.name)
  # Add parameters
  for p in decl.declFuncParams:
    let pType = sema.resolveType(p.ptype)
    let sym = Symbol(kind: skVar, name: p.name, typ: pType, isMutable: false)
    discard funcScope.define(sym)
  # Check body statements
  for stmt in decl.declFuncBody.stmts:
    discard sema.checkStmt(stmt, funcScope)
  # Clean up type parameters
  for tp in addedTypeParams:
    sema.typeTable.del(tp)
  sema.checkedFunc = wasChecked
  sema.currentFuncIsAsync = wasAsync

# ---------------------------------------------------------------------------
# Second pass: check all function bodies
# ---------------------------------------------------------------------------

proc checkBodies(sema: var Sema) =
  # Bootstrap optimization: skip body checking for large modules
  # Only check Main function — other functions are trusted
  var funcCount = 0
  for decl in sema.module.items:
    if decl.kind == dkFunc: inc funcCount
  if funcCount > 5000:
    # Large module — only check Main
    for decl in sema.module.items:
      case decl.kind
      of dkFunc:
        if decl.declFuncName == "Main":
          sema.checkFunc(decl)
      else: discard
    return
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
