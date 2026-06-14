## LIR Lowering — HIR → LIR
## Converts the high-level HIR tree into flat, linear LIR instructions.
## Each HIR node kind lowers to 1-20 LIR instructions.

import std/[strutils, strformat, tables, sequtils]
import types, token, hir, lir

## Convert LirValue to C expression string (no % prefix)
proc lirValToC(v: LirValue): string =
  case v.kind
  of lvkTemp: v.strVal
  of lvkVar: v.strVal
  of lvkInt: $v.intVal
  of lvkFloat: $v.floatVal
  of lvkString: v.strVal
  of lvkLabel: v.strVal
  of lvkGlobal: v.strVal
  of lvkField: v.strVal
  of lvkVoid: ""
  of lvkType: v.strVal

type
  LowerToLirCtx* = object
    builder*: LirBuilder
    ## Map HIR var names -> C type names (for alloca/load/store type info)
    varTypes*: Table[string, string]
    ## Map HIR var names -> LirValue kind (lvkVar or lvkTemp)
    varLirValues*: Table[string, LirValue]
    ## C types for function params / returns
    funcRetType*: string
    ## Current source location for debug
    currentFile*: string
    ## Loop end labels for break/continue
    loopEndLabels*: seq[string]
    loopStartLabels*: seq[string]

proc initLowerToLirCtx*(): LowerToLirCtx =
  result = LowerToLirCtx(
    builder: initLirBuilder(),
    varTypes: initTable[string, string](),
    varLirValues: initTable[string, LirValue](),
    loopEndLabels: @[],
    loopStartLabels: @[],
  )

# ── Helpers ──

proc cEscape(s: string): string =
  result = ""
  for c in s:
    case c
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    of '\0': result.add("\\0")
    else: result.add(c)

proc typeToCStr(typ: Type): string =
  ## Convert a Bux Type to a C type string.
  if typ == nil: return "int"
  case typ.kind
  of tkVoid: return "void"
  of tkBool, tkBool8, tkBool16, tkBool32: return "bool"
  of tkChar8: return "char"
  of tkChar16: return "char16_t"
  of tkChar32: return "char32_t"
  of tkStr: return "const char*"
  of tkInt8: return "int8_t"
  of tkInt16: return "int16_t"
  of tkInt32: return "int32_t"
  of tkInt64: return "int64_t"
  of tkInt: return "int"
  of tkUInt8: return "uint8_t"
  of tkUInt16: return "uint16_t"
  of tkUInt32: return "uint32_t"
  of tkUInt64: return "uint64_t"
  of tkUInt: return "unsigned int"
  of tkFloat32: return "float"
  of tkFloat64: return "double"
  of tkPointer, tkRef, tkMutRef:
    if typ.inner.len > 0:
      return typeToCStr(typ.inner[0]) & "*"
    return "void*"
  of tkDynRef:
    return typ.name & "_FatPtr"
  of tkSlice:
    let elem = if typ.inner.len > 0: typeToCStr(typ.inner[0]) else: "void"
    return "Slice_" & elem.replace(" ", "_").replace("*", "Ptr")
  of tkNamed:
    case typ.name
    of "String", "str": return "const char*"
    of "int": return "int"
    of "int8": return "int8_t"
    of "int16": return "int16_t"
    of "int32": return "int32_t"
    of "int64": return "int64_t"
    of "uint": return "unsigned int"
    of "uint8": return "uint8_t"
    of "uint16": return "uint16_t"
    of "uint32": return "uint32_t"
    of "uint64": return "uint64_t"
    of "float32": return "float"
    of "float64": return "double"
    of "bool": return "bool"
    else: return typ.name
  of tkFunc:
    if typ.inner.len == 0: return "void (*)(void)"
    let params = typ.inner[0..^2].mapIt(typeToCStr(it)).join(", ")
    let ret = typeToCStr(typ.inner[^1])
    return ret & " (*)(" & params & ")"
  else: return "int"

