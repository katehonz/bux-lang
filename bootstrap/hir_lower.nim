import std/[tables, sets, strutils, strformat]
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
    ## Named functions that must be wrapped as fat func values (multi-instance ABI)
    funcAdapters*: HashSet[string]
    funcAdapterSigs*: Table[string, Type]
    ## All func types that need BuxFn_* typedefs (including locals)
    seenFatTypes*: seq[Type]
    ## Pattern-binding names already alloca'd in the current function
    ## (legacy; unique mangled names are preferred for shadowing safety)
    patternBoundNames*: HashSet[string]
    ## Active renames: source pattern name → unique C local (for shadowing)
    patternRenames*: Table[string, string]
    ## Locals whose value was moved into another owner (struct field, let, return).
    ## Auto-Drop is skipped for these (session 37 — field-move ownership).
    movedOutLocals*: HashSet[string]
    ## Partial field moves: local → dotted paths moved out by value
    ## (e.g. "items", "inner.items" for nested `a.b.c` — session 70/73).
    ## When parent Type_Drop is skipped, remaining droppable fields still Drop.
    ## Whole-local moves leave this empty → full skip, no field drops.
    partialMovedFields*: Table[string, HashSet[string]]
    ## Pointer aliases: local pointer name → pointee local (`p = &bag` → p→bag).
    ## Used so `p.items` / `(*p).items` mark the owner local (session 74).
    ptrAliases*: Table[string, string]

proc freshName(ctx: var LowerCtx): string =
  inc ctx.varCounter
  result = "__tmp_" & $ctx.varCounter

proc freshPatName(ctx: var LowerCtx, src: string): string =
  ## Unique C name for a pattern binding (allows shadowing outer lets / nested matches).
  inc ctx.varCounter
  let safe = if src.len > 0 and src != "_": src else: "x"
  result = "__p" & $ctx.varCounter & "_" & safe

proc generateMethodInstance(ctx: var LowerCtx, baseMethodName: string, typeArgs: seq[TypeExpr]): string

proc namedTypeArg(name: string): TypeExpr =
  TypeExpr(kind: tekNamed, typeName: name)

proc ensureDropMono(ctx: var LowerCtx, dropBase: string, freeBase: string, typeArgs: seq[TypeExpr]) =
  ## Monomorphize Free (if any) then Drop so the C linker finds them.
  if freeBase.len > 0:
    discard ctx.generateMethodInstance(freeBase, typeArgs)
  discard ctx.generateMethodInstance(dropBase, typeArgs)

proc dropTargetName(n: HirNode): string =
  ## Local name targeted by Type_Drop(&name), or "".
  if n == nil: return ""
  if n.kind == hCall and n.callArgs.len >= 1:
    let a = n.callArgs[0]
    if a != nil and a.kind == hUnary and a.unaryOp == tkAmp and
       a.unaryOperand != nil and a.unaryOperand.kind == hVar:
      return a.unaryOperand.varName
  return ""

proc dropTargetsVar(n: HirNode, name: string): bool =
  ## True if n is Type_Drop(&name) / collection Drop of that local.
  name.len > 0 and dropTargetName(n) == name

proc hasPendingDrop(ctx: LowerCtx, name: string): bool =
  if name.len == 0: return false
  for d in ctx.deferStmts:
    if dropTargetsVar(d, name): return true
  false

proc markMovedOutLocal(ctx: var LowerCtx, name: string) =
  ## Record that `name` no longer owns its heap (moved into another value).
  if name.len > 0 and ctx.hasPendingDrop(name):
    ctx.movedOutLocals.incl(name)

# Forward decls (used by markMovedOutFromAst / remainingFieldDrops before defs)
proc resolveExprType(ctx: var LowerCtx, expr: Expr): Type
proc autoDropFuncName(ctx: var LowerCtx, ty: Type): string
proc resolveTypeExpr(ctx: var LowerCtx, te: TypeExpr): Type
proc substituteType(ctx: var LowerCtx, te: TypeExpr, subst: Table[string, Type]): Type
proc markCrossFuncPtrMoves(ctx: var LowerCtx, call: Expr)

proc resolvePtrAlias(ctx: LowerCtx, name: string): string =
  ## Follow `p → bag` aliases (depth-limited).
  result = name
  var guard = 0
  while result.len > 0 and ctx.ptrAliases.hasKey(result) and guard < 8:
    result = ctx.ptrAliases[result]
    inc guard

proc fieldPathFromAst(ctx: LowerCtx, expr: Expr): tuple[base: string, path: seq[string]] =
  ## Walk `a.b.c` / `(*p).b.c` / `p.b` (auto-deref) → owner local + path.
  ## Resolves pointer aliases (`p = &bag` → owner is `bag`).
  result = ("", @[])
  if expr == nil: return
  var path: seq[string] = @[]
  var e = expr
  while e != nil and e.kind == ekField:
    path.insert(e.exprFieldName, 0)
    e = e.exprFieldObj
  # Peel explicit derefs: (*p).x or (**pp).x
  while e != nil and e.kind == ekUnary and e.exprUnaryOp == tkStar:
    e = e.exprUnaryOperand
  if e != nil and e.kind == ekIdent and e.exprIdent.len > 0 and path.len > 0:
    let owner = ctx.resolvePtrAlias(e.exprIdent)
    result = (owner, path)

proc pathKey(path: seq[string]): string =
  path.join(".")

proc recordPtrAliasFromAst(ctx: var LowerCtx, ptrName: string, init: Expr) =
  ## If `init` is `&local` (possibly with paren/cast noise), record ptr→local.
  if ptrName.len == 0 or init == nil: return
  var e = init
  # Skip simple casts
  while e != nil and e.kind == ekCast:
    e = e.exprCastOperand
  if e != nil and e.kind == ekUnary and e.exprUnaryOp == tkAmp:
    var op = e.exprUnaryOperand
    while op != nil and op.kind == ekCast:
      op = op.exprCastOperand
    if op != nil and op.kind == ekIdent and op.exprIdent.len > 0:
      ctx.ptrAliases[ptrName] = op.exprIdent

proc markMovedOutFromAst(ctx: var LowerCtx, expr: Expr) =
  ## Mark droppable locals used by-value in ownership-taking contexts.
  ## Partial field moves: `return bag.items` / `return outer.inner.items` /
  ## `return p.items` (p = &bag) mark the **owner** local so auto-Drop of the
  ## parent is skipped. Records dotted path so remaining fields still Drop
  ## (sessions 70/73/74).
  if expr == nil: return
  case expr.kind
  of ekIdent:
    ctx.markMovedOutLocal(ctx.resolvePtrAlias(expr.exprIdent))
  of ekField:
    let fieldTy = ctx.resolveExprType(expr)
    if ctx.autoDropFuncName(fieldTy).len > 0:
      let (base, path) = ctx.fieldPathFromAst(expr)
      if base.len > 0 and path.len > 0:
        if not ctx.partialMovedFields.hasKey(base):
          ctx.partialMovedFields[base] = initHashSet[string]()
        ctx.partialMovedFields[base].incl(pathKey(path))
        ctx.markMovedOutLocal(base)
      # Nested path recorded as a whole — do not recurse (would mis-mark intermediates)
  of ekUnary:
    # Moving `*p` by value (whole pointee) — mark owner local if known
    if expr.exprUnaryOp == tkStar and expr.exprUnaryOperand != nil and
       expr.exprUnaryOperand.kind == ekIdent:
      let owner = ctx.resolvePtrAlias(expr.exprUnaryOperand.exprIdent)
      ctx.markMovedOutLocal(owner)
  of ekStructInit:
    for f in expr.exprStructInitFields:
      ctx.markMovedOutFromAst(f.value)
  of ekTuple:
    for e in expr.exprTupleElements:
      ctx.markMovedOutFromAst(e)
  of ekCall:
    # Cross-function: Take(&bag) may move fields of bag (session 76)
    ctx.markCrossFuncPtrMoves(expr)
    for a in expr.exprCallArgs:
      ctx.markMovedOutFromAst(a)
  else:
    discard


proc argAmpOwner(ctx: LowerCtx, arg: Expr): string =
  ## If arg is `&local` (or cast of that), return the owner local name.
  ## Also: bare pointer local that aliases an owner (`p` where p→bag).
  if arg == nil: return ""
  var e = arg
  while e != nil and e.kind == ekCast:
    e = e.exprCastOperand
  if e != nil and e.kind == ekUnary and e.exprUnaryOp == tkAmp:
    var op = e.exprUnaryOperand
    while op != nil and op.kind == ekCast:
      op = op.exprCastOperand
    if op != nil and op.kind == ekIdent and op.exprIdent.len > 0:
      return ctx.resolvePtrAlias(op.exprIdent)
    return ""
  if e != nil and e.kind == ekIdent and e.exprIdent.len > 0:
    let owner = ctx.resolvePtrAlias(e.exprIdent)
    if owner != e.exprIdent:
      return owner
  ""

proc fieldPathFromParam(expr: Expr, param: string): seq[string] =
  ## If `expr` is `param.a.b` / `(*param).a` / `param` auto-deref field chain,
  ## return path `["a","b"]`. Empty if not rooted at param.
  result = @[]
  if expr == nil or param.len == 0: return
  var path: seq[string] = @[]
  var e = expr
  while e != nil and e.kind == ekField:
    path.insert(e.exprFieldName, 0)
    e = e.exprFieldObj
  while e != nil and e.kind == ekUnary and e.exprUnaryOp == tkStar:
    e = e.exprUnaryOperand
  if e != nil and e.kind == ekIdent and e.exprIdent == param and path.len > 0:
    result = path

proc scanExprParamMoves(e: Expr, param: string, paths: var HashSet[string], whole: var bool)
proc scanBlockParamMoves(blk: Block, param: string, paths: var HashSet[string], whole: var bool)

