# Fix Generic Operator `[]` in Bootstrap Sema — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `_test_drop_trait` and `_test_checked_index` pass by teaching bootstrap sema to preserve generic type arguments and substitute them when resolving operator `[]` on generic types like `Array<T>`.

**Architecture:** Add a `Type`-to-`Type` substitution helper, update `resolveType` to keep type args on `tkNamed`, fix explicit generic-call return-type resolution, and update `ekIndex` to look up `operator_index_get` through pointers and substitute method type parameters from the receiver's concrete type arguments.

**Tech Stack:** Nim (bootstrap compiler), Bux integration tests.

---

## Background

`Array_operator_index_get<T>` is auto-registered as a method for type `Array`. Its `MethodInfo.retType` is the type parameter `T` (`tkTypeParam`). When the bootstrap compiler sees `arr[0]` where `arr: Array<int>`, it currently:

1. Resolves `Array<int>` to a plain `tkNamed("Array")` (type args are dropped).
2. Finds `operator_index_get` in the method table.
3. Returns the unsubstituted `T`.
4. `T` is treated as a numeric type and arithmetic defaults to `float32`, producing the `_test_drop_trait` error `expected int, got float32`.

For `*Array<int>`, the pointer branch in `ekIndex` returns the pointee `Array<int>` instead of the element type, producing the `_test_checked_index` error `cannot assign int to Array`.

---

## Task 1: Add Type-to-Type Substitution Helper

**Files:**
- Modify: `bootstrap/sema.nim` (after the existing helper procs, around line 135)

- [ ] **Step 1.1: Add `substituteTypeInType`**

```nim
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
    if t.inner.len > 0:
      var args: seq[Type] = @[]
      for a in t.inner:
        args.add(sema.substituteTypeInType(a, subst))
      return Type(kind: tkNamed, name: t.name, inner: args)
    return t
  else:
    return t
```

---

## Task 2: Preserve Type Arguments in `resolveType`

**Files:**
- Modify: `bootstrap/sema.nim:261-265` (`resolveType` `tekNamed` branch)

- [ ] **Step 2.1: Replace the `else` branch in `resolveType` for `tekNamed`**

Find:

```nim
    else:
      if sema.typeTable.hasKey(name):
        return sema.typeTable[name]
      return makeNamed(name)
```

Replace with:

```nim
    else:
      if te.typeArgs.len > 0:
        var args: seq[Type] = @[]
        for arg in te.typeArgs:
          args.add(sema.resolveType(arg))
        return Type(kind: tkNamed, name: name, inner: args)
      if sema.typeTable.hasKey(name):
        return sema.typeTable[name]
      return makeNamed(name)
```

This makes `Array<int>` resolve to `tkNamed("Array", inner: [tkInt])`.

---

## Task 3: Fix Explicit Generic Call Return-Type Resolution

**Files:**
- Modify: `bootstrap/sema.nim:979-993` (`ekCall` `ekGenericCall` callee branch)

- [ ] **Step 3.1: Replace the generic-call return-type substitution logic**

Find:

```nim
      if sym.typ != nil and sym.typ.kind == tkFunc:
        # Get the return type and substitute type parameters
        let retType = sym.typ.inner[^1]
        if retType.kind == tkNamed:
          # Check if this is a type parameter
          let sym2 = sema.globalScope.lookup(expr.exprCallCallee.exprGenericCallee)
          if sym2 != nil and sym2.decl != nil and sym2.decl.kind == dkFunc:
            let typeParams = sym2.decl.declFuncTypeParams
            for i, tp in typeParams:
              if retType.name == tp.name and i < expr.exprCallCallee.exprGenericTypeArgs.len:
                # Substitute with concrete type
                let concreteType = expr.exprCallCallee.exprGenericTypeArgs[i]
                if concreteType.kind == tekNamed:
                  return sema.resolveType(concreteType)
        return retType
```

Replace with:

```nim
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
```

This makes `Array_New<int>()` resolve to `tkNamed("Array", inner: [tkInt])`, so assignments like `let arr: Array<int> = Array_New<int>(8)` remain assignable.

