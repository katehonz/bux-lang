## LIR — Low-level Intermediate Representation
## Linear 3-address code IR, designed for straightforward C emission.
## Each HIR construct lowers to 5-30 LIR instructions.

type
  LirKind* = enum
    # ── Data movement ──
    lirMov             ## dst = src
    lirLoad            ## dst = *(base + offset)   [type: base elem type]
    lirStore           ## *(base + offset) = src
    lirLoadGlobal      ## dst = global_name

    # ── Arithmetic (3-address, signed) ──
    lirAdd
    lirSub
    lirMul
    lirDiv
    lirMod

    # ── Bitwise ──
    lirAnd
    lirOr
    lirXor
    lirShl
    lirShr

    # ── Unary ──
    lirNeg             ## dst = -src
    lirNot             ## dst = !src   (logical)
    lirBNot            ## dst = ~src   (bitwise)

    # ── Comparison (dst = 0 or 1) ──
    lirCmpEq
    lirCmpNe
    lirCmpLt
    lirCmpLe
    lirCmpGt
    lirCmpGe

    # ── Control flow ──
    lirLabel           ## label_name:
    lirJmp             ## goto target
    lirJz              ## if (!cond) goto target
    lirJnz             ## if (cond) goto target

    # ── Calls ──
    lirCall            ## dst = callee(args...)
    lirCallVoid        ## callee(args...)   [no return]
    lirCallIndirect    ## dst = (*fn_ptr)(args...)

    # ── Return ──
    lirRet             ## return [val]

    # ── Stack allocation ──
    lirAlloca          ## type dst;   (declare a C local)

    # ── Pointers / addressing ──
    lirAddrOf          ## dst = &source_var
    lirFieldPtr        ## dst = &(base.field_name)
    lirArrowFieldPtr   ## dst = &(base->field_name)
    lirIndexPtr        ## dst = &base[idx]
    lirPtrAdd          ## dst = base + offset_bytes  (raw pointer arithmetic)

    # ── Type conversion ──
    lirCast            ## dst = (target_type)src

    # ── Composite literals ──
    lirStructInit      ## dst = (StructType){.f1=v1, .f2=v2, ...}
    lirSliceInit       ## dst = (SliceType){.data=arr, .len=n}

    # ── Ternary (convenience; lowered from if-expr) ──
    lirSelect          ## dst = cond ? a : b

    # ── Inline C (for runtime calls that C handles natively) ──
    lirRawC            ## emit raw C line

    # ── Source annotation ──
    lirComment         ## /* text */

  LirValueKind* = enum
    lvkTemp       ## Virtual register / temp (e.g. "%42")
    lvkVar        ## Named variable / parameter
    lvkInt        ## Integer literal
    lvkFloat      ## Float literal
    lvkString     ## String literal (already C-escaped)
    lvkGlobal     ## Global variable / constant name
    lvkLabel      ## Label reference
    lvkField      ## Field name (for struct operations)
    lvkType       ## C type name (for casts, alloca, struct init)
    lvkVoid       ## No value

  LirValue* = object
    case kind*: LirValueKind
    of lvkVoid: discard
    of lvkTemp, lvkVar, lvkGlobal, lvkLabel, lvkField, lvkType, lvkString:
      strVal*: string
    of lvkInt:
      intVal*: int64
    of lvkFloat:
      floatVal*: float64

  LirInstr* = object
    kind*: LirKind
    dst*: LirValue          ## Destination (temp or void)
    src*: LirValue          ## Source operand
    src2*: LirValue         ## Second source operand (for binary ops)
    extra*: seq[LirValue]   ## Extra operands (call args, struct fields, etc.)
    locLine*: int           ## Source line for debug comments (0 = none)
    locFile*: string        ## Source file for debug comments ("" = none)

# ── Constructor helpers ──

proc lirTemp*(name: string): LirValue =
  LirValue(kind: lvkTemp, strVal: name)

proc lirVar*(name: string): LirValue =
  LirValue(kind: lvkVar, strVal: name)

proc lirInt*(v: int64): LirValue =
  LirValue(kind: lvkInt, intVal: v)

proc lirFloatLit*(v: float64): LirValue =
  LirValue(kind: lvkFloat, floatVal: v)