proc scanExprParamMoves(e: Expr, param: string, paths: var HashSet[string], whole: var bool) =
  ## Detect ownership moves of pointee fields through pointer param `param`.
  if e == nil or param.len == 0: return
  case e.kind
  of ekField:
    let path = fieldPathFromParam(e, param)
    if path.len > 0:
      paths.incl(path.join("."))
  of ekUnary:
    if e.exprUnaryOp == tkStar and e.exprUnaryOperand != nil and
       e.exprUnaryOperand.kind == ekIdent and
       e.exprUnaryOperand.exprIdent == param:
      whole = true
    else:
      scanExprParamMoves(e.exprUnaryOperand, param, paths, whole)
  of ekStructInit:
    for f in e.exprStructInitFields:
      scanExprParamMoves(f.value, param, paths, whole)
  of ekTuple:
    for el in e.exprTupleElements:
      scanExprParamMoves(el, param, paths, whole)
  of ekCall:
    if e.exprCallCallee != nil:
      scanExprParamMoves(e.exprCallCallee, param, paths, whole)
    for a in e.exprCallArgs:
      scanExprParamMoves(a, param, paths, whole)
  of ekBinary:
    scanExprParamMoves(e.exprBinaryLeft, param, paths, whole)
    scanExprParamMoves(e.exprBinaryRight, param, paths, whole)
  of ekAssign:
    # `let x = p.items` style via assign value
    scanExprParamMoves(e.exprAssignValue, param, paths, whole)
  of ekBlock:
    if e.exprBlock != nil:
      scanBlockParamMoves(e.exprBlock, param, paths, whole)
  of ekCast:
    scanExprParamMoves(e.exprCastOperand, param, paths, whole)
  else:
    discard

proc scanStmtParamMoves(s: Stmt, param: string, paths: var HashSet[string], whole: var bool) =
  if s == nil: return
  case s.kind
  of skReturn:
    scanExprParamMoves(s.stmtReturnValue, param, paths, whole)
  of skLet:
    scanExprParamMoves(s.stmtLetInit, param, paths, whole)
  of skExpr:
    scanExprParamMoves(s.stmtExpr, param, paths, whole)
  of skIf:
    scanExprParamMoves(s.stmtIfCond, param, paths, whole)
    if s.stmtIfThen != nil: scanBlockParamMoves(s.stmtIfThen, param, paths, whole)
    if s.stmtIfElse != nil: scanBlockParamMoves(s.stmtIfElse, param, paths, whole)
    for br in s.stmtIfElseIfs:
      scanExprParamMoves(br.cond, param, paths, whole)
      if br.blk != nil: scanBlockParamMoves(br.blk, param, paths, whole)
  of skWhile:
    scanExprParamMoves(s.stmtWhileCond, param, paths, whole)
    if s.stmtWhileBody != nil: scanBlockParamMoves(s.stmtWhileBody, param, paths, whole)
  of skFor:
    scanExprParamMoves(s.stmtForIter, param, paths, whole)
    if s.stmtForBody != nil: scanBlockParamMoves(s.stmtForBody, param, paths, whole)
  of skMatch:
    scanExprParamMoves(s.stmtMatchSubject, param, paths, whole)
    for arm in s.stmtMatchArms:
      if arm.body != nil:
        scanExprParamMoves(arm.body, param, paths, whole)
  else:
    discard

proc scanBlockParamMoves(blk: Block, param: string, paths: var HashSet[string], whole: var bool) =
  if blk == nil: return
  for st in blk.stmts:
    scanStmtParamMoves(st, param, paths, whole)

proc paramIsPointer(p: Param): bool =
  ## True if the parameter type is a pointer (`*T` / `&T` / `own` pointer-ish).
  if p.ptype == nil: return false
  p.ptype.kind in {tekPointer, tekOwn}

proc markCrossFuncPtrMoves(ctx: var LowerCtx, call: Expr) =
  ## Session 76: `TakeItems(&bag)` where TakeItems moves `p.items` → mark bag.
  if call == nil or call.kind != ekCall: return
  var calleeName = ""
  if call.exprCallCallee == nil: return
  case call.exprCallCallee.kind
  of ekIdent:
    calleeName = call.exprCallCallee.exprIdent
    if ctx.importTable.hasKey(calleeName):
      calleeName = ctx.importTable[calleeName]
  of ekPath:
    calleeName = call.exprCallCallee.exprPath.join("_")
  of ekGenericCall:
    calleeName = call.exprCallCallee.exprGenericCallee
  else:
    return
  if calleeName.len == 0: return
  let sym = ctx.globalScope.lookup(calleeName)
  if sym == nil or sym.decl == nil or sym.decl.kind != dkFunc: return
  let decl = sym.decl
  if decl.declFuncBody == nil: return
  for i, arg in call.exprCallArgs:
    if i >= decl.declFuncParams.len: break
    let fp = decl.declFuncParams[i]
    if not paramIsPointer(fp): continue
    let owner = ctx.argAmpOwner(arg)
    if owner.len == 0: continue
    if not ctx.hasPendingDrop(owner): continue
    var paths = initHashSet[string]()
    var whole = false
    scanBlockParamMoves(decl.declFuncBody, fp.name, paths, whole)
    if not whole and paths.len == 0: continue
    if whole:
      ctx.markMovedOutLocal(owner)
    else:
      if not ctx.partialMovedFields.hasKey(owner):
        ctx.partialMovedFields[owner] = initHashSet[string]()
      for path in paths:
        ctx.partialMovedFields[owner].incl(path)
      ctx.markMovedOutLocal(owner)

proc shouldSkipDrop(ctx: LowerCtx, dropNode: HirNode, skipName: string): bool =
  ## Skip Drop for explicit skipName or any moved-out local.
  let target = dropTargetName(dropNode)
  if target.len == 0: return false
  if skipName.len > 0 and target == skipName: return true
  if target in ctx.movedOutLocals: return true
  false

proc structFieldsOf(ctx: var LowerCtx, te: TypeExpr, typeName: string): seq[tuple[name: string, typ: Type]] =
  ## Resolve struct fields for a named / monomorphized type.
  result = @[]
  var declName = if te != nil: te.typeName else: ""
  if declName.len == 0: declName = typeName
  let sym = ctx.globalScope.lookup(declName)
  if sym != nil and sym.decl != nil and sym.decl.kind == dkStruct:
    for f in sym.decl.declStructFields:
      if f.ftype == nil: continue
      var fieldTy: Type
      if te != nil and te.typeArgs.len > 0 and ctx.genericStructs.hasKey(declName):
        var subst = initTable[string, Type]()
        let gdecl = ctx.genericStructs[declName]
        for j, tp in gdecl.declStructTypeParams:
          if j < te.typeArgs.len:
            subst[tp.name] = ctx.resolveTypeExpr(te.typeArgs[j])
        fieldTy = substituteType(ctx, f.ftype, subst)
      else:
        fieldTy = ctx.resolveTypeExpr(f.ftype)
      result.add((f.name, fieldTy))
    return
  if ctx.structInstMap.hasKey(typeName):
    for es in ctx.extraStructs:
      if es.name == typeName:
        for f in es.fields:
          result.add((f.name, f.typ))
        return
  # Also try mangled typeName as decl name
  let sym2 = ctx.globalScope.lookup(typeName)
  if sym2 != nil and sym2.decl != nil and sym2.decl.kind == dkStruct:
    for f in sym2.decl.declStructFields:
      if f.ftype == nil: continue
      result.add((f.name, ctx.resolveTypeExpr(f.ftype)))

proc makeFieldPtrAt(ctx: var LowerCtx, base: HirNode, rootTe: TypeExpr,
                    rootTypeName: string, path: seq[string], fieldTy: Type,
                    loc: SourceLocation): HirNode =
  ## `&(base.a.b)` with typed intermediate field accesses (needed by LIR/C).
  if path.len == 0:
    return hirUnary(tkAmp, base, makePointer(fieldTy), loc)
  if path.len == 1:
    return HirNode(kind: hFieldPtr, fieldPtrBase: base, fieldName: path[0],
      typ: makePointer(fieldTy), loc: loc)
  # Build typed prefix: base.a.b for path [a,b,c] → access a, then b; ptr on c
  var cur = base
  var curTe = rootTe
  var curTypeName = rootTypeName
  for i in 0 ..< path.len - 1:
    let fields = ctx.structFieldsOf(curTe, curTypeName)
    var nextTy: Type = makeUnknown()
    for f in fields:
      if f.name == path[i]:
        nextTy = f.typ
        break
    cur = HirNode(kind: hFieldAccess, fieldAccessBase: cur,
      fieldAccessName: path[i], typ: nextTy, loc: loc)
    if nextTy != nil and nextTy.kind == tkNamed:
      curTypeName = nextTy.name
      curTe = TypeExpr(kind: tekNamed, typeName: nextTy.name)
    else:
      curTe = nil
      curTypeName = ""
  return HirNode(kind: hFieldPtr, fieldPtrBase: cur, fieldName: path[^1],
    typ: makePointer(fieldTy), loc: loc)

proc remainingDropsAt(ctx: var LowerCtx, baseHir: HirNode, typeName: string,
                      te: TypeExpr, prefix: seq[string],
                      moved: HashSet[string], loc: SourceLocation,
                      rootTe: TypeExpr, rootTypeName: string): seq[HirNode] =
  ## Emit Drops for fields of `typeName` under `baseHir`+`prefix`, respecting
  ## dotted moved paths (exact = fully moved; prefix = recurse nested).
  ## `rootTe`/`rootTypeName` are the original local's type (for path typing).
  result = @[]
  let fields = ctx.structFieldsOf(te, typeName)
  for f in fields:
    var fpath = prefix
    fpath.add(f.name)
    let key = pathKey(fpath)
    # Fully moved this field
    if key in moved:
      continue
    # Nested partial: some path starts with key + "."
    var nestedMoved = false
    for m in moved:
      if m.startsWith(key & "."):
        nestedMoved = true
        break
    if nestedMoved:
      let fty = f.typ
      if fty == nil or fty.kind != tkNamed: continue
      var fte = TypeExpr(kind: tekNamed, typeName: fty.name)
      result.add(ctx.remainingDropsAt(baseHir, fty.name, fte, fpath, moved, loc,
        rootTe, rootTypeName))
      continue
    # Unrelated field — full Drop if droppable
    let dropFn = ctx.autoDropFuncName(f.typ)
    if dropFn.len == 0: continue
    let fieldPtr = ctx.makeFieldPtrAt(baseHir, rootTe, rootTypeName, fpath, f.typ, loc)
    result.add(hirCall(dropFn, @[fieldPtr], makeVoid(), loc))

