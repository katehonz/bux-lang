import std/[strformat, tables, strutils, sets]
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
    checkedFunc*: bool  ## true inside @[Checked] and not @[Release]
    releaseFunc*: bool  ## true inside @[Release] (zero-cost: no borrow checks)
    currentFuncIsAsync*: bool  ## true inside async func
    movedVars*: seq[string]  ## variables moved in current checked function
    ## Active exclusive borrows: source var → borrow site (let-bound &mut lasts for rest of fn)
    activeMutBorrows*: Table[string, SourceLocation]
    ## Active shared borrows of a source var (count of live &T lets)
    activeSharedBorrows*: Table[string, int]
    ## When true, ekIdent skips use-while-borrowed (we're forming `&x` itself)
    suppressUseWhileBorrow*: bool
    currentRetType*: Type    ## return type of the function being checked
    ## Lifetime elision / ref-origin tracking (@[Checked] only)
    ## Binding name → lifetime id ("'a", "#elided0", "#local", …)
    varRefLifetime*: Table[string, string]
    ## Expected lifetime of the function's returned reference ("" if ret is not a ref)
    returnLifetime*: string
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
# Borrow checker helpers (@[Checked] exclusive &mut / shared & data-flow)
# ---------------------------------------------------------------------------

proc extractBorrowedIdent*(e: Expr): string =
  ## Identify the source variable of `&x`, `borrow x`, `borrow &mut x`, etc.
  if e == nil: return ""
  case e.kind
  of ekUnary:
    if e.exprUnaryOp == tkAmp and e.exprUnaryOperand != nil:
      if e.exprUnaryOperand.kind == ekIdent:
        return e.exprUnaryOperand.exprIdent
      if e.exprUnaryOperand.kind == ekUnary and e.exprUnaryOperand.exprUnaryOp == tkAmp and
         e.exprUnaryOperand.exprUnaryOperand != nil and
         e.exprUnaryOperand.exprUnaryOperand.kind == ekIdent:
        return e.exprUnaryOperand.exprUnaryOperand.exprIdent
  of ekBorrow:
    return extractBorrowedIdent(e.exprBorrowOperand)
  else:
    discard
  return ""

proc checkCreateBorrow(sema: var Sema, varName: string, isMut: bool, loc: SourceLocation) =
  ## Register a long-lived (let-bound) borrow of `varName` in a @[Checked] function.
  if not sema.checkedFunc or varName.len == 0:
    return
  if isMut:
    if sema.activeMutBorrows.hasKey(varName):
      sema.emitError(loc, &"cannot mutably borrow '{varName}': already mutably borrowed")
      return
    if sema.activeSharedBorrows.getOrDefault(varName, 0) > 0:
      sema.emitError(loc, &"cannot mutably borrow '{varName}' while it is shared-borrowed")
      return
    sema.activeMutBorrows[varName] = loc
  else:
    if sema.activeMutBorrows.hasKey(varName):
      sema.emitError(loc, &"cannot shared-borrow '{varName}' while it is mutably borrowed")
      return
    sema.activeSharedBorrows[varName] = sema.activeSharedBorrows.getOrDefault(varName, 0) + 1

proc checkUseWhileBorrowed(sema: var Sema, varName: string, loc: SourceLocation, isWrite: bool) =
  ## Reject uses of a variable that has an active exclusive (&mut) borrow.
  if not sema.checkedFunc or varName.len == 0 or sema.suppressUseWhileBorrow:
    return
  if sema.activeMutBorrows.hasKey(varName):
    let kind = if isWrite: "assign to" else: "use"
    sema.emitError(loc, &"cannot {kind} '{varName}' while it is mutably borrowed")

proc checkTempMutBorrow(sema: var Sema, varName: string, loc: SourceLocation) =
  ## Temporary &mut in a call argument — conflict with existing long-lived borrows.
  if not sema.checkedFunc or varName.len == 0:
    return
  if sema.activeMutBorrows.hasKey(varName):
    sema.emitError(loc, &"cannot mutably borrow '{varName}': already mutably borrowed")
  elif sema.activeSharedBorrows.getOrDefault(varName, 0) > 0:
    sema.emitError(loc, &"cannot mutably borrow '{varName}' while it is shared-borrowed")

# ---------------------------------------------------------------------------
# Lifetime elision (C.1) — Rust-style simple rules for @[Checked]
# ---------------------------------------------------------------------------
#
# Rules (common cases, no annotations required):
#   1. Each elided input reference (&T / &mut T param) gets a distinct lifetime.
#   2. If there is exactly one input lifetime, it is assigned to all elided outputs.
#   3. If the first param is `self` / `Self`, its lifetime is preferred for outputs.
#   4. Multiple input refs + elided return → error (need explicit `'a`).
#   5. Returning a reference derived from a local (or by-value param) is rejected.
#

const
  LifetimeLocal* = "#local"       ## ref derived from a local / by-value place
  LifetimeOutNone* = "#out"       ## return ref with no input to borrow from
  LifetimeAmbiguous* = "#ambiguous"