proc hirTypeToC(ctx: var LowerToLirCtx, node: HirNode): string =
  if node == nil: return "int"
  result = typeToCStr(node.typ)

proc binOpToLir(op: TokenKind): LirKind =
  case op
  of tkPlus: lirAdd
  of tkMinus: lirSub
  of tkStar: lirMul
  of tkSlash: lirDiv
  of tkPercent: lirMod
  of tkAmp: lirAnd
  of tkPipe: lirOr
  of tkCaret: lirXor
  of tkShl: lirShl
  of tkShr: lirShr
  else: lirAdd

proc cmpOpToLir(op: TokenKind): LirKind =
  case op
  of tkEq: lirCmpEq
  of tkNe: lirCmpNe
  of tkLt: lirCmpLt
  of tkLe: lirCmpLe
  of tkGt: lirCmpGt
  of tkGe: lirCmpGe
  else: lirCmpEq

# ── Forward declarations ──
proc lowerExpr(ctx: var LowerToLirCtx, node: HirNode): LirValue
proc lowerStmt(ctx: var LowerToLirCtx, node: HirNode)

# ── Lowering: Expressions → LirValue ──

proc lowerExpr(ctx: var LowerToLirCtx, node: HirNode): LirValue =
  if node == nil: return lirInt(0)
  template b: var LirBuilder = ctx.builder

  case node.kind

  # ── Literals ──
  of hLit:
    case node.litToken.kind
    of tkBoolLiteral:
      if node.litToken.text == "true": return lirInt(1)
      else: return lirInt(0)
    of tkStringLiteral:
      var text = node.litToken.text
      # Handle backtick strings
      if text.len >= 2 and text[0] == '`' and text[text.len-1] == '`':
        text = "\"" & cEscape(text[1 ..< text.len-1]) & "\""
      elif text.len >= 2 and text[0] == '"' and text[text.len-1] == '"':
        # Strip c8" c16" c32" prefixes
        if text.startsWith("c32\""):
          text = "\"" & cEscape(text[4 ..< text.len-1]) & "\""
        elif text.startsWith("c16\""):
          text = "\"" & cEscape(text[4 ..< text.len-1]) & "\""
        elif text.startsWith("c8\""):
          text = "\"" & cEscape(text[3 ..< text.len-1]) & "\""
        else:
          text = "\"" & cEscape(text[1 ..< text.len-1]) & "\""
      elif text.len >= 2 and text[0] == '"':
        text = "\"" & cEscape(text[1 ..< text.len]) & "\""
      else:
        text = "\"" & cEscape(text) & "\""
      return lirStr(text)
    of tkNull:
      return lirInt(0)
    else:
      # Integer/float literal
      return lirVar(node.litToken.text)

  # ── Variable reference ──
  of hVar:
    let name = node.varName
    if ctx.varLirValues.hasKey(name):
      return ctx.varLirValues[name]
    return lirVar(name)

  # ── Alloca (address of local) ──
  of hAlloca:
    let cType = typeToCStr(node.allocaType)
    let name = node.allocaName
    if not ctx.varLirValues.hasKey(name):
      ctx.varTypes[name] = cType
      ctx.varLirValues[name] = lirVar(name)
      b.emitAlloca(name, cType)
    return lirVar("&" & name)

  # ── Self ──
  of hSelf:
    return lirVar("self")

  # ── Unary ──
  of hUnary:
    let operand = lowerExpr(ctx, node.unaryOperand)
    case node.unaryOp
    of tkMinus:
      let t = b.freshTemp()
      b.emitUnary(lirNeg, t, operand)
      return t
    of tkBang:
      let t = b.freshTemp()
      b.emitUnary(lirNot, t, operand)
      return t
    of tkTilde:
      let t = b.freshTemp()
      b.emitUnary(lirBNot, t, operand)
      return t
    of tkStar:
      # Dereference: *ptr → load
      let t = b.freshTemp()
      b.emitLoad(t, operand)
      return t
    of tkAmp:
      # Address of: &expr
      # Optimize: &struct.field → fieldPtr (no temp copy)
      #           &array[i]     → indexPtr (no temp copy)
      if node.unaryOperand.kind == hLoad and node.unaryOperand.loadPtr != nil:
        let ptrNode = node.unaryOperand.loadPtr
        case ptrNode.kind
        of hFieldPtr:
          let base = lowerExpr(ctx, ptrNode.fieldPtrBase)
          let baseTyp = ptrNode.fieldPtrBase.typ
          let isPtr = baseTyp != nil and baseTyp.kind in {tkPointer, tkRef, tkMutRef}
          let t = b.freshTemp()
          b.emitAlloca(t.strVal, "void*")
          if isPtr:
            b.emitRawC(&"{t.strVal} = &({lirValToC(base)}->{ptrNode.fieldName});")
          else:
            b.emitRawC(&"{t.strVal} = &({lirValToC(base)}.{ptrNode.fieldName});")
          return t
        of hArrowField:
          let base = lowerExpr(ctx, ptrNode.arrowFieldBase)
          let t = b.freshTemp()
          b.emitAlloca(t.strVal, "void*")
          b.emitRawC(&"{t.strVal} = &({lirValToC(base)}->{ptrNode.arrowFieldName});")
          return t
        of hIndexPtr:
          let base = lowerExpr(ctx, ptrNode.indexPtrBase)
          let idx = lowerExpr(ctx, ptrNode.indexPtrIndex)
          let t = b.freshTemp()
          b.emitAlloca(t.strVal, "void*")
          b.emitRawC(&"{t.strVal} = &({lirValToC(base)}[{lirValToC(idx)}]);")
          return t
        else: discard
      let t = b.freshTemp()
      b.emitAddrOf(t, operand)
      return t
    else:
      return operand

  # ── Binary ──
  of hBinary:
    let left = lowerExpr(ctx, node.binaryLeft)
    let right = lowerExpr(ctx, node.binaryRight)
    case node.binaryOp
    of tkEq, tkNe, tkLt, tkLe, tkGt, tkGe:
      let t = b.freshTemp()
      b.emitCmp(cmpOpToLir(node.binaryOp), t, left, right)
      return t
    of tkAmpAmp, tkPipePipe:
      # Logical and/or: lowered to branches for short-circuit evaluation
      let t = b.freshTemp()
      b.emitAlloca(t.strVal, "int")
      let falseLbl = b.freshLabel("and_false")
      let trueLbl = b.freshLabel("and_true")
      let endLbl = b.freshLabel("and_end")
      if node.binaryOp == tkAmpAmp:
        # left && right: if !left goto false; if !right goto false; t=1; goto end; false: t=0; end:
        b.emitJz(falseLbl, left)
        b.emitJz(falseLbl, right)
        b.emitMov(t, lirInt(1))
        b.emitJmp(endLbl)
        b.emitLabel(falseLbl)
        b.emitMov(t, lirInt(0))
        b.emitLabel(endLbl)
      else:
        # left || right: if left goto true; if right goto true; t=0; goto end; true: t=1; end:
        b.emitJnz(trueLbl, left)
        b.emitJnz(trueLbl, right)
        b.emitMov(t, lirInt(0))
        b.emitJmp(endLbl)
        b.emitLabel(trueLbl)
        b.emitMov(t, lirInt(1))
        b.emitLabel(endLbl)
      return t
    else:
      let t = b.freshTemp()
      b.emitBinOp(binOpToLir(node.binaryOp), t, left, right)
      return t

  # ── Call ──
  of hCall:
    var args: seq[LirValue] = @[]
    for arg in node.callArgs:
      args.add(lowerExpr(ctx, arg))
    let callee = node.callCallee
    let t = b.freshTemp()
    let cType = hirTypeToC(ctx, node)
    if cType != "void" and cType != "":
      b.emitAlloca(t.strVal, cType)
    b.emitCall(t, callee, args)
    return t

  # ── CallIndirect ──
  of hCallIndirect:
    let callee = lowerExpr(ctx, node.callIndirectCallee)
    var args: seq[LirValue] = @[callee]
    for arg in node.callIndirectArgs:
      args.add(lowerExpr(ctx, arg))
    let t = b.freshTemp()
    let cType = hirTypeToC(ctx, node)
    if cType != "void" and cType != "":
      b.emitAlloca(t.strVal, cType)
    # Use lirCallIndirect: dst = (*fn_ptr)(args...)
    b.emit(LirInstr(kind: lirCallIndirect, dst: t, src: callee, extra: args[1..^1]))
    return t

  # ── Field pointer expressions (return address) ──
  # These return a typed pointer (void* for now, cast before deref)
  of hFieldPtr:
    let base = lowerExpr(ctx, node.fieldPtrBase)
    let baseTyp = node.fieldPtrBase.typ
    let isPtr = baseTyp != nil and baseTyp.kind in {tkPointer, tkRef, tkMutRef}
    let t = b.freshTemp()
    b.emitAlloca(t.strVal, "void*")
    if isPtr:
      b.emitRawC(&"{t.strVal} = (void*)&({lirValToC(base)}->{node.fieldName});")
    else:
      b.emitRawC(&"{t.strVal} = (void*)&({lirValToC(base)}.{node.fieldName});")
    return t

  of hFieldAccess:
    let base = lowerExpr(ctx, node.fieldAccessBase)
    let cType = hirTypeToC(ctx, node)
    let t = b.freshTemp()
    b.emitAlloca(t.strVal, cType)
    b.emitRawC(&"{t.strVal} = {lirValToC(base)}.{node.fieldAccessName};")
    return t

  of hArrowField:
    let base = lowerExpr(ctx, node.arrowFieldBase)
    let t = b.freshTemp()
    b.emitAlloca(t.strVal, "void*")
    b.emitRawC(&"{t.strVal} = (void*)&({lirValToC(base)}->{node.arrowFieldName});")
    return t

  of hIndexPtr:
    let base = lowerExpr(ctx, node.indexPtrBase)
    let idx = lowerExpr(ctx, node.indexPtrIndex)
    let t = b.freshTemp()
    b.emitAlloca(t.strVal, "void*")
    b.emitRawC(&"{t.strVal} = (void*)&({lirValToC(base)}[{lirValToC(idx)}]);")
    return t

  # ── Load ──
  of hLoad:
    # Load through a pointer or field access
    # Optimize common patterns: load(field_ptr) → direct field access
    if node.loadPtr != nil and node.loadPtr.kind == hArrowField:
      let base = lowerExpr(ctx, node.loadPtr.arrowFieldBase)
      let cType = hirTypeToC(ctx, node)
      let t = b.freshTemp()
      b.emitAlloca(t.strVal, cType)
      b.emitRawC(&"{t.strVal} = {lirValToC(base)}->{node.loadPtr.arrowFieldName};")
      return t
    if node.loadPtr != nil and node.loadPtr.kind == hFieldPtr:
      let base = lowerExpr(ctx, node.loadPtr.fieldPtrBase)
      let baseTyp = node.loadPtr.fieldPtrBase.typ
      let isPtr = baseTyp != nil and baseTyp.kind in {tkPointer, tkRef, tkMutRef}
      let cType = hirTypeToC(ctx, node)
      let t = b.freshTemp()
      b.emitAlloca(t.strVal, cType)
      if isPtr:
        b.emitRawC(&"{t.strVal} = {lirValToC(base)}->{node.loadPtr.fieldName};")
      else:
        b.emitRawC(&"{t.strVal} = {lirValToC(base)}.{node.loadPtr.fieldName};")
      return t
    if node.loadPtr != nil and node.loadPtr.kind == hIndexPtr:
      let base = lowerExpr(ctx, node.loadPtr.indexPtrBase)
      let idx = lowerExpr(ctx, node.loadPtr.indexPtrIndex)
      let cType = hirTypeToC(ctx, node)
      let t = b.freshTemp()
      b.emitAlloca(t.strVal, cType)
      b.emitRawC(&"{t.strVal} = {lirValToC(base)}[{lirValToC(idx)}];")
      return t
    # Generic: dereference pointer
    let ptrVal = lowerExpr(ctx, node.loadPtr)
    let cType = hirTypeToC(ctx, node)
    let t = b.freshTemp()
    b.emitAlloca(t.strVal, cType)
    b.emitRawC(&"{t.strVal} = *({cType}*){lirValToC(ptrVal)};")
    return t

  # ── Slice Index ──
  of hSliceIndex:
    let base = lowerExpr(ctx, node.sliceIndexBase)
    let idx = lowerExpr(ctx, node.sliceIndexIndex)
    let t = b.freshTemp()
    # Emit: base.data[idx]  (with optional bounds check)
    if node.sliceIndexBoundsCheck:
      b.emitRawC(&"bux_bounds_check((size_t)({lirValToC(idx)}), ({lirValToC(base)}).len)")
    b.emit(LirInstr(kind: lirLoad, dst: t, src: base, src2: idx))
    return t

  # ── Cast ──
  of hCast:
    let operand = lowerExpr(ctx, node.castOperand)
    let targetCType = typeToCStr(node.castType)
    let t = b.freshTemp()
    b.emitCast(t, operand, targetCType)
    return t

  # ── SizeOf ──
  of hSizeOf:
    let ctype = typeToCStr(node.sizeOfType)
    b.emit(LirInstr(kind: lirRawC, src: lirStr(&"/* sizeof({ctype}) */")))
    return lirVar(&"sizeof({ctype})")

  # ── Spawn ──
  of hSpawn:
    if node.spawnAsync:
      let t = b.freshTemp()
      b.emitAlloca(t.strVal, "void*")
      b.emitCall(t, "bux_async_spawn", @[lirGlobal(node.spawnCallee)])
      return t
    else:
      var args: seq[LirValue] = @[]
      if node.spawnArgs.len > 0:
        args.add(lowerExpr(ctx, node.spawnArgs[0]))
      else:
        args.add(lirInt(0))
      let t = b.freshTemp()
      b.emitAlloca(t.strVal, "void*")
      b.emitCall(t, "bux_task_spawn", @[lirGlobal(node.spawnCallee)] & args)
      return t

  # ── DynRef (trait object) ──
  of hDynRef:
    let data = lowerExpr(ctx, node.dynRefData)
    let t = b.freshTemp()
    let fatPtrType = node.dynRefInterface & "_FatPtr"
    b.emitRawC(&"{fatPtrType} {t.strVal};")
    b.emitMov(lirVar(t.strVal & ".data"), data)
    b.emitMov(lirVar(t.strVal & ".vtable"), lirGlobal(node.dynRefConcreteType & "_" & node.dynRefInterface & "_VTable"))
    return t

  # ── DynCall ──
  of hDynCall:
    let receiver = lowerExpr(ctx, node.dynCallReceiver)
    var args: seq[LirValue] = @[receiver]
    for i in 1 ..< node.dynCallArgs.len:
      args.add(lowerExpr(ctx, node.dynCallArgs[i]))
    let t = b.freshTemp()
    b.emitRawC(&"{t.strVal} = {lirValToC(receiver)}.vtable->{node.dynCallMethod}({args.mapIt($it).join(\", \")});")
    return t

  # ── StructInit ──
  of hStructInit:
    var fields: seq[tuple[name: string, val: LirValue]] = @[]
    for f in node.structInitFields:
      fields.add((f.name, lowerExpr(ctx, f.value)))
    let t = b.freshTemp()
    b.emitStructInit(t, node.structInitName, fields)
    return t

  # ── SliceInit ──
  of hSliceInit:
    let t = b.freshTemp()
    let elemType = if node.typ.inner.len > 0: typeToCStr(node.typ.inner[0]) else: "void"
    var elems: seq[LirValue] = @[]
    for e in node.sliceInitElements:
      elems.add(lowerExpr(ctx, e))
    # Create a temporary array, then wrap in slice
    let arrTmp = b.freshTemp()
    b.emitRawC(&"{elemType} {arrTmp.strVal}[] = {{{elems.mapIt($it).join(\", \")}}};")
    b.emitSliceInit(t, elemType, arrTmp, lirInt(node.sliceInitLen))
    return t

  # ── TupleInit ──
  of hTupleInit:
    var elems: seq[LirValue] = @[]
    for e in node.tupleInitElements:
      elems.add(lowerExpr(ctx, e))
    let t = b.freshTemp()
    b.emitRawC(&"/* tuple */ {t.strVal} = {{{elems.mapIt($it).join(\", \")}}};")
    return t

  # ── If expression (ternary) ──
  of hIf:
    if node.ifThen.kind != hBlock and node.ifElse != nil:
      # Simple ternary
      let cond = lowerExpr(ctx, node.ifCond)
      let thenVal = lowerExpr(ctx, node.ifThen)
      let elseVal = lowerExpr(ctx, node.ifElse)
      let t = b.freshTemp()
      b.emitSelect(t, cond, thenVal, elseVal)
      return t
    else:
      # Complex if — fallback to block lowering
      # This shouldn't happen if lowering is done right, but handle gracefully
      return lirInt(0)

  # ── Block expression (returns last expr) ──
  of hBlock:
    for stmt in node.blockStmts:
      lowerStmt(ctx, stmt)
    if node.blockExpr != nil:
      return lowerExpr(ctx, node.blockExpr)
    return lirVoid()

  # ── Match (lowered by hir_lower already, but handle if present) ──
  of hMatch:
    # Should have been lowered by hir_lower.nim already
    return lirInt(0)

  else:
    # Fallback for unhandled expression kinds
    b.emitComment(&"unhandled expr kind: {node.kind}")
    return lirInt(0)