proc remainingFieldDrops(ctx: var LowerCtx, localName: string, loc: SourceLocation): seq[HirNode] =
  ## After a partial field move out of `localName`, Drop every *other* droppable
  ## field (including nested remaining after `a.b.c` moves).
  result = @[]
  if localName.len == 0 or not ctx.partialMovedFields.hasKey(localName):
    return
  let moved = ctx.partialMovedFields[localName]
  if not ctx.varTypeExprs.hasKey(localName):
    return
  let te = ctx.varTypeExprs[localName]
  if te == nil or te.kind != tekNamed:
    return
  let localTy = ctx.resolveTypeExpr(te)
  if localTy == nil or localTy.kind != tkNamed:
    return
  let base = hirVar(localName, localTy, loc)
  result = ctx.remainingDropsAt(base, localTy.name, te, @[], moved, loc, te, localTy.name)

proc emitDropOrPartial(ctx: var LowerCtx, stmts: var seq[HirNode], dropNode: HirNode,
                       skipName: string) =
  ## Emit Type_Drop, or remaining field Drops after a partial move.
  if not ctx.shouldSkipDrop(dropNode, skipName):
    stmts.add(dropNode)
    return
  let target = dropTargetName(dropNode)
  if target.len > 0 and target in ctx.partialMovedFields:
    let loc = if dropNode != nil: dropNode.loc else: SourceLocation()
    for d in ctx.remainingFieldDrops(target, loc):
      stmts.add(d)

proc autoDropFuncName(ctx: var LowerCtx, ty: Type): string =
  ## Return `Type_Drop` if this type should be auto-dropped, else "".
  ## Also monomorphizes generic Drop/Free helpers for stdlib collections.
  if ty == nil: return ""
  var typeName = ""
  if ty.kind == tkNamed:
    typeName = ty.name
  else:
    return ""
  # User type with @[Drop]
  let sym = ctx.globalScope.lookup(typeName)
  if sym != nil and sym.decl != nil and sym.decl.kind == dkStruct:
    if "Drop" in sym.decl.declAttrs:
      return typeName & "_Drop"
  # Explicit Type_Drop function exists (extend … for Drop)
  let dropSym = ctx.globalScope.lookup(typeName & "_Drop")
  if dropSym != nil and dropSym.kind == skFunc:
    return typeName & "_Drop"
  # Stdlib mangled collections: Array_int → Array_Drop_int
  if typeName.startsWith("Array_"):
    let elem = typeName[6 .. ^1]
    ctx.ensureDropMono("Array_Drop", "Array_Free", @[namedTypeArg(elem)])
    return "Array_Drop_" & elem
  if typeName.startsWith("Map_"):
    let rest = typeName[4 .. ^1]
    let us = rest.find('_')
    if us > 0:
      let k = rest[0 ..< us]
      let v = rest[us+1 .. ^1]
      ctx.ensureDropMono("Map_Drop", "Map_Free", @[namedTypeArg(k), namedTypeArg(v)])
    return "Map_Drop_" & rest
  if typeName.startsWith("Set_"):
    let elem = typeName[4 .. ^1]
    ctx.ensureDropMono("Set_Drop", "Set_Free", @[namedTypeArg(elem)])
    return "Set_Drop_" & elem
  if typeName.startsWith("Channel_"):
    let elem = typeName[8 .. ^1]
    ctx.ensureDropMono("Channel_Drop", "Channel_Free", @[namedTypeArg(elem)])
    return "Channel_Drop_" & elem
  return ""

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

proc enumHasDataVariants(ctx: var LowerCtx, enumName: string): bool =
  let sym = ctx.globalScope.lookup(enumName)
  if sym != nil and sym.decl != nil and sym.decl.kind == dkEnum:
    for v in sym.decl.declEnumVariants:
      if v.fields.len > 0 or v.namedFields.len > 0:
        return true
  return false

proc litTokenType(tok: Token): Type =
  case tok.kind
  of tkIntLiteral: makeInt()
  of tkFloatLiteral: makeFloat64()
  of tkStringLiteral: makeStr()
  of tkCharLiteral: makeChar32()
  of tkBoolLiteral: makeBool()
  else: makeUnknown()

proc patternLiteralNode(pat: Pattern, loc: SourceLocation): HirNode =
  ## Convert a pkLiteral pattern into an hLit node, or nil if not a literal.
  if pat == nil or pat.kind != pkLiteral:
    return nil
  return hirLit(pat.patLit, litTokenType(pat.patLit), loc)

proc matchPatternCond(ctx: var LowerCtx, subject: HirNode, pattern: Pattern,
                      subjectEnumName: string, subjectHasData: bool,
                      loc: SourceLocation): HirNode =
  ## Build a boolean condition for a match pattern.
  ## Returns nil for always-true arms (wildcard / catch-all).
  if pattern == nil:
    return nil
  case pattern.kind
  of pkWildcard, pkIdent:
    return nil
  of pkLiteral:
    let litNode = patternLiteralNode(pattern, loc)
    if litNode == nil:
      return nil
    return hirBinary(tkEq, subject, litNode, makeBool(), loc)
  of pkRange:
    let loNode = patternLiteralNode(pattern.patRangeLo, loc)
    let hiNode = patternLiteralNode(pattern.patRangeHi, loc)
    if loNode == nil or hiNode == nil:
      # Non-literal range endpoints — treat as always-true (best-effort)
      return nil
    let loOk = hirBinary(tkGe, subject, loNode, makeBool(), loc)
    let hiOp = if pattern.patRangeInclusive: tkLe else: tkLt
    let hiOk = hirBinary(hiOp, subject, hiNode, makeBool(), loc)
    return hirBinary(tkAmpAmp, loOk, hiOk, makeBool(), loc)
  of pkEnum:
    let path = pattern.patEnumPath
    if path.len >= 2:
      let enumName = path[0]
      let variantName = path[^1]
      let tagName = enumName & "_" & variantName
      if subjectHasData and enumName == subjectEnumName:
        # Algebraic enum: compare subject.tag
        let tagField = HirNode(kind: hFieldPtr, fieldPtrBase: subject, fieldName: "tag",
                               typ: makePointer(makeNamed(enumName & "_Tag")), loc: loc)
        let tagLoad = HirNode(kind: hLoad, loadPtr: tagField, typ: makeNamed(enumName & "_Tag"), loc: loc)
        let tagConst = hirLit(Token(kind: tkIdent, text: tagName, loc: loc), makeNamed(enumName & "_Tag"), loc)
        return hirBinary(tkEq, tagLoad, tagConst, makeBool(), loc)
      else:
        # Simple enum or cross-enum match: compare subject directly
        let tagConst = hirLit(Token(kind: tkIdent, text: tagName, loc: loc), makeNamed(enumName), loc)
        return hirBinary(tkEq, subject, tagConst, makeBool(), loc)
    # Single-segment enum path — always-true fallback
    return nil
  of pkGuarded:
    # Condition is only the inner pattern; guard is applied after bindings in lowerMatch.
    return matchPatternCond(ctx, subject, pattern.patGuardedInner, subjectEnumName, subjectHasData, loc)
  else:
    # Struct/tuple patterns: not yet fully lowered — always-true
    return nil

# lowerMatch calls lowerExpr for arm bodies after emitting bindings
proc lowerExpr(ctx: var LowerCtx, expr: Expr): HirNode

proc bindPatLocal(ctx: var LowerCtx, srcName: string, ty: Type, subject: HirNode,
                  loc: SourceLocation): seq[HirNode] =
  ## Allocate a unique C local for a pattern binding and map source name → C name.
  result = @[]
  if srcName.len == 0 or srcName == "_":
    return
  let cName = ctx.freshPatName(srcName)
  ctx.patternRenames[srcName] = cName
  ctx.patternBoundNames.incl(srcName)
  result.add(hirAlloca(cName, ty, loc))
  result.add(hirStore(hirVar(cName, ty, loc), subject, loc))