---

## Task 4: Update `ekIndex` to Substitute Method Type Parameters

**Files:**
- Modify: `bootstrap/sema.nim:1155-1178` (`ekIndex` branch)

- [ ] **Step 4.1: Replace the `ekIndex` implementation**

Find the entire `of ekIndex:` block (lines 1155-1178):

```nim
  of ekIndex:
    let obj = sema.checkExpr(expr.exprIndexObj, scope)
    let idx = sema.checkExpr(expr.exprIndexIdx, scope)
    if not idx.isInteger:
      sema.emitError(expr.loc, "index must be integer")
    if obj.isSlice:
      if sema.checkedFunc:
        expr.exprIndexBoundsCheck = true
      return obj.inner[0]
    elif obj.isPointer:
      return obj.inner[0]
    elif obj.kind == tkStr:
      return makeChar8()
    elif obj.kind == tkNamed and sema.methodTable.hasKey(obj.name):
      for minfo in sema.methodTable[obj.name]:
        if minfo.name == "operator_index_get" and minfo.params.len == 2:
          let idxType = minfo.params[1]
          if idx.isAssignableTo(idxType) or idxType.isAssignableTo(idx) or idx.kind == tkUnknown:
            return minfo.retType
      sema.emitError(expr.loc, "cannot index non-slice/non-pointer type")
      return makeUnknown()
    else:
      sema.emitError(expr.loc, "cannot index non-slice/non-pointer type")
      return makeUnknown()
```

Replace with:

```nim
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
```

This makes `arr[0]` on `Array<int>` return `int`, and `arr[0]` on `*Array<int>` also return `int`.

---

## Task 5: Skip Strict Arg Check for Generic Function Calls

**Files:**
- Modify: `bootstrap/sema.nim:1124-1133` (regular function call arg checking)

- [ ] **Step 5.1: Wrap non-generic arg checking**

Find:

```nim
    if calleeDecl != nil and calleeDecl.kind == dkFunc and calleeDecl.declFuncTypeParams.len > 0:
      discard  # will be handled later
    if calleeType.kind == tkFunc:
      let expectedParams = calleeType.inner[0..^2]
      if argTypes.len != expectedParams.len:
        sema.emitError(expr.loc, &"expected {expectedParams.len} arguments, got {argTypes.len}")
      else:
        for i in 0 ..< argTypes.len:
          if not argTypes[i].isAssignableTo(expectedParams[i]) and not (argTypes[i].kind in {TypeKind.tkUnknown, TypeKind.tkNamed, TypeKind.tkTypeParam}):
            sema.emitError(expr.loc, &"argument {i+1}: expected {expectedParams[i].toString}, got {argTypes[i].toString}")
```

Replace with:

```nim
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
```

This prevents spurious type mismatches when passing `&mut Array<int>` to a generic function expecting `*Array<T>`.

---

## Task 6: Fix Generic Struct Monomorphization in HIR `substituteType`

**Files:**
- Modify: `bootstrap/hir_lower.nim:168-176`

- [ ] **Step 6.1: Build a local substitution map when generating struct instances**

Find:

```nim
        if not hasUnresolved:
          var fields: seq[tuple[name: string, typ: Type]] = @[]
          var concreteArgs: seq[Type] = @[]
          for f in genericDecl.declStructFields:
            let resolvedType = substituteType(ctx, f.ftype, subst)
            fields.add((f.name, resolvedType))
          for arg in te.typeArgs:
            concreteArgs.add(substituteType(ctx, arg, subst))
          ctx.extraStructs.add((mangledName, fields))
          ctx.generatedStructInsts[mangledName] = true
          ctx.structInstMap[mangledName] = (te.typeName, concreteArgs)
```

Replace with:

```nim
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
```

This ensures field types like `*T` are resolved to `*int` when generating `Array_int`, even when the struct instance is first requested from a context with no active substitution map.

---

## Task 7: Fix Parameter Visibility in HIR `lowerFunc`