proc isRefTypeExpr(te: TypeExpr): bool =
  te != nil and te.kind in {tekRef, tekMutRef}

proc applyLifetimeElision*(sema: var Sema, decl: Decl) =
  ## Assign elided lifetimes for ref params/return of `decl`. Populates
  ## `varRefLifetime` (params) and `returnLifetime`.
  sema.varRefLifetime = initTable[string, string]()
  sema.returnLifetime = ""
  if not sema.checkedFunc:
    return

  var inputLts: seq[string] = @[]
  var anon = 0
  for p in decl.declFuncParams:
    if not isRefTypeExpr(p.ptype):
      continue
    var lt = p.ptype.refLifetime
    if lt.len == 0:
      lt = "#elided" & $anon
      inc anon
    inputLts.add(lt)
    sema.varRefLifetime[p.name] = lt

  let ret = decl.declFuncReturnType
  if not isRefTypeExpr(ret):
    return

  var rlt = ret.refLifetime
  if rlt.len == 0:
    if inputLts.len == 1:
      rlt = inputLts[0]
    elif inputLts.len == 0:
      rlt = LifetimeOutNone
    elif decl.declFuncParams.len > 0 and
         decl.declFuncParams[0].name in ["self", "Self"]:
      rlt = inputLts[0]
    else:
      sema.emitError(decl.loc,
        "lifetime elision failed: return type needs an explicit lifetime " &
        "(multiple input references); e.g. func F<'a>(a: &'a T, b: &'a U) -> &'a T")
      rlt = LifetimeAmbiguous
  sema.returnLifetime = rlt

proc exprRefLifetime*(sema: Sema, expr: Expr, scope: Scope): string =
  ## Best-effort lifetime of a reference-producing expression.
  if expr == nil:
    return ""
  case expr.kind
  of ekIdent:
    if sema.varRefLifetime.hasKey(expr.exprIdent):
      return sema.varRefLifetime[expr.exprIdent]
    return ""
  of ekUnary:
    if expr.exprUnaryOp == tkAmp:
      let name = extractBorrowedIdent(expr)
      if name.len == 0:
        return LifetimeLocal
      # Reborrow of an existing ref binding keeps its lifetime
      if sema.varRefLifetime.hasKey(name):
        return sema.varRefLifetime[name]
      # Address-of a by-value local or by-value parameter → local (dangling if returned)
      return LifetimeLocal
    # Dereference: *r still carries r's lifetime for field/ref purposes
    if expr.exprUnaryOp == tkStar:
      return sema.exprRefLifetime(expr.exprUnaryOperand, scope)
    return ""
  of ekBorrow:
    # `borrow &x` / `borrow &mut x` — same origin rules as unary &
    if expr.exprBorrowOperand != nil:
      return sema.exprRefLifetime(expr.exprBorrowOperand, scope)
    return LifetimeLocal
  of ekField:
    # Field projection through a ref keeps the base lifetime: (*p).x or p.x
    if expr.exprFieldObj != nil:
      let baseLt = sema.exprRefLifetime(expr.exprFieldObj, scope)
      if baseLt.len > 0:
        return baseLt
      # Base is an ident of a struct local — field address would be local
      if expr.exprFieldObj.kind == ekIdent:
        if sema.varRefLifetime.hasKey(expr.exprFieldObj.exprIdent):
          return sema.varRefLifetime[expr.exprFieldObj.exprIdent]
        return LifetimeLocal
    return ""
  else:
    return ""

proc checkReturnLifetime*(sema: var Sema, retExpr: Expr, scope: Scope, loc: SourceLocation) =
  ## Reject dangling returns and explicit lifetime mismatches in @[Checked].
  if not sema.checkedFunc or sema.returnLifetime.len == 0 or retExpr == nil:
    return
  let got = sema.exprRefLifetime(retExpr, scope)
  if sema.returnLifetime == LifetimeOutNone:
    sema.emitError(loc,
      "cannot return a reference: function has no input reference to borrow from")
    return
  if got == LifetimeLocal:
    sema.emitError(loc, "cannot return reference to local variable")
    return
  if got.len == 0:
    # Non-trivial expression (call, etc.) — leave for later analysis
    return
  if got == LifetimeAmbiguous or sema.returnLifetime == LifetimeAmbiguous:
    return
  # Explicit lifetime mismatch (both sides named with ')
  if got.startsWith("'") and sema.returnLifetime.startsWith("'") and got != sema.returnLifetime:
    sema.emitError(loc,
      &"lifetime mismatch: returning '{got}' but function returns '{sema.returnLifetime}'")
    return
  # Distinct elided inputs returned into another elided input's return slot
  if got.startsWith("#elided") and sema.returnLifetime.startsWith("#elided") and
     got != sema.returnLifetime:
    sema.emitError(loc,
      "lifetime mismatch: returned reference does not outlive the return type " &
      "(multiple input references; annotate with an explicit lifetime)")

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
  of tkFunc:
    var params: seq[TypeExpr] = @[]
    if t.inner.len > 0:
      for i in 0 ..< t.inner.len - 1:
        params.add(typeToTypeExpr(t.inner[i]))
      let ret = typeToTypeExpr(t.inner[^1])
      return TypeExpr(kind: tekFunc, funcParams: params, funcRet: ret)
    TypeExpr(kind: tekNamed, typeName: "void")
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