proc matchPatternBindings(ctx: var LowerCtx, subject: HirNode, pattern: Pattern,
                          subjectEnumName: string, subjectHasData: bool,
                          loc: SourceLocation): seq[HirNode] =
  ## Emit alloca+store for identifiers bound by a match pattern.
  ## Each binding gets a unique C name (`__pN_src`) so nested matches and
  ## outer `let` can share source names without C redeclaration / use-before-decl.
  ## Enum payload: `Option::Some(value)` → `value = subject.data.Some_0`
  ## Ident catch-all: `x` → `x = subject`
  result = @[]
  if pattern == nil: return
  case pattern.kind
  of pkIdent:
    let ty = if subject.typ != nil: subject.typ else: makeUnknown()
    result.add(ctx.bindPatLocal(pattern.patIdent, ty, subject, loc))
  of pkEnum:
    if not subjectHasData:
      return
    var enumName = ""
    var variantName = ""
    if pattern.patEnumPath.len >= 2:
      enumName = pattern.patEnumPath[0]
      variantName = pattern.patEnumPath[^1]
    elif pattern.patEnumPath.len == 1:
      variantName = pattern.patEnumPath[0]
      enumName = subjectEnumName
    if enumName == "" or variantName == "":
      return
    # Look up field types from enum declaration
    var fieldTypes: seq[Type] = @[]
    var namedFields: seq[tuple[name: string, typ: Type]] = @[]
    let enumSym = ctx.globalScope.lookup(enumName)
    if enumSym != nil and enumSym.decl != nil and enumSym.decl.kind == dkEnum:
      for v in enumSym.decl.declEnumVariants:
        if v.name == variantName:
          for f in v.fields:
            fieldTypes.add(ctx.resolveTypeExpr(f))
          for nf in v.namedFields:
            namedFields.add((nf.name, ctx.resolveTypeExpr(nf.ftype)))
          break
    let dataType = makeNamed(enumName & "_Data")
    let dataPtr = HirNode(kind: hFieldPtr, fieldPtrBase: subject, fieldName: "data",
                          typ: makePointer(dataType), loc: loc)
    let dataLoad = HirNode(kind: hLoad, loadPtr: dataPtr, typ: dataType, loc: loc)
    # Multi-field positional variants live in a nested struct data.Variant.{Variant_i}
    # Single-field stay flat as data.Variant_0 for ABI compat.
    let multiField = fieldTypes.len > 1
    var payloadBase = dataLoad
    if multiField:
      # Nested struct type Enum_Variant_Payload (avoids clash with tag Enum_Variant)
      let nestedName = enumName & "_" & variantName & "_Payload"
      let variantStructTy = makeNamed(nestedName)
      let variantPtr = HirNode(kind: hFieldPtr, fieldPtrBase: dataLoad, fieldName: variantName,
                               typ: makePointer(variantStructTy), loc: loc)
      payloadBase = HirNode(kind: hLoad, loadPtr: variantPtr, typ: variantStructTy, loc: loc)
    for i, arg in pattern.patEnumArgs:
      if arg == nil:
        continue
      let fieldName = variantName & "_" & $i
      let fieldTy = if i < fieldTypes.len: fieldTypes[i] else: makeInt()
      let fieldPtr = HirNode(kind: hFieldPtr, fieldPtrBase: payloadBase, fieldName: fieldName,
                             typ: makePointer(fieldTy), loc: loc)
      let fieldLoad = HirNode(kind: hLoad, loadPtr: fieldPtr, typ: fieldTy, loc: loc)
      if arg.kind == pkIdent:
        result.add(ctx.bindPatLocal(arg.patIdent, fieldTy, fieldLoad, loc))
      else:
        # Nested: Option::Some((a, b)), Pair::Two(Point { x, y })
        result.add(ctx.matchPatternBindings(fieldLoad, arg, subjectEnumName, subjectHasData, loc))
    for nf in pattern.patEnumNamed:
      if nf.pattern == nil:
        continue
      var fieldTy = makeInt()
      for entry in namedFields:
        if entry.name == nf.name:
          fieldTy = entry.typ
          break
      # Named payload fields live under data.Variant.name on Enum_Variant_Payload
      let nestedName = enumName & "_" & variantName & "_Payload"
      let variantStructTy = makeNamed(nestedName)
      let variantPtr = HirNode(kind: hFieldPtr, fieldPtrBase: dataLoad, fieldName: variantName,
                               typ: makePointer(variantStructTy), loc: loc)
      let variantLoad = HirNode(kind: hLoad, loadPtr: variantPtr, typ: variantStructTy, loc: loc)
      let fieldPtr = HirNode(kind: hFieldPtr, fieldPtrBase: variantLoad, fieldName: nf.name,
                             typ: makePointer(fieldTy), loc: loc)
      let fieldLoad = HirNode(kind: hLoad, loadPtr: fieldPtr, typ: fieldTy, loc: loc)
      if nf.pattern.kind == pkIdent:
        result.add(ctx.bindPatLocal(nf.pattern.patIdent, fieldTy, fieldLoad, loc))
      else:
        result.add(ctx.matchPatternBindings(fieldLoad, nf.pattern, subjectEnumName, subjectHasData, loc))
  of pkGuarded:
    result.add(ctx.matchPatternBindings(subject, pattern.patGuardedInner, subjectEnumName, subjectHasData, loc))
  of pkTuple:
    # (a, b) => bind a = subject._0, b = subject._1
    for i, elem in pattern.patTupleElements:
      if elem == nil:
        continue
      let fieldName = "_" & $i
      let fieldTy = if subject.typ != nil and subject.typ.kind == tkTuple and i < subject.typ.inner.len:
                      subject.typ.inner[i]
                    else: makeInt()
      let fieldPtr = HirNode(kind: hFieldPtr, fieldPtrBase: subject, fieldName: fieldName,
                             typ: makePointer(fieldTy), loc: loc)
      let fieldLoad = HirNode(kind: hLoad, loadPtr: fieldPtr, typ: fieldTy, loc: loc)
      if elem.kind == pkIdent:
        result.add(ctx.bindPatLocal(elem.patIdent, fieldTy, fieldLoad, loc))
      else:
        # Nested patterns: recurse with field as subject
        result.add(ctx.matchPatternBindings(fieldLoad, elem, subjectEnumName, subjectHasData, loc))
  of pkStruct:
    # Point { x: px, y: py } => px = subject.x, py = subject.y
    var structName = pattern.patStructName
    if structName.len == 0 and subject.typ != nil and subject.typ.kind == tkNamed:
      structName = subject.typ.name
    var fieldTypes = initTable[string, Type]()
    if structName.len > 0:
      let ssym = ctx.globalScope.lookup(structName)
      if ssym != nil and ssym.decl != nil and ssym.decl.kind == dkStruct:
        for f in ssym.decl.declStructFields:
          fieldTypes[f.name] = ctx.resolveTypeExpr(f.ftype)
    for entry in pattern.patStructFields:
      let fname = entry.name
      let fpat = entry.pattern
      if fpat == nil:
        continue
      let fieldTy = if fieldTypes.hasKey(fname): fieldTypes[fname] else: makeInt()
      let fieldPtr = HirNode(kind: hFieldPtr, fieldPtrBase: subject, fieldName: fname,
                             typ: makePointer(fieldTy), loc: loc)
      let fieldLoad = HirNode(kind: hLoad, loadPtr: fieldPtr, typ: fieldTy, loc: loc)
      if fpat.kind == pkIdent:
        result.add(ctx.bindPatLocal(fpat.patIdent, fieldTy, fieldLoad, loc))
      else:
        result.add(ctx.matchPatternBindings(fieldLoad, fpat, subjectEnumName, subjectHasData, loc))
  else:
    discard

proc lowerMatch(ctx: var LowerCtx, subject: HirNode, astArms: seq[MatchArm], typ: Type, loc: SourceLocation): HirNode =
  ## Lower match expression to sequential ifs with a `found` flag.
  ## Supports: enum tags + payload bindings, integer/bool/char/string literals,
  ## ranges, wildcard/ident catch-all, and `p if guard` arms.
  ##
  ## Each arm:
  ##   1. emit unique pattern bindings (sets patternRenames)
  ##   2. lower guard + body (idents use renames)
  ##   3. restore renames
  ##   if (!found) { if (cond) { binds; if (guard) { result=body; found=true } } }
  let hasResult = typ != nil and typ.kind != tkVoid and typ.kind != tkUnknown
  let resultName = ctx.freshName()
  let foundName = ctx.freshName()
  var stmts: seq[HirNode] = @[]

  if hasResult:
    stmts.add(hirAlloca(resultName, typ, loc))
  stmts.add(hirAlloca(foundName, makeBool(), loc))
  stmts.add(hirStore(hirVar(foundName, makeBool(), loc),
                     hirLit(Token(kind: tkBoolLiteral, text: "false", loc: loc), makeBool(), loc), loc))

  var subjectEnumName = ""
  var subjectHasData = false
  if subject.typ != nil and subject.typ.kind == tkNamed:
    subjectEnumName = subject.typ.name
    subjectHasData = ctx.enumHasDataVariants(subjectEnumName)

  for arm in astArms:
    # Snapshot renames so this arm's bindings don't leak to later arms
    let savedRenames = ctx.patternRenames

    var innerPat = arm.pattern
    if arm.pattern != nil and arm.pattern.kind == pkGuarded:
      innerPat = arm.pattern.patGuardedInner

    # Register bind types for resolveExprType during body lower
    if innerPat != nil and innerPat.kind == pkEnum and subjectHasData:
      var enumName = ""
      var variantName = ""
      if innerPat.patEnumPath.len >= 2:
        enumName = innerPat.patEnumPath[0]
        variantName = innerPat.patEnumPath[^1]
      elif innerPat.patEnumPath.len == 1:
        variantName = innerPat.patEnumPath[0]
        enumName = subjectEnumName
      var fieldTypes: seq[Type] = @[]
      let enumSym = ctx.globalScope.lookup(enumName)
      if enumSym != nil and enumSym.decl != nil and enumSym.decl.kind == dkEnum:
        for v in enumSym.decl.declEnumVariants:
          if v.name == variantName:
            for f in v.fields:
              fieldTypes.add(ctx.resolveTypeExpr(f))
            break
      for i, arg in innerPat.patEnumArgs:
        if arg != nil and arg.kind == pkIdent:
          let ft = if i < fieldTypes.len: fieldTypes[i] else: makeInt()
          ctx.varTypeExprs[arg.patIdent] = typeToTypeExpr(ft)
    elif innerPat != nil and innerPat.kind == pkIdent:
      let ty = if subject.typ != nil: subject.typ else: makeUnknown()
      ctx.varTypeExprs[innerPat.patIdent] = typeToTypeExpr(ty)

    # Bindings BEFORE body so (1) renames active (2) alloca precedes use in C
    let binds = matchPatternBindings(ctx, subject, innerPat, subjectEnumName, subjectHasData, loc)

    var guardHir: HirNode = nil
    if arm.pattern != nil and arm.pattern.kind == pkGuarded and arm.pattern.patGuardedExpr != nil:
      guardHir = ctx.lowerExpr(arm.pattern.patGuardedExpr)
    let bodyHir = ctx.lowerExpr(arm.body)

    # Pop this arm's renames (nested matches already restored themselves)
    ctx.patternRenames = savedRenames

    var successStmts: seq[HirNode] = @[]
    if hasResult:
      successStmts.add(hirStore(hirVar(resultName, typ, loc), bodyHir, loc))
    elif bodyHir != nil:
      successStmts.add(bodyHir)
    successStmts.add(hirStore(hirVar(foundName, makeBool(), loc),
                              hirLit(Token(kind: tkBoolLiteral, text: "true", loc: loc), makeBool(), loc), loc))
    let successBlock = hirBlock(successStmts, nil, makeVoid(), loc)

    var afterBinds: HirNode
    if guardHir != nil:
      afterBinds = HirNode(kind: hIf, ifCond: guardHir, ifThen: successBlock, ifElse: nil,
                           typ: makeVoid(), loc: loc)
    else:
      afterBinds = successBlock

    var armInnerStmts = binds
    armInnerStmts.add(afterBinds)
    let armInner = hirBlock(armInnerStmts, nil, makeVoid(), loc)

    let cond = matchPatternCond(ctx, subject, innerPat, subjectEnumName, subjectHasData, loc)
    let armBody = if cond == nil: armInner
                  else: HirNode(kind: hIf, ifCond: cond, ifThen: armInner, ifElse: nil,
                                typ: makeVoid(), loc: loc)

    let notFound = HirNode(kind: hUnary, unaryOp: tkBang,
                           unaryOperand: hirVar(foundName, makeBool(), loc),
                           typ: makeBool(), loc: loc)
    stmts.add(HirNode(kind: hIf, ifCond: notFound, ifThen: armBody, ifElse: nil,
                      typ: makeVoid(), loc: loc))

  if hasResult:
    return hirBlock(stmts, hirVar(resultName, typ, loc), typ, loc)
  return hirBlock(stmts, nil, makeVoid(), loc)

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
  result.funcAdapters = initHashSet[string]()
  result.funcAdapterSigs = initTable[string, Type]()
  result.seenFatTypes = @[]
  result.patternBoundNames = initHashSet[string]()
  result.patternRenames = initTable[string, string]()
  result.movedOutLocals = initHashSet[string]()
  result.partialMovedFields = initTable[string, HashSet[string]]()
  result.ptrAliases = initTable[string, string]()