proc lirStr*(v: string): LirValue =
  ## Already C-escaped and quoted string
  LirValue(kind: lvkString, strVal: v)

proc lirGlobal*(name: string): LirValue =
  LirValue(kind: lvkGlobal, strVal: name)

proc lirLabel*(name: string): LirValue =
  LirValue(kind: lvkLabel, strVal: name)

proc lirField*(name: string): LirValue =
  LirValue(kind: lvkField, strVal: name)

proc lirType*(name: string): LirValue =
  LirValue(kind: lvkType, strVal: name)

proc lirVoid*(): LirValue =
  LirValue(kind: lvkVoid)

proc `$`*(v: LirValue): string =
  case v.kind
  of lvkVoid: "void"
  of lvkTemp: "%" & v.strVal
  of lvkVar: v.strVal
  of lvkInt: $v.intVal
  of lvkFloat: $v.floatVal
  of lvkString: v.strVal
  of lvkGlobal: "@" & v.strVal
  of lvkLabel: ":" & v.strVal
  of lvkField: "." & v.strVal
  of lvkType: "<" & v.strVal & ">"

# ── LIR function ──

type
  LirFunc* = object
    name*: string
    params*: seq[tuple[name: string, cType: string]]
    retType*: string          ## C return type ("int", "void", etc.)
    instrs*: seq[LirInstr]
    isPublic*: bool

  LirModule* = object
    funcs*: seq[LirFunc]
    globals*: seq[tuple[name: string, cType: string, initVal: string]]
    structDefs*: seq[string]   ## Raw C struct typedef strings
    enumDefs*: seq[string]     ## Raw C enum typedef strings
    externs*: seq[string]      ## Raw C extern declarations
    includes*: seq[string]     ## #include <...>
    preamble*: string          ## Raw C code at top of file

# ── Builder context (temp counter, label counter) ──

type
  LirBuilder* = object
    funcs*: seq[LirFunc]
    tempCounter*: int
    labelCounter*: int
    commentLine*: int
    commentFile*: string
    ## Current function being built
    curFunc*: LirFunc
    curFuncActive*: bool

proc initLirBuilder*(): LirBuilder =
  result = LirBuilder()
  result.tempCounter = 0
  result.labelCounter = 0

proc freshTemp*(b: var LirBuilder): LirValue =
  inc b.tempCounter
  result = lirTemp("_t" & $b.tempCounter)

proc freshLabel*(b: var LirBuilder, prefix: string = "L"): LirValue =
  inc b.labelCounter
  result = lirLabel(prefix & $b.labelCounter)

# ── Instruction emitters ──

proc emit*(b: var LirBuilder, instr: LirInstr) =
  var i = instr
  if b.commentLine > 0:
    i.locLine = b.commentLine
    i.locFile = b.commentFile
  b.curFunc.instrs.add(i)

proc emitMov*(b: var LirBuilder, dst, src: LirValue) =
  b.emit(LirInstr(kind: lirMov, dst: dst, src: src))

proc emitLoad*(b: var LirBuilder, dst, base: LirValue, offset: int = 0) =
  b.emit(LirInstr(kind: lirLoad, dst: dst, src: base, src2: lirInt(offset)))

proc emitStore*(b: var LirBuilder, base: LirValue, src: LirValue, offset: int = 0) =
  b.emit(LirInstr(kind: lirStore, src: src, src2: base, dst: lirInt(offset)))

proc emitBinOp*(b: var LirBuilder, op: LirKind, dst, a, bl: LirValue) =
  b.emit(LirInstr(kind: op, dst: dst, src: a, src2: bl))

proc emitUnary*(b: var LirBuilder, op: LirKind, dst, src: LirValue) =
  b.emit(LirInstr(kind: op, dst: dst, src: src))

proc emitCmp*(b: var LirBuilder, op: LirKind, dst, a, bl: LirValue) =
  b.emit(LirInstr(kind: op, dst: dst, src: a, src2: bl))

proc emitLabel*(b: var LirBuilder, label: LirValue) =
  b.emit(LirInstr(kind: lirLabel, src: label))

proc emitJmp*(b: var LirBuilder, target: LirValue) =
  b.emit(LirInstr(kind: lirJmp, src: target))