proc unifyTypeParam(sema: var Sema, pattern: TypeExpr, concrete: Type,
                    tpNames: HashSet[string],
                    bindings: var Table[string, Type],
                    loc: SourceLocation): bool =
  ## Structural match of a parameter TypeExpr against a concrete argument Type.
  ## Binds type parameters (names in `tpNames`) into `bindings`.
  ## Returns false on hard mismatch; true when matching succeeds (unknowns ok).
  if pattern == nil:
    return true
  if concrete == nil or concrete.isUnknown:
    return true

  case pattern.kind
  of tekNamed:
    let name = pattern.typeName
    # Bare type parameter: T
    if name in tpNames and pattern.typeArgs.len == 0:
      if bindings.hasKey(name):
        let prev = bindings[name]
        if prev == concrete:
          return true
        if concrete.isAssignableTo(prev):
          return true
        if prev.isAssignableTo(concrete):
          bindings[name] = concrete
          return true
        sema.emitError(loc,
          &"conflicting types for type parameter '{name}': " &
          &"{prev.toString} vs {concrete.toString}")
        return false
      bindings[name] = concrete
      return true
    # Named type with type args: Iter<T>, Array<U>, Map<K,V>
    if pattern.typeArgs.len > 0:
      if concrete.kind != tkNamed:
        return false
      # Allow monomorphized names like Iter_int? Prefer structural Iter + inner.
      if concrete.name != name and not concrete.name.startsWith(name & "_"):
        return false
      if concrete.name == name:
        if concrete.inner.len < pattern.typeArgs.len:
          return false
        for i, ta in pattern.typeArgs:
          if i >= concrete.inner.len: break
          if not sema.unifyTypeParam(ta, concrete.inner[i], tpNames, bindings, loc):
            return false
        return true
      # Monomorphized form Iter_int — best-effort: only if single type arg
      if pattern.typeArgs.len == 1 and concrete.name.startsWith(name & "_"):
        let suffix = concrete.name[name.len + 1 .. ^1]
        # Only bind if pattern arg is a type param
        let ta = pattern.typeArgs[0]
        if ta != nil and ta.kind == tekNamed and ta.typeName in tpNames and ta.typeArgs.len == 0:
          let mono = makeNamed(suffix)
          # Prefer known primitives
          let prim =
            case suffix
            of "int": makeInt()
            of "bool": makeBool()
            of "String", "str": makeStr()
            of "float", "float64": makeFloat64()
            else: mono
          return sema.unifyTypeParam(ta, prim, tpNames, bindings, loc)
      return false
    # Concrete named type (not a param): int, String, Foo / primitives
    let expected =
      case name
      of "int": makeInt()
      of "int8": makeInt8()
      of "int16": makeInt16()
      of "int32": makeInt32()
      of "int64": makeInt64()
      of "uint": makeUInt()
      of "uint8": makeUInt8()
      of "uint16": makeUInt16()
      of "uint32": makeUInt32()
      of "uint64": makeUInt64()
      of "bool": makeBool()
      of "float", "float64": makeFloat64()
      of "float32": makeFloat32()
      of "String", "str": makeStr()
      of "void": makeVoid()
      else: makeNamed(name)
    if concrete == expected:
      return true
    if concrete.kind == tkNamed and expected.kind == tkNamed:
      return concrete.name == expected.name
    return concrete.isAssignableTo(expected) or expected.isAssignableTo(concrete)

  of tekPointer, tekOwn:
    if not concrete.isPointer or concrete.inner.len == 0:
      return false
    return sema.unifyTypeParam(pattern.pointerPointee, concrete.inner[0], tpNames, bindings, loc)

  of tekRef, tekMutRef:
    if not concrete.isPointer or concrete.inner.len == 0:
      return false
    return sema.unifyTypeParam(pattern.pointerPointee, concrete.inner[0], tpNames, bindings, loc)

  of tekFunc:
    # concrete: tkFunc with inner = params ++ [ret]
    if concrete.kind != tkFunc:
      return false
    let nParams = pattern.funcParams.len
    if concrete.inner.len != nParams + 1:
      # Allow fat-func mismatch length if unknown
      return false
    for i, p in pattern.funcParams:
      if not sema.unifyTypeParam(p, concrete.inner[i], tpNames, bindings, loc):
        return false
    if pattern.funcRet != nil:
      if not sema.unifyTypeParam(pattern.funcRet, concrete.inner[^1], tpNames, bindings, loc):
        return false
    return true

  of tekSlice:
    if not concrete.isSlice or concrete.inner.len == 0:
      return false
    return sema.unifyTypeParam(pattern.sliceElement, concrete.inner[0], tpNames, bindings, loc)

  of tekTuple:
    if concrete.kind != tkTuple or concrete.inner.len != pattern.tupleElements.len:
      return false
    for i, elem in pattern.tupleElements:
      if not sema.unifyTypeParam(elem, concrete.inner[i], tpNames, bindings, loc):
        return false
    return true

  of tekPath, tekDynRef, tekSelf:
    return true  # best-effort skip