proc sanitizeFatPart(s: string): string =
  result = s.replace("const char*", "cstr").replace("unsigned int", "uint")
  result = result.replace(" ", "_").replace("*", "Ptr").replace("(", "").replace(")", "").replace(",", "_").replace(".", "_")

proc typeNameForFat(typ: Type): string
proc hirFuncFatTypeName*(typ: Type): string

proc typeNameForFat(typ: Type): string =
  ## Lightweight C-ish name for fat-func mangling (mirrors lir typeToCStr subset).
  if typ == nil: return "void"
  case typ.kind
  of tkVoid: return "void"
  of tkBool, tkBool8, tkBool16, tkBool32: return "bool"
  of tkStr: return "cstr"
  of tkInt, tkInt8, tkInt16, tkInt32, tkInt64: return "int"
  of tkUInt, tkUInt8, tkUInt16, tkUInt32, tkUInt64: return "uint"
  of tkFloat32: return "float"
  of tkFloat64: return "double"
  of tkPointer, tkRef, tkMutRef:
    if typ.inner.len > 0: return sanitizeFatPart(typeNameForFat(typ.inner[0]) & "Ptr")
    return "voidPtr"
  of tkNamed:
    case typ.name
    of "String", "str": return "cstr"
    else: return sanitizeFatPart(typ.name)
  of tkFunc:
    return hirFuncFatTypeName(typ)
  else:
    return "int"

proc hirFuncFatTypeName*(typ: Type): string =
  if typ == nil or typ.kind != tkFunc: return "BuxFn_void"
  let ret = if typ.inner.len > 0: typeNameForFat(typ.inner[^1]) else: "void"
  var parts: seq[string] = @[sanitizeFatPart(ret)]
  if typ.inner.len > 1:
    for p in typ.inner[0 ..^ 2]:
      parts.add(sanitizeFatPart(typeNameForFat(p)))
  else:
    parts.add("void")
  return "BuxFn_" & parts.join("_")

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
  of tekRef: return makeRef(ctx.resolveTypeExpr(te.pointerPointee))
  of tekMutRef: return makeMutRef(ctx.resolveTypeExpr(te.pointerPointee))
  of tekSlice: return makeSlice(ctx.resolveTypeExpr(te.sliceElement))
  of tekTuple:
    var elems: seq[Type] = @[]
    for e in te.tupleElements:
      elems.add(ctx.resolveTypeExpr(e))
    return makeTuple(elems)
  of tekFunc:
    var params: seq[Type] = @[]
    for p in te.funcParams:
      params.add(ctx.resolveTypeExpr(p))
    let ret = if te.funcRet != nil: ctx.resolveTypeExpr(te.funcRet) else: makeVoid()
    return makeFunc(params, ret)
  else: return makeUnknown()

# Forward declarations (lowerExpr already declared above for lowerMatch)
proc lowerStmt(ctx: var LowerCtx, stmt: Stmt): HirNode
proc lowerBlock(ctx: var LowerCtx, blk: Block, asExpr = false): HirNode
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
    # Local / param fat-func values (after monomorphization typeSubst) — e.g. f: func(T)->U
    # Must run before the global-only lookup so generic HOFs get the correct return type.
    if expr.exprCallCallee.kind in {ekIdent, ekPath}:
      let calType = ctx.resolveExprType(expr.exprCallCallee)
      if calType != nil and calType.kind == tkFunc and calType.inner.len > 0:
        return calType.inner[^1]
    if expr.exprCallCallee.kind == ekIdent:
      let sym = ctx.globalScope.lookup(expr.exprCallCallee.exprIdent)
      if sym != nil and sym.typ != nil and sym.typ.kind == tkFunc and sym.typ.inner.len > 0:
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
                  if f.ftype.typeArgs.len > 0:
                    return substituteType(ctx, f.ftype, subst)
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
                  if f.ftype.typeArgs.len > 0:
                    return ctx.resolveTypeExpr(f.ftype)
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
    let hiType = ctx.resolveExprType(expr.exprRangeHi)
    if loType == hiType:
      return makeRange(loType)
    elif loType.isAssignableTo(hiType):
      return makeRange(hiType)
    elif hiType.isAssignableTo(loType):
      return makeRange(loType)
    else:
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
  of ekMatch:
    if expr.exprMatchArms.len > 0:
      return ctx.resolveExprType(expr.exprMatchArms[0].body)
    return makeUnknown()
  of ekBlock:
    if expr.exprBlock.stmts.len > 0:
      let last = expr.exprBlock.stmts[^1]
      if last.kind == skExpr:
        return ctx.resolveExprType(last.stmtExpr)
    return makeVoid()
  of ekBorrow:
    return ctx.resolveExprType(expr.exprBorrowOperand)
  of ekClosure:
    var params: seq[Type] = @[]
    for p in expr.exprClosureParams:
      if p.ptype != nil:
        params.add(ctx.resolveTypeExpr(p.ptype))
      else:
        params.add(makeUnknown())
    let ret = if expr.exprClosureReturnType != nil:
      ctx.resolveTypeExpr(expr.exprClosureReturnType)
    else:
      makeVoid()
    return makeFunc(params, ret)
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

