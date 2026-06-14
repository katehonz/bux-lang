# Fix `for ... in` Iterator Lowering — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the placeholder collection `for ... in` lowering in the bootstrap compiler with correct Array/Iter and Channel lowerings, fixing `_test_forin_stdlib`, `_test_forin_channel`, `_test_generic_trait`, `_test_import`, and `_test_mono`.

**Architecture:** Determine the concrete element type in sema and register the loop variable with it; in HIR lowering emit explicit alloca/store/while nodes that call monomorphized iterator helpers (`Array_Iter_T`, `Iter_HasNext_T`, `Iter_Next_T`) for arrays and `Channel_Recv_Ok_T` for channels. Also fix generic struct field access so direct field mutations on `Array<int>` work.

**Tech Stack:** Nim (bootstrap compiler), Bux integration tests.

---

## Task 1: Export and Fix `typeToTypeExpr`

**Files:**
- Modify: `bootstrap/sema.nim:140-157`

- [ ] **Step 1.1: Export the helper and preserve type args for named types**

Find:

```nim
proc typeToTypeExpr(t: Type): TypeExpr =
```

Change the signature to `proc typeToTypeExpr*(t: Type): TypeExpr =` and update the `tkNamed` branch:

```nim
  of tkNamed:
    var args: seq[TypeExpr] = @[]
    for a in t.inner:
      args.add(typeToTypeExpr(a))
    return TypeExpr(kind: tekNamed, typeName: t.name, typeArgs: args)
```

This lets HIR lowering round-trip a resolved concrete `Type` back to a `TypeExpr` that can be mangled into the correct struct instance name (e.g. `Array<int>` → `Array_int`).

---

## Task 2: Derive Loop-Variable Type in Sema

**Files:**
- Modify: `bootstrap/sema.nim:1503-1515`

- [ ] **Step 2.1: Set the loop variable type from the collection's element type**

Find the `of skFor:` branch and update it so `iterTyp` is the collection element type:

```nim
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
```

---

## Task 3: Substitute Generic Struct Type Parameters on Field Access

**Files:**
- Modify: `bootstrap/sema.nim:1269-1273` and `bootstrap/sema.nim:180-215`

- [ ] **Step 3.1: Build substitution map in `ekField` for struct fields**

In the `dkStruct` branch of `ekField`, build a substitution map from the object's concrete type arguments before resolving the field type:

```nim
          if sym.decl.kind == dkStruct:
            var subst = initTable[string, Type]()
            for i, tp in sym.decl.declStructTypeParams:
              if i < objType.inner.len:
                subst[tp.name] = objType.inner[i]
            for f in sym.decl.declStructFields:
              if f.name == expr.exprFieldName:
                return sema.substituteTypeInType(sema.resolveType(f.ftype), subst)
            sema.emitError(expr.loc, &"struct '{objType.name}' has no field '{expr.exprFieldName}'")
```

- [ ] **Step 3.2: Make `substituteTypeInType` handle named type-parameter names**

In `substituteTypeInType`, add a lookup for `tkNamed` names that are type-parameter names:

```nim
  of tkNamed:
    if subst.hasKey(t.name):
      return subst[t.name]
    if t.inner.len > 0:
      var args: seq[Type] = @[]
      for a in t.inner:
        args.add(sema.substituteTypeInType(a, subst))
      return Type(kind: tkNamed, name: t.name, inner: args)
    return t
```

---

## Task 4: Add `getCollectionElementTypeExpr` Helper in `hir_lower.nim`

**Files:**
- Modify: `bootstrap/hir_lower.nim` (after `resolveExprType` definition)

- [ ] **Step 4.1: Add the helper**

```nim
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
  else:
    discard
  let t = ctx.resolveExprType(expr)
  if t.kind == tkNamed and t.inner.len > 0:
    return typeToTypeExpr(t.inner[0])
  if t.isPointer and t.inner.len > 0 and t.inner[0].kind == tkNamed and t.inner[0].inner.len > 0:
    return typeToTypeExpr(t.inner[0].inner[0])
  return TypeExpr(kind: tekNamed, typeName: "unknown")
```