proc inferTypeArgs(sema: var Sema, funcDecl: Decl, argTypes: seq[Type],
                   loc: SourceLocation): seq[TypeExpr] =
  ## Infer type arguments from argument types for a generic function call.
  ## Uses structural matching so `*Iter<T>` + `func(T)->U` yield T and U.
  ## Returns empty seq if inference fails for any type parameter.
  result = @[]
  var tpNames = initHashSet[string]()
  for tp in funcDecl.declFuncTypeParams:
    if not tp.isLifetime:
      tpNames.incl(tp.name)

  var bindings = initTable[string, Type]()

  # Lifetime params: mark as found if any ref param uses them
  for tp in funcDecl.declFuncTypeParams:
    if tp.isLifetime:
      var found = false
      for i, param in funcDecl.declFuncParams:
        if i >= argTypes.len: break
        if param.ptype.kind in {tekRef, tekMutRef} and param.ptype.refLifetime == tp.name:
          found = true
          break
      if not found:
        return @[]
      # lifetimes don't go into monomorph name; placeholder
      bindings[tp.name] = makeNamed("lifetime")

  # Unify each param pattern with the corresponding argument type
  for i, param in funcDecl.declFuncParams:
    if i >= argTypes.len: break
    if param.ptype == nil: continue
    var refsTp = false
    for n in tpNames:
      if typeExprReferencesTypeParam(param.ptype, n):
        refsTp = true
        break
    if not refsTp:
      continue
    if not sema.unifyTypeParam(param.ptype, argTypes[i], tpNames, bindings, loc):
      return @[]

  # Emit results in decl order
  for tp in funcDecl.declFuncTypeParams:
    if tp.isLifetime:
      result.add(TypeExpr(kind: tekNamed, typeName: "lifetime"))
      continue
    if not bindings.hasKey(tp.name):
      return @[]
    let t = bindings[tp.name]
    if t == nil or t.isUnknown:
      return @[]
    result.add(typeToTypeExpr(t))

# ---------------------------------------------------------------------------
# Type resolution from AST TypeExpr
# ---------------------------------------------------------------------------

proc resolveType*(sema: var Sema, te: TypeExpr): Type =
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
      # Support 0x / 0b / 0o prefixes (parseBiggestInt is decimal-only).
      let lit = expr.exprLit.text
      try:
        if lit.len >= 3 and lit[0] == '0':
          let p = lit[1].toLowerAscii()
          if p == 'x':
            return CtValue(kind: ctkInt, intVal: BiggestInt(parseHexInt(lit[2 .. ^1])))
          elif p == 'b':
            return CtValue(kind: ctkInt, intVal: BiggestInt(parseBinInt(lit[2 .. ^1])))
          elif p == 'o':
            return CtValue(kind: ctkInt, intVal: BiggestInt(parseOctInt(lit[2 .. ^1])))
        return CtValue(kind: ctkInt, intVal: parseBiggestInt(lit))
      except ValueError:
        return CtValue(kind: ctkVoid)
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
      # Bitwise (session 75 — embedded CRC / flag tables at compile time)
      of tkCaret: return CtValue(kind: ctkInt, intVal: left.intVal xor right.intVal)
      of tkAmp: return CtValue(kind: ctkInt, intVal: left.intVal and right.intVal)
      of tkPipe: return CtValue(kind: ctkInt, intVal: left.intVal or right.intVal)
      of tkShl: return CtValue(kind: ctkInt, intVal: left.intVal shl right.intVal)
      of tkShr: return CtValue(kind: ctkInt, intVal: left.intVal shr right.intVal)
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

proc checkExpr*(sema: var Sema, expr: Expr, scope: Scope): Type
proc checkStmt(sema: var Sema, stmt: Stmt, scope: Scope): Type

proc isResultOrOptionName(name: string): bool =
  name == "Result" or name.startsWith("Result_") or
  name == "Option" or name.startsWith("Option_")