# ── Build C lvalue string for direct field/index assignment ──
proc buildLval(ctx: var LowerToLirCtx, n: HirNode): string =
  case n.kind
  of hLoad:
    if n.loadPtr != nil:
      return buildLval(ctx, n.loadPtr)
    else:
      let v = lowerExpr(ctx, n)
      return lirValToC(v)
  of hVar:
    return n.varName
  of hSelf:
    return "self"
  of hFieldPtr:
    let baseStr = buildLval(ctx, n.fieldPtrBase)
    let baseTyp = n.fieldPtrBase.typ
    let isPtr = baseTyp != nil and baseTyp.kind in {tkPointer, tkRef, tkMutRef}
    let sep = if isPtr: "->" else: "."
    return baseStr & sep & n.fieldName
  of hArrowField:
    let baseStr = buildLval(ctx, n.arrowFieldBase)
    return baseStr & "->" & n.arrowFieldName
  of hFieldAccess:
    let baseStr = buildLval(ctx, n.fieldAccessBase)
    return baseStr & "." & n.fieldAccessName
  of hIndexPtr:
    let baseStr = buildLval(ctx, n.indexPtrBase)
    let idx = lowerExpr(ctx, n.indexPtrIndex)
    return baseStr & "[" & lirValToC(idx) & "]"
  else:
    let v = lowerExpr(ctx, n)
    return lirValToC(v)