proc getCollectionElementTypeExpr(ctx: var LowerCtx, expr: Expr): TypeExpr =
  ## Return the element TypeExpr of a collection expression (Array<T>, Iter<T>, Channel<T>).
  ## For identifiers we can use the declared TypeExpr directly; for other expressions we
  ## fall back to the resolved concrete Type.
  case expr.kind
  of ekIdent:
    if ctx.varTypeExprs.hasKey(expr.exprIdent):
      let te = ctx.varTypeExprs[expr.exprIdent]
      if te.kind == tekNamed and te.typeArgs.len > 0:
        return te.typeArgs[0]
      if te.kind in {tekPointer, tekRef, tekMutRef} and te.pointerPointee.kind == tekNamed and te.pointerPointee.typeArgs.len > 0:
        return te.pointerPointee.typeArgs[0]
  of ekField:
    # Try to resolve the field's declared TypeExpr directly.
    let objType = ctx.resolveExprType(expr.exprFieldObj)
    if objType.kind == tkNamed:
      var decl = ctx.globalScope.lookup(objType.name).decl
      if decl == nil and ctx.structInstMap.hasKey(objType.name):
        let (baseName, _) = ctx.structInstMap[objType.name]
        let baseSym = ctx.globalScope.lookup(baseName)
        if baseSym != nil and baseSym.decl != nil and baseSym.decl.kind == dkStruct:
          decl = baseSym.decl
      if decl != nil and decl.kind == dkStruct:
        for f in decl.declStructFields:
          if f.name == expr.exprFieldName and f.ftype != nil:
            let fte = f.ftype
            if fte.kind == tekNamed and fte.typeArgs.len > 0 and (fte.typeName == "Array" or fte.typeName == "Iter" or fte.typeName == "Channel"):
              return fte.typeArgs[0]
            return fte
  else:
    discard
  let t = ctx.resolveExprType(expr)
  if t.kind == tkNamed and t.inner.len > 0:
    return typeToTypeExpr(t.inner[0])
  if t.isPointer and t.inner.len > 0 and t.inner[0].kind == tkNamed and t.inner[0].inner.len > 0:
    return typeToTypeExpr(t.inner[0].inner[0])
  # Generic struct instances (e.g. Array_HeaderEntry) store their type args in structInstMap.
  if t.kind == tkNamed and ctx.structInstMap.hasKey(t.name):
    let (baseName, concreteArgs) = ctx.structInstMap[t.name]
    if concreteArgs.len > 0 and (baseName == "Array" or baseName == "Iter" or baseName == "Channel"):
      return typeToTypeExpr(concreteArgs[0])
  return TypeExpr(kind: tekNamed, typeName: "unknown")

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
    # Pattern binding rename: source name → unique C local (`__pN_v`)
    if ctx.patternRenames.hasKey(name):
      let cName = ctx.patternRenames[name]
      return hirVar(cName, typ, loc)
    # Capture rewriting: if inside closure and ident is captured
    if ctx.closureDepth > 0 and ctx.currentClosureExpr != nil and ctx.envInstanceName != "":
      let idx = ctx.currentClosureExpr.captureNames.find(name)
      if idx >= 0:
        let capType = if idx < ctx.currentClosureExpr.captureTypeKinds.len: Type(kind: TypeKind(ctx.currentClosureExpr.captureTypeKinds[idx])) else: makeInt()
        let base = hirVar(ctx.envInstanceName, makeNamed(""), loc)
        return HirNode(kind: hFieldAccess, fieldAccessName: name, fieldAccessBase: base, typ: capType, loc: loc)
    var resolvedName = name
    if ctx.importTable.hasKey(name):
      resolvedName = ctx.importTable[name]
    # Named function used as a value → fat function pointer via adapter
    if typ != nil and typ.kind == tkFunc:
      let sym = ctx.globalScope.lookup(name)
      let sym2 = if sym == nil: ctx.globalScope.lookup(resolvedName) else: sym
      if sym2 != nil and sym2.kind == skFunc:
        let adaptName = "__adapt_" & resolvedName
        ctx.funcAdapters.incl(resolvedName)
        ctx.funcAdapterSigs[resolvedName] = typ
        let fatName = hirFuncFatTypeName(typ)
        let nullEnv = HirNode(kind: hCast,
          castOperand: hirLit(Token(kind: tkIntLiteral, text: "0", loc: loc), makeInt(), loc),
          castType: makePointer(makeVoid()), typ: makePointer(makeVoid()), loc: loc)
        return HirNode(kind: hStructInit, structInitName: fatName, structInitFields: @[
          (name: "code", value: hirVar(adaptName, makePointer(makeVoid()), loc)),
          (name: "env", value: nullEnv)
        ], typ: typ, loc: loc)
    return hirVar(resolvedName, typ, loc)

  of ekPath:
    # Handle enum variants: Color::Red → Color_Red
    # or module paths: Std::Io::PrintLine → Std_Io_PrintLine
    let mangledName = expr.exprPath.join("_")
    return hirVar(mangledName, typ, loc)

  of ekSelf:
    return hirSelf(typ, loc)

  of ekUnary:
    # &NamedFunc used as func value → fat adapter (not a raw C function pointer)
    if expr.exprUnaryOp == tkAmp and expr.exprUnaryOperand != nil and
       expr.exprUnaryOperand.kind == ekIdent:
      let fname = expr.exprUnaryOperand.exprIdent
      var resolved = fname
      if ctx.importTable.hasKey(fname):
        resolved = ctx.importTable[fname]
      let sym = ctx.globalScope.lookup(resolved)
      if sym != nil and sym.kind == skFunc:
        # Prefer declared func type on the symbol; fall back to expression type
        var ftyp = if sym.typ != nil and sym.typ.kind == tkFunc: sym.typ else: typ
        if ftyp == nil or ftyp.kind != tkFunc:
          ftyp = ctx.resolveExprType(expr.exprUnaryOperand)
        if ftyp != nil and ftyp.kind == tkFunc:
          let adaptName = "__adapt_" & resolved
          ctx.funcAdapters.incl(resolved)
          ctx.funcAdapterSigs[resolved] = ftyp
          ctx.seenFatTypes.add(ftyp)
          let fatName = hirFuncFatTypeName(ftyp)
          let nullEnv = HirNode(kind: hCast,
            castOperand: hirLit(Token(kind: tkIntLiteral, text: "0", loc: loc), makeInt(), loc),
            castType: makePointer(makeVoid()), typ: makePointer(makeVoid()), loc: loc)
          return HirNode(kind: hStructInit, structInitName: fatName, structInitFields: @[
            (name: "code", value: hirVar(adaptName, makePointer(makeVoid()), loc)),
            (name: "env", value: nullEnv)
          ], typ: ftyp, loc: loc)
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
    # Cross-function pointer ownership (before any lowering side effects)
    ctx.markCrossFuncPtrMoves(expr)
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
      # Named global function → direct call
      let sym = ctx.globalScope.lookup(calleeName)
      if sym != nil and sym.kind == skFunc:
        return hirCall(calleeName, args, typ, loc)
      # Variable holding a fat function pointer → indirect call
      let ct = ctx.resolveExprType(expr.exprCallCallee)
      if ct != nil and ct.kind == tkFunc:
        let callee = hirVar(calleeName, ct, loc)
        return HirNode(kind: hCallIndirect, callIndirectCallee: callee,
                       callIndirectArgs: args, typ: typ, loc: loc)
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
    # `*p = value` must store through the pointer, not assign to a loaded temp.
    # Represent as hAssign to hLoad(loadPtr=p) so LIR emits `*p = value`.
    if expr.exprAssignTarget.kind == ekUnary and expr.exprAssignTarget.exprUnaryOp == tkStar:
      let destPtr = ctx.lowerExpr(expr.exprAssignTarget.exprUnaryOperand)
      let value = ctx.lowerExpr(expr.exprAssignValue)
      let loadTarget = HirNode(kind: hLoad, loadPtr: destPtr, typ: typ, loc: loc)
      return HirNode(kind: hAssign, assignOp: tkAssign,
                     assignTarget: loadTarget, assignValue: value,
                     typ: makeVoid(), loc: loc)
    # Pointer alias update: `p = &bag`
    if expr.exprAssignTarget.kind == ekIdent and expr.exprAssignValue != nil:
      ctx.recordPtrAliasFromAst(expr.exprAssignTarget.exprIdent, expr.exprAssignValue)
    let target = ctx.lowerExpr(expr.exprAssignTarget)
    let value = ctx.lowerExpr(expr.exprAssignValue)
    return HirNode(kind: hAssign, assignOp: expr.exprAssignOp,
                   assignTarget: target, assignValue: value,
                   typ: makeVoid(), loc: loc)

  of ekStructInit:
    # Field values are taken by value → move ownership out of droppable locals
    ctx.markMovedOutFromAst(expr)
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
    return ctx.lowerBlock(expr.exprBlock, asExpr = true)

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
    # Prefer resolved match type; fall back to function return type when arms
    # only reference pattern bindings (not yet in varTypeExprs during resolve).
    var matchTyp = typ
    if matchTyp == nil or matchTyp.kind == tkUnknown:
      if ctx.currentFuncRetType != nil and ctx.currentFuncRetType.kind notin {tkVoid, tkUnknown}:
        matchTyp = ctx.currentFuncRetType
    # Register bind types early so matchTyp fallback can resolve arm bodies
    var subjectEnumName = ""
    var subjectHasData = false
    if subject.typ != nil and subject.typ.kind == tkNamed:
      subjectEnumName = subject.typ.name
      subjectHasData = ctx.enumHasDataVariants(subjectEnumName)
    for arm in expr.exprMatchArms:
      var bindPat = arm.pattern
      if bindPat != nil and bindPat.kind == pkGuarded:
        bindPat = bindPat.patGuardedInner
      if bindPat != nil and bindPat.kind == pkEnum and subjectHasData:
        var enumName = ""
        var variantName = ""
        if bindPat.patEnumPath.len >= 2:
          enumName = bindPat.patEnumPath[0]
          variantName = bindPat.patEnumPath[^1]
        elif bindPat.patEnumPath.len == 1:
          variantName = bindPat.patEnumPath[0]
          enumName = subjectEnumName
        var fieldTypes: seq[Type] = @[]
        let enumSym = ctx.globalScope.lookup(enumName)
        if enumSym != nil and enumSym.decl != nil and enumSym.decl.kind == dkEnum:
          for v in enumSym.decl.declEnumVariants:
            if v.name == variantName:
              for f in v.fields:
                fieldTypes.add(ctx.resolveTypeExpr(f))
              break
        for i, arg in bindPat.patEnumArgs:
          if arg != nil and arg.kind == pkIdent:
            let ft = if i < fieldTypes.len: fieldTypes[i] else: makeInt()
            ctx.varTypeExprs[arg.patIdent] = typeToTypeExpr(ft)
      elif bindPat != nil and bindPat.kind == pkIdent:
        let ty = if subject.typ != nil: subject.typ else: makeUnknown()
        ctx.varTypeExprs[bindPat.patIdent] = typeToTypeExpr(ty)
    # Binds + body lower happen inside lowerMatch (unique C names + renames)
    return lowerMatch(ctx, subject, expr.exprMatchArms, matchTyp, loc)

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
    if typ != nil and typ.kind == tkFunc:
      ctx.seenFatTypes.add(typ)
    let fatName = hirFuncFatTypeName(typ)
    if expr.captureCount > 0 and f.envStructName.len > 0:
      # Heap-allocate a fresh env so each closure value is independent
      let envTmp = "__envp_" & $ctx.varCounter
      inc ctx.varCounter
      let fatTmp = "__fat_" & $ctx.varCounter
      inc ctx.varCounter
      var code = ""
      code.add(&"{f.envStructName}* {envTmp} = ({f.envStructName}*)bux_alloc(sizeof({f.envStructName}));\n")
      for i in 0 ..< expr.captureCount:
        let capName = expr.captureNames[i]
        code.add(&"{envTmp}->{capName} = {capName};\n")
      code.add(&"{fatName} {fatTmp} = {{ .code = {f.name}, .env = {envTmp} }};")
      ctx.pendingStmts.add(HirNode(kind: hEmit, emitCode: code, typ: makeVoid(), loc: loc))
      return hirVar(fatTmp, typ, loc)
    else:
      # Capture-less: fat pointer with NULL env
      let nullEnv = HirNode(kind: hCast,
        castOperand: hirLit(Token(kind: tkIntLiteral, text: "0", loc: loc), makeInt(), loc),
        castType: makePointer(makeVoid()), typ: makePointer(makeVoid()), loc: loc)
      return HirNode(kind: hStructInit, structInitName: fatName, structInitFields: @[
        (name: "code", value: hirVar(f.name, makePointer(makeVoid()), loc)),
        (name: "env", value: nullEnv)
      ], typ: typ, loc: loc)

  else:
    return HirNode(kind: hLit, litToken: Token(kind: tkIntLiteral, text: "0", loc: loc),
                   typ: makeVoid(), loc: loc)