proc extractResultOptionPayload*(sema: var Sema, opTy: Type, loc: SourceLocation, opKind: string): Type =
  ## Payload type of `Result`/`Option` for `?` (try) and `!` (unwrap).
  ## Prefer type-args (`Result<T,E>` → T); fall back to Ok/Some field on the enum decl.
  if opTy == nil or opTy.isUnknown:
    return makeUnknown()
  if opTy.kind != tkNamed:
    sema.emitError(loc, opKind & " requires Result or Option operand")
    return makeUnknown()
  let name = opTy.name
  if not isResultOrOptionName(name):
    sema.emitError(loc, opKind & " requires Result or Option, got " & opTy.toString)
    return makeUnknown()
  # Result<T,E> / Option<T> store payload in .inner
  if opTy.inner.len >= 1:
    return opTy.inner[0]
  # Bare / monomorphized name: look up Ok(T) / Some(T) on the enum decl
  var enumSym = sema.globalScope.lookup(name)
  if (enumSym == nil or enumSym.decl == nil or enumSym.decl.kind != dkEnum):
    if name.startsWith("Result_"):
      enumSym = sema.globalScope.lookup("Result")
    elif name.startsWith("Option_"):
      enumSym = sema.globalScope.lookup("Option")
  let wantVariant =
    if name == "Option" or name.startsWith("Option_"): "Some"
    else: "Ok"
  if enumSym != nil and enumSym.decl != nil and enumSym.decl.kind == dkEnum:
    var subst = initTable[string, Type]()
    # Result_String_String → try to bind type params from mangled suffix when possible
    if opTy.inner.len == 0 and enumSym.decl.declEnumTypeParams.len > 0 and
       (name.startsWith("Result_") or name.startsWith("Option_")):
      let prefix = if name.startsWith("Result_"): "Result_" else: "Option_"
      let rest = name[prefix.len .. ^1]
      # Split on '_' is imperfect for nested types; for simple T_E it works
      let parts = rest.split('_')
      var pi = 0
      for tp in enumSym.decl.declEnumTypeParams:
        if pi < parts.len and parts[pi].len > 0:
          # Re-resolve simple type names (int, String, …)
          let te = TypeExpr(kind: tekNamed, typeName: parts[pi])
          subst[tp.name] = sema.resolveType(te)
        inc pi
    for variant in enumSym.decl.declEnumVariants:
      if variant.name == wantVariant and variant.fields.len > 0:
        let raw = sema.resolveType(variant.fields[0])
        return sema.substituteTypeInType(raw, subst)
  # Unknown payload — don't invent int (breaks String Results)
  return makeUnknown()

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

proc extractPatternBindings(sema: var Sema, pat: Pattern, scope: Scope, subjectType: Type = nil) =
  ## Add pattern-bound identifiers to scope. For enum payloads, resolve field types
  ## from the matched enum variant so arm bodies type-check correctly.
  if pat == nil: return
  case pat.kind
  of pkIdent:
    let bindTy = if subjectType != nil and not subjectType.isUnknown: subjectType else: makeUnknown()
    let sym = Symbol(kind: skVar, name: pat.patIdent, typ: bindTy, isMutable: false)
    discard scope.define(sym)
  of pkEnum:
    # Resolve variant field types from enum declaration
    var enumName = ""
    var variantName = ""
    if pat.patEnumPath.len >= 2:
      enumName = pat.patEnumPath[0]
      variantName = pat.patEnumPath[^1]
    elif pat.patEnumPath.len == 1:
      variantName = pat.patEnumPath[0]
      if subjectType != nil and subjectType.kind == tkNamed:
        enumName = subjectType.name
    var fieldTypes: seq[Type] = @[]
    var namedFieldTypes: Table[string, Type]
    if enumName != "":
      let enumSym = sema.globalScope.lookup(enumName)
      if enumSym != nil and enumSym.decl != nil and enumSym.decl.kind == dkEnum:
        for v in enumSym.decl.declEnumVariants:
          if v.name == variantName:
            for f in v.fields:
              fieldTypes.add(sema.resolveType(f))
            for nf in v.namedFields:
              namedFieldTypes[nf.name] = sema.resolveType(nf.ftype)
            break
    for i, arg in pat.patEnumArgs:
      let argTy = if i < fieldTypes.len: fieldTypes[i] else: makeUnknown()
      if arg.kind == pkIdent:
        let sym = Symbol(kind: skVar, name: arg.patIdent, typ: argTy, isMutable: false)
        discard scope.define(sym)
      else:
        sema.extractPatternBindings(arg, scope, argTy)
    for nf in pat.patEnumNamed:
      let argTy = if namedFieldTypes.hasKey(nf.name): namedFieldTypes[nf.name] else: makeUnknown()
      if nf.pattern.kind == pkIdent:
        let sym = Symbol(kind: skVar, name: nf.pattern.patIdent, typ: argTy, isMutable: false)
        discard scope.define(sym)
      else:
        sema.extractPatternBindings(nf.pattern, scope, argTy)
  of pkTuple:
    for i, elem in pat.patTupleElements:
      let elemTy = if subjectType != nil and subjectType.kind == tkTuple and i < subjectType.inner.len:
                     subjectType.inner[i]
                   else: makeUnknown()
      if elem.kind == pkIdent:
        let sym = Symbol(kind: skVar, name: elem.patIdent, typ: elemTy, isMutable: false)
        discard scope.define(sym)
      else:
        sema.extractPatternBindings(elem, scope, elemTy)
  of pkStruct:
    # Resolve field types from struct declaration when possible
    var fieldTypes = initTable[string, Type]()
    var structName = pat.patStructName
    if structName.len == 0 and subjectType != nil and subjectType.kind == tkNamed:
      structName = subjectType.name
    if structName.len > 0:
      let ssym = sema.globalScope.lookup(structName)
      if ssym != nil and ssym.decl != nil and ssym.decl.kind == dkStruct:
        for f in ssym.decl.declStructFields:
          fieldTypes[f.name] = sema.resolveType(f.ftype)
    for entry in pat.patStructFields:
      let fty = if fieldTypes.hasKey(entry.name): fieldTypes[entry.name] else: makeUnknown()
      if entry.pattern != nil and entry.pattern.kind == pkIdent:
        let sym = Symbol(kind: skVar, name: entry.pattern.patIdent, typ: fty, isMutable: false)
        discard scope.define(sym)
      else:
        sema.extractPatternBindings(entry.pattern, scope, fty)
  of pkGuarded:
    sema.extractPatternBindings(pat.patGuardedInner, scope, subjectType)
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