# ── Lowering: Statements → void ──

proc lowerStmt(ctx: var LowerToLirCtx, node: HirNode) =
  if node == nil: return
  template b: var LirBuilder = ctx.builder

  case node.kind

  # ── Return ──
  of hReturn:
    if node.returnValue != nil:
      let val = lowerExpr(ctx, node.returnValue)
      b.emitRet(val)
    else:
      b.emitRet()

  # ── If statement ──
  of hIf:
    # Lower to:  cond = lower(ifCond); jz else_label, cond
    #            lower(ifThen); jmp end_label
    #            else_label: lower(ifElse); end_label:
    let cond = lowerExpr(ctx, node.ifCond)
    let elseLbl = b.freshLabel("else")
    let endLbl = b.freshLabel("endif")

    if node.ifElse != nil:
      b.emitJz(elseLbl, cond)
      lowerStmt(ctx, node.ifThen)
      b.emitJmp(endLbl)
      b.emitLabel(elseLbl)
      lowerStmt(ctx, node.ifElse)
      b.emitLabel(endLbl)
    else:
      b.emitJz(endLbl, cond)
      lowerStmt(ctx, node.ifThen)
      b.emitLabel(endLbl)

  # ── While statement ──
  of hWhile:
    let startLbl = b.freshLabel("while")
    let endLbl = b.freshLabel("wend")

    ctx.loopStartLabels.add(startLbl.strVal)
    ctx.loopEndLabels.add(endLbl.strVal)
    b.emitLabel(startLbl)
    let cond = lowerExpr(ctx, node.whileCond)
    b.emitJz(endLbl, cond)
    lowerStmt(ctx, node.whileBody)
    b.emitJmp(startLbl)
    b.emitLabel(endLbl)
    discard ctx.loopStartLabels.pop()
    discard ctx.loopEndLabels.pop()

  # ── Loop (infinite) ──
  of hLoop:
    let startLbl = b.freshLabel("loop")
    let endLbl = b.freshLabel("lend")

    ctx.loopStartLabels.add(startLbl.strVal)
    ctx.loopEndLabels.add(endLbl.strVal)
    b.emitLabel(startLbl)
    lowerStmt(ctx, node.loopBody)
    b.emitJmp(startLbl)
    b.emitLabel(endLbl)
    discard ctx.loopStartLabels.pop()
    discard ctx.loopEndLabels.pop()

  # ── Break ──
  of hBreak:
    if ctx.loopEndLabels.len > 0:
      b.emitJmp(lirLabel(ctx.loopEndLabels[^1]))
    else:
      b.emitRawC("break;")

  # ── Continue ──
  of hContinue:
    if ctx.loopStartLabels.len > 0:
      b.emitJmp(lirLabel(ctx.loopStartLabels[^1]))
    else:
      b.emitRawC("continue;")

  # ── Alloca ──
  of hAlloca:
    let cType = typeToCStr(node.allocaType)
    let name = node.allocaName
    ctx.varTypes[name] = cType
    ctx.varLirValues[name] = lirVar(name)
    b.emitAlloca(name, cType)

  # ── Store ──
  of hStore:
    # If storing to a simple variable, use mov (direct assignment)
    if node.storePtr.kind == hVar:
      let val = lowerExpr(ctx, node.storeValue)
      b.emitMov(lirVar(node.storePtr.varName), val)
    else:
      let ptrVal = lowerExpr(ctx, node.storePtr)
      let val = lowerExpr(ctx, node.storeValue)
      # ptrVal is a void* address; cast and store
      let valCType = hirTypeToC(ctx, node.storeValue)
      b.emitRawC(&"*({valCType}*){lirValToC(ptrVal)} = {lirValToC(val)};")

  # ── Assign ──
  of hAssign:
    let value = lowerExpr(ctx, node.assignValue)
    case node.assignOp
    of tkAssign:
      case node.assignTarget.kind
      of hFieldPtr:
        let lval = buildLval(ctx, node.assignTarget)
        b.emitRawC(&"{lval} = {lirValToC(value)};")
      of hFieldAccess:
        let lval = buildLval(ctx, node.assignTarget)
        b.emitRawC(&"{lval} = {lirValToC(value)};")
      of hArrowField:
        let lval = buildLval(ctx, node.assignTarget)
        b.emitRawC(&"{lval} = {lirValToC(value)};")
      of hIndexPtr:
        let base = lowerExpr(ctx, node.assignTarget.indexPtrBase)
        let idx = lowerExpr(ctx, node.assignTarget.indexPtrIndex)
        b.emit(LirInstr(kind: lirStore, src: value, src2: base, dst: idx))
      of hLoad:
        if node.assignTarget.loadPtr != nil:
          let ptrNode = node.assignTarget.loadPtr
          case ptrNode.kind
          of hIndexPtr:
            let base = lowerExpr(ctx, ptrNode.indexPtrBase)
            let idx = lowerExpr(ctx, ptrNode.indexPtrIndex)
            b.emit(LirInstr(kind: lirStore, src: value, src2: base, dst: idx))
          of hFieldPtr:
            let lval = buildLval(ctx, ptrNode)
            b.emitRawC(&"{lval} = {lirValToC(value)};")
          of hArrowField:
            let lval = buildLval(ctx, ptrNode)
            b.emitRawC(&"{lval} = {lirValToC(value)};")
          else:
            let ptrVal = lowerExpr(ctx, ptrNode)
            let valCType = hirTypeToC(ctx, node.assignValue)
            b.emitRawC(&"*({valCType}*){lirValToC(ptrVal)} = {lirValToC(value)};")
        else:
          let target = lowerExpr(ctx, node.assignTarget)
          b.emitMov(target, value)
      else:
        let target = lowerExpr(ctx, node.assignTarget)
        b.emitMov(target, value)
    of tkPlusAssign:
      let target = lowerExpr(ctx, node.assignTarget)
      let t = b.freshTemp()
      b.emitBinOp(lirAdd, t, target, value)
      b.emit(LirInstr(kind: lirStore, src: t, src2: target))
    of tkMinusAssign:
      let target = lowerExpr(ctx, node.assignTarget)
      let t = b.freshTemp()
      b.emitBinOp(lirSub, t, target, value)
      b.emit(LirInstr(kind: lirStore, src: t, src2: target))
    else:
      let target = lowerExpr(ctx, node.assignTarget)
      b.emitMov(target, value)

  # ── Call statement (void return) ──
  of hCall:
    var args: seq[LirValue] = @[]
    for arg in node.callArgs:
      args.add(lowerExpr(ctx, arg))
    b.emitCallVoid(node.callCallee, args)

  # ── CallIndirect statement ──
  of hCallIndirect:
    let callee = lowerExpr(ctx, node.callIndirectCallee)
    var args: seq[LirValue] = @[]
    for arg in node.callIndirectArgs:
      args.add(lowerExpr(ctx, arg))
    b.emit(LirInstr(kind: lirCallIndirect, src: callee, extra: args))

  # ── Block ──
  of hBlock:
    if node.isScope:
      b.emitRawC("{")
    for stmt in node.blockStmts:
      lowerStmt(ctx, stmt)
    if node.blockExpr != nil:
      # If block is an expression, result is unused at statement level
      discard lowerExpr(ctx, node.blockExpr)
    if node.isScope:
      b.emitRawC("}")

  # ── Emit (inline C) ──
  of hEmit:
    b.emitRawC(node.emitCode)

  # ── Expression statement ──
  else:
    # Expression evaluated for side effects; temp is unused
    discard lowerExpr(ctx, node)

# ── Module-level lowering ──

proc lowerModuleToLir*(hirMod: HirModule): LirBuilder =
  ## Convert a full HIR module into LIR functions.
  var ctx = initLowerToLirCtx()

  for f in hirMod.funcs:
    var params: seq[tuple[name: string, cType: string]] = @[]
    for p in f.params:
      let ct = typeToCStr(p.typ)
      params.add((p.name, ct))
      ctx.varTypes[p.name] = ct
      ctx.varLirValues[p.name] = lirVar(p.name)

    let retCT = if f.retType != nil: typeToCStr(f.retType) else: "void"
    ctx.funcRetType = retCT
    ctx.builder.beginFunc(f.name, params, retCT, f.isPublic)

    if f.body != nil:
      if f.body.kind == hBlock:
        for stmt in f.body.blockStmts:
          lowerStmt(ctx, stmt)
        if f.body.blockExpr != nil and f.retType != nil and f.retType.kind != tkVoid:
          let val = lowerExpr(ctx, f.body.blockExpr)
          ctx.builder.emitRet(val)
      else:
        lowerStmt(ctx, f.body)

    ctx.builder.endFunc()

  return ctx.builder