**Files:**
- Modify: `bootstrap/hir_lower.nim:1432-1451`

- [ ] **Step 7.1: Move parameter `varTypeExprs` registration after clearing the table**

Find:

```nim
  var params: seq[tuple[name: string, typ: Type]] = @[]
  for p in funcParams:
    var pType = makeUnknown()
    if p.ptype != nil:
      pType = substituteType(ctx, p.ptype, ctx.typeSubst)
    params.add((p.name, pType))
    if p.ptype != nil:
      ctx.varTypeExprs[p.name] = p.ptype

  var retType = makeVoid()
  if funcReturnType != nil:
    retType = substituteType(ctx, funcReturnType, ctx.typeSubst)

  let oldFuncDecl = ctx.currentFuncDecl
  let oldFuncRetType = ctx.currentFuncRetType
  let oldVarTypeExprs = ctx.varTypeExprs
  ctx.currentFuncRetType = retType
  ctx.currentFuncDecl = decl
  ctx.varTypeExprs = initTable[string, TypeExpr]()  # Clear local vars for new function
  var body = if funcBody != nil: ctx.lowerBlock(funcBody) else: nil
```

Replace with:

```nim
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
```

This makes parameter types visible when lowering `operator_index_get` calls on pointer parameters like `arr: *Array<int>`.

---

## Task 8: Build and Verify

**Files:**
- Test: `_test_drop_trait`, `_test_checked_index`, full suite

- [ ] **Step 8.1: Rebuild the bootstrap compiler**

Run:

```bash
cd /home/ziko/z-git/bux/bux
make build
```

Expected: build succeeds.

- [ ] **Step 8.2: Run the two target integration tests**

Run:

```bash
cd /home/ziko/z-git/bux/bux/_test_drop_trait
/home/ziko/z-git/bux/bux/buxc run

cd /home/ziko/z-git/bux/bux/_test_checked_index
/home/ziko/z-git/bux/bux/buxc run
```

Expected: both exit 0 and print the expected output.

- [ ] **Step 8.3: Run bootstrap unit tests and integration tests**

Run:

```bash
cd /home/ziko/z-git/bux/bux
make test
```

Expected: no new failures.

- [ ] **Step 8.4: Run selfhost loop**

Run:

```bash
cd /home/ziko/z-git/bux/bux
make selfhost-loop
```

Expected: C output and stripped ELF binary remain identical.

- [ ] **Step 8.5: Optional cross-check of all `_test_*` packages**

Run:

```bash
cd /home/ziko/z-git/bux/bux
for d in _test_*; do
  echo "=== $d ==="
  (cd "$d" && /home/ziko/z-git/bux/bux/buxc run) || true
done
```

Expected: no new failures compared to the baseline.

---

## Task 9: Commit

- [ ] **Step 9.1: Commit the changes**

```bash
cd /home/ziko/z-git/bux/bux
git add bootstrap/sema.nim bootstrap/hir_lower.nim
git commit -m "fix(bootstrap): substitute generic type args in operator [] resolution

- Preserve type args on tkNamed in resolveType
- Resolve explicit generic call return types with concrete substitutions
- Substitute method type params when looking up operator_index_get
- Skip strict arg checks for generic function calls (deferred to inference)
- Fix generic struct monomorphization when no caller substitution map exists
- Fix parameter varTypeExprs ordering so pointer params are visible in bodies
- Fixes _test_drop_trait and _test_checked_index"
```

---

## Spec Coverage Check

| Spec Requirement | Plan Task |
|---|---|
| Reproduce failures | Task 8.2 |
| Trace operator `[]` resolution | Tasks 2-4 |
| Minimal bootstrap-only fix | Tasks 2-7 (no selfhost changes) |
| `_test_drop_trait` passes | Task 8.2 |
| `_test_checked_index` passes | Task 8.2 |
| No regressions in `make test` / `make selfhost-loop` | Tasks 8.3-8.5 |

## Placeholder Scan

- No TBD/TODO/fill-in-later steps.
- Every code block contains the exact code to insert.
- Every command contains the exact path and expected outcome.