proc checkExpr*(sema: var Sema, expr: Expr, scope: Scope): Type =
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
    # Exclusive borrow: cannot read original while &mut is live
    sema.checkUseWhileBorrowed(expr.exprIdent, expr.loc, isWrite = false)
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
    # Forming `&x` must not count as a "use" of x (borrow creation is checked separately)
    var operandType: Type
    if expr.exprUnaryOp == tkAmp:
      let savedSup = sema.suppressUseWhileBorrow
      sema.suppressUseWhileBorrow = true
      operandType = sema.checkExpr(expr.exprUnaryOperand, scope)
      sema.suppressUseWhileBorrow = savedSup
    else:
      operandType = sema.checkExpr(expr.exprUnaryOperand, scope)
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
      # Cannot assign to var while it is mutably borrowed (single message; suppress rvalue use-check)
      sema.checkUseWhileBorrowed(expr.exprAssignTarget.exprIdent, expr.loc, isWrite = true)
    var target: Type
    if expr.exprAssignTarget != nil and expr.exprAssignTarget.kind == ekIdent:
      let savedSup = sema.suppressUseWhileBorrow
      sema.suppressUseWhileBorrow = true
      target = sema.checkExpr(expr.exprAssignTarget, scope)
      sema.suppressUseWhileBorrow = savedSup
    else:
      target = sema.checkExpr(expr.exprAssignTarget, scope)
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

    # Check for generic function call: Max<int>(10, 20) or Iter_Map<int, String>(…)
    if expr.exprCallCallee.kind == ekGenericCall:
      let sym = scope.lookup(expr.exprCallCallee.exprGenericCallee)
      if sym == nil:
        sema.emitError(expr.loc, &"undeclared identifier '{expr.exprCallCallee.exprGenericCallee}'")
        return makeUnknown()
      # Still type-check args (closures need capture analysis, etc.)
      # Bind type params while checking so `func(T)->U` params resolve.
      let sym2 = sema.globalScope.lookup(expr.exprCallCallee.exprGenericCallee)
      var added: seq[string] = @[]
      if sym2 != nil and sym2.decl != nil and sym2.decl.kind == dkFunc and
         sym2.decl.declFuncTypeParams.len > 0:
        let typeParams = sym2.decl.declFuncTypeParams
        for i, tp in typeParams:
          if i < expr.exprCallCallee.exprGenericTypeArgs.len:
            let concrete = sema.resolveType(expr.exprCallCallee.exprGenericTypeArgs[i])
            sema.typeTable[tp.name] = concrete
            added.add(tp.name)
      discard sema.checkExprList(expr.exprCallArgs, scope)
      var resolvedRet = makeUnknown()
      if sym2 != nil and sym2.decl != nil and sym2.decl.kind == dkFunc and
         sym2.decl.declFuncReturnType != nil:
        resolvedRet = sema.resolveType(sym2.decl.declFuncReturnType)
      elif sym.typ != nil and sym.typ.kind == tkFunc and sym.typ.inner.len > 0:
        resolvedRet = sym.typ.inner[^1]
      for tp in added:
        sema.typeTable.del(tp)
      return resolvedRet

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
              let bname = extractBorrowedIdent(arg)
              if bname.len > 0:
                mutRefArgs.add((idx: i, name: bname))
                # Conflict with long-lived let-bound &mut
                sema.checkTempMutBorrow(bname, arg.loc)
            elif expectedParams[i].isRef and i < expr.exprCallArgs.len:
              let bname = extractBorrowedIdent(expr.exprCallArgs[i])
              if bname.len > 0 and sema.activeMutBorrows.hasKey(bname):
                sema.emitError(expr.exprCallArgs[i].loc,
                  &"cannot shared-borrow '{bname}' while it is mutably borrowed")
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
    if objType.kind == tkTuple:
      # Tuple fields: .0 / .1 → stored as "_0" / "_1"
      var idx = -1
      let fname = expr.exprFieldName
      if fname.len > 0 and fname[0] == '_':
        try: idx = parseInt(fname[1..^1])
        except ValueError: idx = -1
      else:
        try: idx = parseInt(fname)
        except ValueError: idx = -1
      if idx >= 0 and idx < objType.inner.len:
        return objType.inner[idx]
      sema.emitError(expr.loc, &"tuple has no element '{fname}' (tuple arity {objType.inner.len})")
      return makeUnknown()
    if objType.kind == tkNamed:
      # Check if this is a _Data union field access
      if objType.name.endsWith("_Data"):
        let enumName = objType.name[0..^6]  # Remove "_Data" suffix
        let enumSym = sema.globalScope.lookup(enumName)
        if enumSym != nil and enumSym.decl != nil and enumSym.decl.kind == dkEnum:
          # Look for the field in enum variants
          for variant in enumSym.decl.declEnumVariants:
            # Multi-field / named-field variant: data.Variant → Enum_Variant_Payload
            # (suffix avoids clashing with tag constant Enum_Variant)
            if variant.fields.len > 1 and variant.name == expr.exprFieldName:
              return makeNamed(enumName & "_" & variant.name & "_Payload")
            if variant.namedFields.len > 0 and variant.name == expr.exprFieldName:
              return makeNamed(enumName & "_" & variant.name & "_Payload")
            # Single positional fields: Ok_0, Ok_1, etc. (flat on the union)
            for i, f in variant.fields:
              let fieldName = variant.name & "_" & $i
              if fieldName == expr.exprFieldName:
                return sema.resolveType(f)
            # Named fields nested under data.Variant.name
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
          # Synthetic nested multi-field type Enum_Variant_Payload — generated for
          # multi-field / named-field algebraic variants (not a user-declared type).
          var foundNested = false
          for (_, gsym) in sema.globalScope.table.pairs:
            if gsym.decl == nil or gsym.decl.kind != dkEnum: continue
            let ename = gsym.decl.declEnumName
            for variant in gsym.decl.declEnumVariants:
              let nestedName = ename & "_" & variant.name & "_Payload"
              if nestedName != objType.name: continue
              foundNested = true
              for i, f in variant.fields:
                let fieldName = variant.name & "_" & $i
                if fieldName == expr.exprFieldName:
                  return sema.resolveType(f)
              for nf in variant.namedFields:
                if nf.name == expr.exprFieldName:
                  return sema.resolveType(nf.ftype)
              sema.emitError(expr.loc, &"nested variant type '{objType.name}' has no field '{expr.exprFieldName}'")
              return makeUnknown()
          if not foundNested:
            sema.emitError(expr.loc, &"undeclared type '{objType.name}'")
          return makeUnknown()
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
    let opTy = sema.checkExpr(expr.exprTryOperand, scope)
    # Payload of Result/Option; validates operand is Result or Option
    return sema.extractResultOptionPayload(opTy, expr.loc, "try operator (`?`)")
  of ekUnwrap:
    let opTy = sema.checkExpr(expr.exprUnwrapOperand, scope)
    return sema.extractResultOptionPayload(opTy, expr.loc, "unwrap operator (`!`)")
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
      sema.extractPatternBindings(arm.pattern, armScope, subjectType)
      # Type-check `p if guard` condition (must be bool; sees pattern bindings)
      if arm.pattern != nil and arm.pattern.kind == pkGuarded and arm.pattern.patGuardedExpr != nil:
        let guardTy = sema.checkExpr(arm.pattern.patGuardedExpr, armScope)
        if not guardTy.isBool and not guardTy.isUnknown:
          sema.emitError(arm.pattern.patGuardedExpr.loc, "match guard condition must be bool")
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
    # Explicit `borrow` — track only when bound via let (checkCreateBorrow on skLet).
    # Here we validate conflicts for free-standing borrow expressions used as temps.
    if sema.checkedFunc:
      let bname = extractBorrowedIdent(expr)
      if bname.len > 0:
        if expr.exprBorrowMutable:
          sema.checkTempMutBorrow(bname, expr.loc)
        elif sema.activeMutBorrows.hasKey(bname):
          sema.emitError(expr.loc,
            &"cannot shared-borrow '{bname}' while it is mutably borrowed")
    if expr.exprBorrowMutable:
      return makeMutRef(operand)
    return makeRef(operand)
  of ekSpread:
    return sema.checkExpr(expr.exprSpreadOperand, scope)
  of ekStringInterp:
    for e in expr.exprInterpExprs:
      discard sema.checkExpr(e, scope)
    return makeStr()
  of ekMacroCall:
    # Should have been expanded before analyze; leftover is a compiler bug
    sema.emitError(expr.loc, "unexpanded macro call '" & expr.exprMacroName & "!'")
    return makeUnknown()
  of ekMacroStmt, ekMacroPat, ekMacroTt, ekMacroRep, ekMacroType:
    # Expand-only wrappers; must not reach type-checking
    sema.emitError(expr.loc, "internal: unexpanded macro fragment")
    return makeUnknown()
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
      # Point at the initializer expression for a clearer caret
      sema.emitError(stmt.stmtLetInit.loc, &"cannot assign {initType.toString} to {declaredType.toString}")
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
    # Long-lived borrow: `let r: &mut T = &x` / `let r: &T = &x`
    if sema.checkedFunc and stmt.stmtLetInit != nil:
      let bname = extractBorrowedIdent(stmt.stmtLetInit)
      if bname.len > 0:
        var isMut = false
        if declaredType.isMutRef:
          isMut = true
        elif declaredType.isRef:
          isMut = false
        else:
          # Untyped let + `&x` is typed as &mut by unary lowering
          isMut = initType.isMutRef
        sema.checkCreateBorrow(bname, isMut, stmt.stmtLetInit.loc)
      # Propagate ref lifetime to the new binding (for return-site checks)
      if declaredType.isRef or declaredType.isMutRef or initType.isRef or initType.isMutRef:
        let lt = sema.exprRefLifetime(stmt.stmtLetInit, scope)
        if lt.len > 0:
          sema.varRefLifetime[stmt.stmtLetName] = lt
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
    let subjectType = sema.checkExpr(stmt.stmtMatchSubject, scope)
    for arm in stmt.stmtMatchArms:
      var armScope = newScope(scope)
      sema.extractPatternBindings(arm.pattern, armScope, subjectType)
      if arm.pattern != nil and arm.pattern.kind == pkGuarded and arm.pattern.patGuardedExpr != nil:
        let guardTy = sema.checkExpr(arm.pattern.patGuardedExpr, armScope)
        if not guardTy.isBool and not guardTy.isUnknown:
          sema.emitError(arm.pattern.patGuardedExpr.loc, "match guard condition must be bool")
      discard sema.checkExpr(arm.body, armScope)
    return makeVoid()
  of skReturn:
    if stmt.stmtReturnValue != nil:
      discard sema.checkExpr(stmt.stmtReturnValue, scope)
      if sema.checkedFunc and stmt.stmtReturnValue.kind == ekIdent:
        let retSym = scope.lookup(stmt.stmtReturnValue.exprIdent)
        if retSym != nil and retSym.isOwn:
          sema.movedVars.add(stmt.stmtReturnValue.exprIdent)
      # Lifetime: reject dangling returns / explicit mismatches
      sema.checkReturnLifetime(stmt.stmtReturnValue, scope, stmt.loc)
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
  of skMacroRep:
    # Templates with $(…)* must be expanded before type-check
    sema.emitError(stmt.loc, "unexpanded macro repetition '$(…)*'")
    return makeVoid()