proc lowerStmt(ctx: var LowerCtx, stmt: Stmt): HirNode =
  if stmt == nil: return nil
  let loc = stmt.loc

  case stmt.kind
  of skExpr:
    if stmt.stmtExpr != nil:
      ctx.markMovedOutFromAst(stmt.stmtExpr)
    return ctx.flushPending(ctx.lowerExpr(stmt.stmtExpr))

  of skLet:
    var initHir: HirNode = nil
    if stmt.stmtLetInit != nil:
      initHir = ctx.lowerExpr(stmt.stmtLetInit)
    let allocaType = if stmt.stmtLetType != nil:
      # Full resolve covers named, pointer, slice, tuple, func, refs, etc.
      ctx.resolveTypeExpr(stmt.stmtLetType)
    elif stmt.stmtLetInit != nil:
      ctx.resolveExprType(stmt.stmtLetInit)
    else:
      makeUnknown()
    if allocaType != nil and allocaType.kind == tkFunc:
      ctx.seenFatTypes.add(allocaType)

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
    # Pointer alias: `let p = &bag` so later `p.items` marks bag (session 74)
    if stmt.stmtLetInit != nil:
      ctx.recordPtrAliasFromAst(stmt.stmtLetName, stmt.stmtLetInit)
    # Move: `let a = b` takes ownership of droppable local `b`
    if stmt.stmtLetInit != nil:
      ctx.markMovedOutFromAst(stmt.stmtLetInit)
    # Auto-Drop: @[Drop] types and Array/Map/etc. with TypeName_Drop
    let dropName = ctx.autoDropFuncName(allocaType)
    if dropName.len > 0:
      let addrOf = hirUnary(tkAmp, hirVar(stmt.stmtLetName, allocaType, loc),
                            makePointer(allocaType), loc)
      let dropCall = hirCall(dropName, @[addrOf], makeVoid(), loc)
      ctx.deferStmts.add(dropCall)
    # Capture filling for closures is done at the ekClosure site (heap env).
    return hirBlock(stmts, nil, makeVoid(), loc)

  of skReturn:
    # Mark moves before lowering so struct-field moves are recorded
    if stmt.stmtReturnValue != nil:
      ctx.markMovedOutFromAst(stmt.stmtReturnValue)
    let value = if stmt.stmtReturnValue != nil: ctx.lowerExpr(stmt.stmtReturnValue) else: nil
    var stmts = ctx.pendingStmts
    ctx.pendingStmts = @[]
    # Move-on-return: do not Drop a local that is returned by value.
    var skipDrop = ""
    if value != nil and value.kind == hVar:
      skipDrop = value.varName
      ctx.markMovedOutLocal(value.varName)
    # Materialize the return value BEFORE drops so `return a.id` is not
    # use-after-drop (drops are separate stmts; LIR evaluates return expr last).
    var retVal = value
    if value != nil and ctx.deferStmts.len > 0:
      let retTy = if value.typ != nil: value.typ else: makeUnknown()
      if retTy.kind != tkVoid:
        let tmp = ctx.freshName()
        stmts.add(hirAlloca(tmp, retTy, loc))
        stmts.add(hirStore(hirVar(tmp, retTy, loc), value, loc))
        retVal = hirVar(tmp, retTy, loc)
    # Add defers in reverse order (LIFO); snapshot full stack for every return path
    for i in countdown(ctx.deferStmts.len - 1, 0):
      ctx.emitDropOrPartial(stmts, ctx.deferStmts[i], skipDrop)
    stmts.add(hirReturn(retVal, loc))
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
      let rangeType = ctx.resolveExprType(iterExpr)
      let varType = if rangeType.inner.len > 0: rangeType.inner[0] else: ctx.resolveExprType(iterExpr.exprRangeLo)
      
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
    
    # Collection-based for: for x in collection { body }
    let collType = ctx.resolveExprType(iterExpr)
    let elemTypeExpr = ctx.getCollectionElementTypeExpr(iterExpr)
    let elemType = ctx.resolveTypeExpr(elemTypeExpr)
    # Resolve the collection type to its mangled struct instance (e.g. Array<int> -> Array_int).
    let collTypeMangled = substituteType(ctx, typeToTypeExpr(collType), ctx.typeSubst)

    let isChannel = collType.kind == tkNamed and collType.name.startsWith("Channel")

    if isChannel:
      # Channel lowering:
      #   alloca x
      #   while (true) {
      #       if (!Channel_Recv_Ok_T(&ch, &x)) break;
      #       body
      #   }
      let recvOkName = ctx.generateMethodInstance("Channel_Recv_Ok", @[elemTypeExpr])

      let xAlloca = hirAlloca(varName, elemType, loc)
      let xVar = hirVar(varName, elemType, loc)

      ctx.varTypeExprs[varName] = elemTypeExpr

      let chAddr = HirNode(kind: hUnary, unaryOp: tkAmp, unaryOperand: ctx.lowerExpr(iterExpr),
                           typ: makePointer(collType), loc: loc)
      let xAddr = HirNode(kind: hUnary, unaryOp: tkAmp, unaryOperand: xVar,
                          typ: makePointer(elemType), loc: loc)
      let recvOkCall = hirCall(recvOkName, @[chAddr, xAddr], makeBool(), loc)
      let notRecvOk = HirNode(kind: hUnary, unaryOp: tkBang, unaryOperand: recvOkCall,
                              typ: makeBool(), loc: loc)
      let breakNode = HirNode(kind: hBreak, loc: loc)
      let ifNode = HirNode(kind: hIf, ifCond: notRecvOk, ifThen: breakNode, ifElse: nil,
                           typ: makeVoid(), loc: loc)

      let loweredBody = ctx.lowerBlock(body)
      var whileBodyStmts: seq[HirNode] = @[]
      whileBodyStmts.add(xAlloca)
      whileBodyStmts.add(ifNode)
      if loweredBody != nil:
        whileBodyStmts.add(loweredBody)
      let whileBody = hirBlock(whileBodyStmts, nil, makeVoid(), loc)

      let trueLit = hirLit(Token(kind: tkBoolLiteral, text: "true", loc: loc), makeBool(), loc)
      let whileNode = HirNode(kind: hWhile, whileCond: trueLit, whileBody: whileBody,
                              typ: makeVoid(), loc: loc)

      let forBlock = hirBlock(@[whileNode], nil, makeVoid(), loc, isScope = true)
      return ctx.flushPending(forBlock)

    # Array / Iter lowering:
    #   alloca __iter
    #   __iter = Array_Iter_T(&collection);
    #   while (Iter_HasNext_T(&__iter)) {
    #       alloca x
    #       x = Iter_Next_T(&__iter);
    #       body
    #   }
    let iterFuncName = ctx.generateMethodInstance("Array_Iter", @[elemTypeExpr])
    let hasNextFuncName = ctx.generateMethodInstance("Iter_HasNext", @[elemTypeExpr])
    let nextFuncName = ctx.generateMethodInstance("Iter_Next", @[elemTypeExpr])

    # Ensure Iter<T> struct instance exists and resolve its mangled name.
    let iterType = substituteType(ctx, TypeExpr(kind: tekNamed, typeName: "Iter", typeArgs: @[elemTypeExpr]), ctx.typeSubst)

    let iterVarName = "__iter_" & varName & "_" & $ctx.varCounter
    inc ctx.varCounter

    # Build collection pointer. If the collection is not a simple identifier, spill to a temp.
    var preStmts: seq[HirNode] = @[]
    var collPtr: HirNode = nil
    if iterExpr.kind == ekIdent:
      let collVar = hirVar(iterExpr.exprIdent, collType, loc)
      collPtr = HirNode(kind: hUnary, unaryOp: tkAmp, unaryOperand: collVar,
                        typ: makePointer(collType), loc: loc)
    else:
      let collAllocaName = ctx.freshName()
      let collAlloca = hirAlloca(collAllocaName, collTypeMangled, loc)
      let collVarPtr = hirVar(collAllocaName, makePointer(collTypeMangled), loc)
      let collValue = ctx.lowerExpr(iterExpr)
      let collStore = hirStore(collVarPtr, collValue, loc)
      preStmts.add(collAlloca)
      preStmts.add(collStore)
      collPtr = HirNode(kind: hUnary, unaryOp: tkAmp,
                        unaryOperand: hirVar(collAllocaName, collTypeMangled, loc),
                        typ: makePointer(collTypeMangled), loc: loc)

    let iterAlloca = hirAlloca(iterVarName, iterType, loc)
    let iterVarPtr = hirVar(iterVarName, makePointer(iterType), loc)
    let iterInitCall = hirCall(iterFuncName, @[collPtr], iterType, loc)
    let iterStore = hirStore(iterVarPtr, iterInitCall, loc)

    preStmts.add(iterAlloca)
    preStmts.add(iterStore)

    # while condition: Iter_HasNext_T(&__iter)
    let iterAddr = HirNode(kind: hUnary, unaryOp: tkAmp, unaryOperand: hirVar(iterVarName, iterType, loc),
                           typ: makePointer(iterType), loc: loc)
    let condCall = hirCall(hasNextFuncName, @[iterAddr], makeBool(), loc)

    # loop body: alloca x; x = Iter_Next_T(&__iter); body
    let xAlloca = hirAlloca(varName, elemType, loc)
    let xVarPtr = hirVar(varName, makePointer(elemType), loc)
    let iterAddr2 = HirNode(kind: hUnary, unaryOp: tkAmp, unaryOperand: hirVar(iterVarName, iterType, loc),
                            typ: makePointer(iterType), loc: loc)
    let nextCall = hirCall(nextFuncName, @[iterAddr2], elemType, loc)
    let xStore = hirStore(xVarPtr, nextCall, loc)

    ctx.varTypeExprs[varName] = elemTypeExpr
    let loweredBody = ctx.lowerBlock(body)

    var bodyStmts: seq[HirNode] = @[]
    bodyStmts.add(xAlloca)
    bodyStmts.add(xStore)
    if loweredBody != nil:
      bodyStmts.add(loweredBody)
    let whileBody = hirBlock(bodyStmts, nil, makeVoid(), loc)

    let whileNode = HirNode(kind: hWhile, whileCond: condCall, whileBody: whileBody,
                            typ: makeVoid(), loc: loc)

    var blockStmts = preStmts
    blockStmts.add(whileNode)
    let forBlock = hirBlock(blockStmts, nil, makeVoid(), loc, isScope = true)
    return ctx.flushPending(forBlock)

  of skDoWhile:
    let body = ctx.lowerBlock(stmt.stmtDoWhileBody)
    let cond = ctx.lowerExpr(stmt.stmtDoWhileCond)
    let whileNode = HirNode(kind: hWhile, whileCond: cond, whileBody: body,
                           typ: makeVoid(), loc: loc)
    return ctx.flushPending(HirNode(kind: hBlock, blockStmts: @[body, whileNode],
                   blockExpr: nil, typ: makeVoid(), loc: loc))

  of skMatch:
    let subject = ctx.lowerExpr(stmt.stmtMatchSubject)
    # Statement match: binds + body lower inside lowerMatch (unique C names)
    return ctx.flushPending(lowerMatch(ctx, subject, stmt.stmtMatchArms, makeVoid(), loc))

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

  of skMacroRep:
    # Expanded before lowering
    return HirNode(kind: hLit, litToken: Token(kind: tkIntLiteral, text: "0", loc: loc),
                   typ: makeVoid(), loc: loc)