---

## Task 5: Implement Collection `for ... in` Lowering

**Files:**
- Modify: `bootstrap/hir_lower.nim` (replace the placeholder at lines 1339-1342)

- [ ] **Step 5.1: Replace the placeholder collection lowering**

Find:

```nim
    # Generic iterator for loop (simplified - just infinite loop for now)
    let loweredIter = ctx.lowerExpr(iterExpr)
    let loweredBody = ctx.lowerBlock(body)
    return ctx.flushPending(HirNode(kind: hLoop, loopBody: loweredBody, typ: makeVoid(), loc: loc))
```

Replace with:

```nim
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
                           typ: makePointer(collTypeMangled), loc: loc)
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
      let collVar = hirVar(iterExpr.exprIdent, collTypeMangled, loc)
      collPtr = HirNode(kind: hUnary, unaryOp: tkAmp, unaryOperand: collVar,
                        typ: makePointer(collTypeMangled), loc: loc)
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
```

---

## Task 6: Build and Verify

**Files:**
- Test: `_test_forin_stdlib`, `_test_forin_channel`, `_test_generic_trait`, `_test_import`, `_test_mono`

- [ ] **Step 6.1: Rebuild the bootstrap compiler**

Run:

```bash
cd /home/ziko/z-git/bux/bux
make build
```

Expected: build succeeds.

- [ ] **Step 6.2: Run the five target integration tests**

Run:

```bash
cd /home/ziko/z-git/bux/bux/_test_forin_stdlib && /home/ziko/z-git/bux/bux/buxc run
cd /home/ziko/z-git/bux/bux/_test_forin_channel && /home/ziko/z-git/bux/bux/buxc run
cd /home/ziko/z-git/bux/bux/_test_generic_trait && /home/ziko/z-git/bux/bux/buxc run
cd /home/ziko/z-git/bux/bux/_test_import && /home/ziko/z-git/bux/bux/buxc run
cd /home/ziko/z-git/bux/bux/_test_mono && /home/ziko/z-git/bux/bux/buxc run
```

Expected: all compile and run; programs that return the sum (`_test_generic_trait`, `_test_import`, `_test_mono`) exit with code 60, which is their expected return value.

- [ ] **Step 6.3: Run `make test`**

```bash
cd /home/ziko/z-git/bux/bux
make test
```

Expected: no new failures.

- [ ] **Step 6.4: Run `make selfhost-loop`**

```bash
cd /home/ziko/z-git/bux/bux
make selfhost-loop
```

Expected: C output and stripped ELF binary remain identical.

---

## Task 7: Commit

- [ ] **Step 7.1: Commit the changes**

```bash
cd /home/ziko/z-git/bux/bux
git add bootstrap/sema.nim bootstrap/hir_lower.nim
git commit -m "fix(bootstrap): implement collection for-in lowering

- Export typeToTypeExpr from sema and preserve generic type args
- Derive loop variable type from collection element type in sema
- Substitute generic struct type params on field access
- Add getCollectionElementTypeExpr helper in hir_lower
- Replace placeholder collection for-in lowering
- Add Array/Iter lowering: Array_Iter_T / Iter_HasNext_T / Iter_Next_T
- Add Channel lowering: Channel_Recv_Ok_T loop
- Register loop variable in varTypeExprs before body lowering

Fixes _test_forin_stdlib, _test_forin_channel, _test_generic_trait, _test_import, _test_mono"
```

---

## Spec Coverage Check

| Spec Requirement | Plan Task |
|---|---|
| Export and fix `typeToTypeExpr` | Task 1 |
| Derive loop variable type in sema | Task 2 |
| Substitute generic struct type params on field access | Task 3 |
| Add `getCollectionElementTypeExpr` helper | Task 4 |
| Array/Iter collection lowering | Task 5 |
| Channel collection lowering | Task 5 |
| Loop variable declaration and scope registration | Task 5 |
| Target tests pass | Task 6 |
| No regressions | Task 6 |

## Placeholder Scan

- No TBD/TODO/fill-in-later steps.
- Every code block contains the exact code to insert.
- Every command contains the exact path and expected outcome.