# ---------------------------------------------------------------------------
# Function body checking
# ---------------------------------------------------------------------------

proc checkFunc(sema: var Sema, decl: Decl) =
  if decl.declFuncBody == nil:
    return
  # Skip body type-checking for type-generic functions — their bodies contain
  # type parameters that cannot be fully resolved until monomorphization.
  # Lifetime-only params (`'a`) are fine: we still check the body for elision.
  var hasTypeGeneric = false
  for tp in decl.declFuncTypeParams:
    if not tp.isLifetime:
      hasTypeGeneric = true
      break
  if hasTypeGeneric:
    return
  let wasChecked = sema.checkedFunc
  let wasRelease = sema.releaseFunc
  let wasAsync = sema.currentFuncIsAsync
  # C.4: @[Release] is the zero-cost escape — disables borrow checks even with @[Checked]
  sema.releaseFunc = "Release" in decl.declAttrs
  sema.checkedFunc = "Checked" in decl.declAttrs and not sema.releaseFunc
  sema.currentFuncIsAsync = decl.declFuncIsAsync
  if sema.checkedFunc:
    sema.movedVars = @[]
    sema.activeMutBorrows = initTable[string, SourceLocation]()
    sema.activeSharedBorrows = initTable[string, int]()
    # C.1: elide lifetimes on params / return before walking the body
    sema.applyLifetimeElision(decl)
  else:
    sema.varRefLifetime = initTable[string, string]()
    sema.returnLifetime = ""
  var funcScope = newScope(sema.globalScope)
  # Add type parameters to type table for resolution
  var addedTypeParams: seq[string] = @[]
  for tp in decl.declFuncTypeParams:
    if tp.isLifetime:
      # Lifetime params are not types; skip typeTable
      continue
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
  sema.releaseFunc = wasRelease
  sema.currentFuncIsAsync = wasAsync
  sema.varRefLifetime = initTable[string, string]()
  sema.returnLifetime = ""

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

proc checkExprForLsp*(sema: var Sema, expr: Expr, scope: Scope): Type =
  ## Type-check an expression for IDE use (no borrow/move side effects).
  let wasChecked = sema.checkedFunc
  let savedMoved = sema.movedVars
  let savedMut = sema.activeMutBorrows
  let savedShared = sema.activeSharedBorrows
  sema.checkedFunc = false
  result = sema.checkExpr(expr, scope)
  sema.checkedFunc = wasChecked
  sema.movedVars = savedMoved
  sema.activeMutBorrows = savedMut
  sema.activeSharedBorrows = savedShared