proc lowerBlock(ctx: var LowerCtx, blk: Block, asExpr = false): HirNode =
  ## asExpr=true: block is used as a value (`let x = { ... }`, match arm body).
  ## Last skExpr becomes the block result. Statement blocks (func body, if/while)
  ## keep asExpr=false so trailing void calls stay as statements.
  ##
  ## Auto-drop / defer scope: locals introduced in this block are dropped at
  ## block exit (LIFO). Nested if/while bodies get their own scope so branch-
  ## local drops do not leak into sibling branches. Early return still injects
  ## the full live stack (see skReturn).
  if blk == nil: return nil
  let deferBase = ctx.deferStmts.len
  var stmts: seq[HirNode] = @[]
  for s in blk.stmts:
    let hir = ctx.lowerStmt(s)
    if hir != nil:
      stmts.add(hir)
  var expr: HirNode = nil
  if asExpr and stmts.len > 0 and blk.stmts.len > 0 and blk.stmts[^1].kind == skExpr:
    let last = stmts[^1]
    if last.kind == hBlock and last.blockExpr != nil:
      # Nested yield block (match, block-expr) — lift result, keep side-effect stmts
      stmts[^1] = hirBlock(last.blockStmts, nil, makeVoid(), last.loc)
      expr = last.blockExpr
    elif last.kind in {hIf, hWhile, hLoop, hReturn, hBreak, hContinue, hAlloca, hStore, hAssign}:
      discard
    else:
      # hBinary, hCall, hLit, hVar, hLoad, … — value expression
      expr = last
      discard stmts.pop()
  elif stmts.len > 0 and stmts[^1].kind == hBlock and stmts[^1].blockExpr != nil:
    # Nested block expression (e.g., match) inside statement context — lift for
    # function last-expr return via blockExpr when present
    let last = stmts[^1]
    stmts[^1] = hirBlock(last.blockStmts, nil, makeVoid(), last.loc)
    expr = last.blockExpr
  # Scope exit: Drop locals introduced in this block (not outer ones).
  # Skip Drop for block result and any moved-out locals (field / let / return move).
  # If the last statement always returns, drops were already injected on that
  # path — re-emitting them here produces dead double-Drop after `return`.
  proc blockAlwaysReturns(n: HirNode): bool =
    if n == nil: return false
    if n.kind == hReturn: return true
    if n.kind == hBlock:
      if n.blockStmts.len == 0: return false
      return blockAlwaysReturns(n.blockStmts[^1])
    false

  var skipDrop = ""
  if expr != nil and expr.kind == hVar:
    skipDrop = expr.varName
    ctx.markMovedOutLocal(expr.varName)
  let lastAlwaysReturns = stmts.len > 0 and blockAlwaysReturns(stmts[^1])
  if ctx.deferStmts.len > deferBase and not lastAlwaysReturns:
    for i in countdown(ctx.deferStmts.len - 1, deferBase):
      ctx.emitDropOrPartial(stmts, ctx.deferStmts[i], skipDrop)
    ctx.deferStmts.setLen(deferBase)
  elif ctx.deferStmts.len > deferBase and lastAlwaysReturns:
    # Return path already owns these drops; pop so outer scopes don't re-run them
    # for the same locals when this block is nested. Outer live locals remain.
    ctx.deferStmts.setLen(deferBase)
  let typ = if expr != nil and expr.typ != nil: expr.typ else: makeVoid()
  return hirBlock(stmts, expr, typ, blk.loc, isScope = true)

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
  let oldPatternBound = ctx.patternBoundNames
  let oldPatternRenames = ctx.patternRenames
  ctx.currentFuncRetType = retType
  ctx.currentFuncDecl = decl
  ctx.varTypeExprs = initTable[string, TypeExpr]()  # Clear local vars for new function
  ctx.patternBoundNames = initHashSet[string]()
  ctx.patternRenames = initTable[string, string]()
  let oldDefers = ctx.deferStmts
  let oldMovedOut = ctx.movedOutLocals
  let oldPartialMoved = ctx.partialMovedFields
  let oldPtrAliases = ctx.ptrAliases
  ctx.deferStmts = @[]
  ctx.movedOutLocals = initHashSet[string]()
  ctx.partialMovedFields = initTable[string, HashSet[string]]()
  ctx.ptrAliases = initTable[string, string]()
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
        ctx.emitDropOrPartial(body.blockStmts, ctx.deferStmts[i], "")
  # Always restore — mono of generics (generateMethodInstance → lowerFunc) nests
  # inside an outer function. Restoring only when deferStmts.len > 0 wiped the
  # caller's Drop stack (PeekTagAndTake lost Array_Drop after Array_Len mono).
  ctx.deferStmts = oldDefers
  ctx.movedOutLocals = oldMovedOut
  ctx.partialMovedFields = oldPartialMoved
  ctx.ptrAliases = oldPtrAliases
  
  ctx.currentFuncDecl = oldFuncDecl
  ctx.currentFuncRetType = oldFuncRetType
  ctx.varTypeExprs = oldVarTypeExprs
  ctx.patternBoundNames = oldPatternBound
  ctx.patternRenames = oldPatternRenames

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
  let name = "__closure_" & $ctx.varCounter
  inc ctx.varCounter
  var f = HirFunc(name: name, isPublic: false)
  # Always take a leading env pointer (fat-func ABI); may be unused.
  f.params.add((name: "__env", typ: makePointer(makeVoid())))
  # Copy capture metadata
  if expr.captureCount > 0:
    f.captureNames = expr.captureNames
    for tk in expr.captureTypeKinds:
      f.captureTypes.add(Type(kind: TypeKind(tk)))
    f.envStructName = "__closure_env_" & $(ctx.varCounter - 1)
    f.envInstanceName = "__closure_env_instance_" & $(ctx.varCounter - 1)
  # User params
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
          # Full resolve — supports tuples, pointers, named types, etc.
          fields.add(if f != nil: ctx.resolveTypeExpr(f) else: makeUnknown())
        
        var namedFields: seq[tuple[name: string, typ: Type]] = @[]
        for nf in v.namedFields:
          let fType = if nf.ftype != nil: ctx.resolveTypeExpr(nf.ftype) else: makeUnknown()
          namedFields.add((nf.name, fType))
        
        variants.add(HirEnumVariant(name: v.name, fields: fields, namedFields: namedFields))
        # Multi-field / named-field variants get a named nested struct type
        # Enum_Variant_Payload (suffix avoids clash with tag constant Enum_Variant).
        if fields.len > 1:
          var nestedFields: seq[tuple[name: string, typ: Type]] = @[]
          for i, ft in fields:
            nestedFields.add((v.name & "_" & $i, ft))
          let nestedName = decl.declEnumName & "_" & v.name & "_Payload"
          structs.add((nestedName, nestedFields))
        elif namedFields.len > 0:
          var nestedFields: seq[tuple[name: string, typ: Type]] = @[]
          for nf in namedFields:
            nestedFields.add((nf.name, nf.typ))
          let nestedName = decl.declEnumName & "_" & v.name & "_Payload"
          structs.add((nestedName, nestedFields))
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

  var adapters: seq[tuple[name: string, typ: Type]] = @[]
  for name in ctx.funcAdapters:
    let t = if ctx.funcAdapterSigs.hasKey(name): ctx.funcAdapterSigs[name] else: makeFunc(@[makeInt()], makeInt())
    adapters.add((name, t))
  result = HirModule(funcs: funcs, externFuncs: externFuncs, structs: structs, enums: enums, consts: consts, interfaces: ifaceInfos, vtables: vtableInfos, funcAdapters: adapters, seenFatTypes: ctx.seenFatTypes)