proc emitJz*(b: var LirBuilder, target, cond: LirValue) =
  b.emit(LirInstr(kind: lirJz, src: target, src2: cond))

proc emitJnz*(b: var LirBuilder, target, cond: LirValue) =
  b.emit(LirInstr(kind: lirJnz, src: target, src2: cond))

proc emitCall*(b: var LirBuilder, dst: LirValue, callee: string, args: seq[LirValue]) =
  b.emit(LirInstr(kind: lirCall, dst: dst, src: lirGlobal(callee), extra: args))

proc emitCallVoid*(b: var LirBuilder, callee: string, args: seq[LirValue]) =
  b.emit(LirInstr(kind: lirCallVoid, dst: lirVoid(), src: lirGlobal(callee), extra: args))

proc emitRet*(b: var LirBuilder, val: LirValue = lirVoid()) =
  b.emit(LirInstr(kind: lirRet, src: val))

proc emitAlloca*(b: var LirBuilder, name: string, cType: string) =
  b.emit(LirInstr(kind: lirAlloca, dst: lirVar(name), src: lirType(cType)))

proc emitAddrOf*(b: var LirBuilder, dst, src: LirValue) =
  b.emit(LirInstr(kind: lirAddrOf, dst: dst, src: src))

proc emitFieldPtr*(b: var LirBuilder, dst, base: LirValue, field: string) =
  b.emit(LirInstr(kind: lirFieldPtr, dst: dst, src: base, src2: lirField(field)))

proc emitArrowFieldPtr*(b: var LirBuilder, dst, base: LirValue, field: string) =
  b.emit(LirInstr(kind: lirArrowFieldPtr, dst: dst, src: base, src2: lirField(field)))

proc emitIndexPtr*(b: var LirBuilder, dst, base, idx: LirValue) =
  b.emit(LirInstr(kind: lirIndexPtr, dst: dst, src: base, src2: idx))

proc emitPtrAdd*(b: var LirBuilder, dst, base, offset: LirValue) =
  b.emit(LirInstr(kind: lirPtrAdd, dst: dst, src: base, src2: offset))

proc emitCast*(b: var LirBuilder, dst, src: LirValue, targetType: string) =
  b.emit(LirInstr(kind: lirCast, dst: dst, src: src, src2: lirType(targetType)))

proc emitStructInit*(b: var LirBuilder, dst: LirValue, structType: string,
                     fields: seq[tuple[name: string, val: LirValue]]) =
  var extras: seq[LirValue] = @[lirType(structType)]
  for f in fields:
    extras.add(lirField(f.name))
    extras.add(f.val)
  b.emit(LirInstr(kind: lirStructInit, dst: dst, extra: extras))

proc emitSliceInit*(b: var LirBuilder, dst: LirValue, elemType: string,
                    dataPtr: LirValue, length: LirValue) =
  b.emit(LirInstr(kind: lirSliceInit, dst: dst, src: dataPtr, src2: length,
                   extra: @[lirType(elemType)]))

proc emitSelect*(b: var LirBuilder, dst, cond, thenVal, elseVal: LirValue) =
  b.emit(LirInstr(kind: lirSelect, dst: dst, src: cond, src2: thenVal,
                   extra: @[elseVal]))

proc emitRawC*(b: var LirBuilder, code: string) =
  b.emit(LirInstr(kind: lirRawC, src: lirStr(code)))

proc emitComment*(b: var LirBuilder, text: string) =
  b.emit(LirInstr(kind: lirComment, src: lirStr(text)))

# ── Function management ──

proc beginFunc*(b: var LirBuilder, name: string, params: seq[tuple[name: string, cType: string]],
                retType: string, isPublic: bool = true) =
  if b.curFuncActive:
    b.funcs.add(b.curFunc)
  b.curFunc = LirFunc(name: name, params: params, retType: retType,
                      isPublic: isPublic)
  b.curFuncActive = true

proc endFunc*(b: var LirBuilder) =
  if b.curFuncActive:
    b.funcs.add(b.curFunc)
    b.curFuncActive = false
    b.curFunc = LirFunc()

proc setSourceLoc*(b: var LirBuilder, line: int, file: string) =
  b.commentLine = line
  b.commentFile = file
