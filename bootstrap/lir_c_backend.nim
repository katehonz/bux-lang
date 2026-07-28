## LIR → C Backend
## Emits clean, well-structured C code from LIR instructions.
## Since LIR is already linear and low-level, C emission is straightforward.

import std/[strutils, strformat, tables, sequtils, sets]
import lir, hir, types, token

type
  LirCBackend* = object
    output*: string
    indent*: int
    tempTypes*: Table[string, string]  ## Track C types of temp variables
    emitDebugLines*: bool              ## Emit #line → .bux for DWARF (E.4)
    lastDebugLine*: int
    lastDebugFile*: string

proc initLirCBackend*(emitDebugLines: bool = true): LirCBackend =
  result = LirCBackend(
    indent: 0,
    tempTypes: initTable[string, string](),
    emitDebugLines: emitDebugLines,
    lastDebugLine: 0,
    lastDebugFile: "",
  )

proc emitIndent(be: var LirCBackend) =
  for i in 0 ..< be.indent:
    be.output.add("    ")

proc emitLine(be: var LirCBackend, s: string) =
  be.emitIndent()
  be.output.add(s)
  be.output.add("\n")

proc emitDebugLine(be: var LirCBackend, instr: LirInstr) =
  ## Map generated C back to Bux source for gdb/DWARF via #line.
  if not be.emitDebugLines: return
  if instr.locLine <= 0: return
  if instr.locLine == be.lastDebugLine and instr.locFile == be.lastDebugFile:
    return
  be.lastDebugLine = instr.locLine
  be.lastDebugFile = instr.locFile
  var path = instr.locFile
  if path.len == 0:
    path = "<bux>"
  # Escape for C string literal
  path = path.replace("\\", "\\\\").replace("\"", "\\\"")
  # #line must start at column 0
  be.output.add(&"#line {instr.locLine} \"{path}\"\n")

proc valToC(be: var LirCBackend, v: LirValue): string =
  ## Convert a LirValue to its C representation.
  case v.kind
  of lvkVoid: ""
  of lvkTemp: v.strVal
  of lvkVar: v.strVal
  of lvkInt: $v.intVal
  of lvkFloat: $v.floatVal
  of lvkString: v.strVal
  of lvkGlobal: v.strVal
  of lvkLabel: v.strVal
  of lvkField: v.strVal
  of lvkType: v.strVal

proc cParamDecl(cType, name: string): string =
  ## Emit a C parameter declaration, handling function-pointer syntax.
  if cType.contains("(*)"):
    return cType.replace("(*)", "(*" & name & ")")
  else:
    return cType & " " & name

# ── Per-instruction emission ──

proc emitInstr(be: var LirCBackend, instr: LirInstr) =
  be.emitDebugLine(instr)
  template v(x: LirValue): string = valToC(be, x)
  case instr.kind

  # ── Data movement ──
  of lirMov:
    be.emitLine(&"{v(instr.dst)} = {v(instr.src)};")

  of lirLoad:
    # dst = *(base + offset)  or  dst = base->src2 (if src2 is a field name)
    if instr.src2.kind == lvkField:
      be.emitLine(&"{v(instr.dst)} = {v(instr.src)}.{v(instr.src2)};")
    elif instr.src2.kind == lvkInt and instr.src2.intVal == 0:
      be.emitLine(&"{v(instr.dst)} = *{v(instr.src)};")
    elif instr.src2.kind == lvkTemp or instr.src2.kind == lvkVar:
      be.emitLine(&"{v(instr.dst)} = {v(instr.src)}[{v(instr.src2)}];")
    else:
      be.emitLine(&"{v(instr.dst)} = {v(instr.src)}[{v(instr.src2)}];")

  of lirStore:
    # *(base + offset) = src
    if instr.src2.kind == lvkField:
      be.emitLine(&"{v(instr.src2)}.{v(instr.dst)} = {v(instr.src)};")
    elif instr.dst.kind == lvkInt and instr.dst.intVal == 0:
      be.emitLine(&"*{v(instr.src2)} = {v(instr.src)};")
    elif instr.src2.kind == lvkTemp or instr.src2.kind == lvkVar:
      be.emitLine(&"{v(instr.src2)}[{v(instr.dst)}] = {v(instr.src)};")
    else:
      be.emitLine(&"*({v(instr.src2)} + {v(instr.dst)}) = {v(instr.src)};")

  of lirLoadGlobal:
    be.emitLine(&"{v(instr.dst)} = {v(instr.src)};")

  # ── Arithmetic ──
  of lirDiv:
    # Checked integer division (runtime panics on divisor 0 instead of SIGFPE).
    be.emitLine(&"{v(instr.dst)} = bux_div_i64((int64_t)({v(instr.src)}), (int64_t)({v(instr.src2)}));")
  of lirMod:
    be.emitLine(&"{v(instr.dst)} = bux_mod_i64((int64_t)({v(instr.src)}), (int64_t)({v(instr.src2)}));")
  of lirAdd, lirSub, lirMul,
     lirAnd, lirOr, lirXor, lirShl, lirShr:
    let op = case instr.kind
      of lirAdd: "+"
      of lirSub: "-"
      of lirMul: "*"
      of lirAnd: "&"
      of lirOr: "|"
      of lirXor: "^"
      of lirShl: "<<"
      of lirShr: ">>"
      else: "?"
    # Parenthesize so future non-temp operands cannot be rewritten by C precedence
    be.emitLine(&"{v(instr.dst)} = ({v(instr.src)} {op} {v(instr.src2)});")

  of lirNeg:
    be.emitLine(&"{v(instr.dst)} = -({v(instr.src)});")
  of lirNot:
    be.emitLine(&"{v(instr.dst)} = !({v(instr.src)});")
  of lirBNot:
    be.emitLine(&"{v(instr.dst)} = ~({v(instr.src)});")

  # ── Comparison ──
  of lirCmpEq, lirCmpNe, lirCmpLt, lirCmpLe, lirCmpGt, lirCmpGe:
    let op = case instr.kind
      of lirCmpEq: "=="
      of lirCmpNe: "!="
      of lirCmpLt: "<"
      of lirCmpLe: "<="
      of lirCmpGt: ">"
      of lirCmpGe: ">="
      else: "=="
    be.emitLine(&"{v(instr.dst)} = ({v(instr.src)} {op} {v(instr.src2)});")

  # ── Control flow ──
  of lirLabel:
    be.emitLine(&"{v(instr.src)}:;")  # C requires statement after label
    # Add a null statement to avoid "label at end of compound statement" warnings
    # Handled by the next instruction naturally

  of lirJmp:
    be.emitLine(&"goto {v(instr.src)};")

  of lirJz:
    be.emitLine(&"if (!{v(instr.src2)}) goto {v(instr.src)};")

  of lirJnz:
    be.emitLine(&"if ({v(instr.src2)}) goto {v(instr.src)};")

  # ── Calls ──
  of lirCall:
    var argsStr = ""
    for i, arg in instr.extra:
      if i > 0: argsStr.add(", ")
      argsStr.add(v(arg))
    be.emitLine(&"{v(instr.dst)} = {v(instr.src)}({argsStr});")

  of lirCallVoid:
    var argsStr = ""
    for i, arg in instr.extra:
      if i > 0: argsStr.add(", ")
      argsStr.add(v(arg))
    be.emitLine(&"{v(instr.src)}({argsStr});")

  of lirCallIndirect:
    ## Fat function pointer call: f.code(f.env, args...)
    var argsStr = ""
    for i, arg in instr.extra:
      if i > 0: argsStr.add(", ")
      argsStr.add(v(arg))
    let callee = v(instr.src)
    if instr.dst.kind != lvkVoid:
      if argsStr.len > 0:
        be.emitLine(&"{v(instr.dst)} = ({callee}.code)({callee}.env, {argsStr});")
      else:
        be.emitLine(&"{v(instr.dst)} = ({callee}.code)({callee}.env);")
    else:
      if argsStr.len > 0:
        be.emitLine(&"({callee}.code)({callee}.env, {argsStr});")
      else:
        be.emitLine(&"({callee}.code)({callee}.env);")

  # ── Return ──
  of lirRet:
    if instr.src.kind != lvkVoid:
      be.emitLine(&"return {v(instr.src)};")
    else:
      be.emitLine("return;")

  # ── Alloca ──
  of lirAlloca:
    var ct = v(instr.src)
    if instr.dst.strVal.len > 0 and be.tempTypes.hasKey(instr.dst.strVal):
      let inferred = be.tempTypes[instr.dst.strVal]
      if inferred != "" and inferred != ct:
        ct = inferred
    be.emitLine(cParamDecl(ct, v(instr.dst)) & ";")

  # ── Pointers ──
  of lirAddrOf:
    be.emitLine(&"{v(instr.dst)} = &{v(instr.src)};")

  of lirFieldPtr:
    be.emitLine(&"{v(instr.dst)} = &({v(instr.src)}.{v(instr.src2)});")

  of lirArrowFieldPtr:
    be.emitLine(&"{v(instr.dst)} = &({v(instr.src)}->{v(instr.src2)});")

  of lirIndexPtr:
    be.emitLine(&"{v(instr.dst)} = &({v(instr.src)}[{v(instr.src2)}]);")

  of lirPtrAdd:
    be.emitLine(&"{v(instr.dst)} = ({v(instr.src)} + {v(instr.src2)});")

  # ── Cast ──
  of lirCast:
    be.emitLine(&"{v(instr.dst)} = ({v(instr.src2)}){v(instr.src)};")

  # ── StructInit ──
  of lirStructInit:
    let structType = v(instr.extra[0])
    var fieldPairs = ""
    var i = 1
    while i < instr.extra.len:
      let fieldName = v(instr.extra[i])     # e.g. "width"
      let fieldVal = v(instr.extra[i + 1])  # e.g. "10"
      if i > 1: fieldPairs.add(", ")
      fieldPairs.add(&".{fieldName} = {fieldVal}")
      i += 2
    be.emitLine(&"{v(instr.dst)} = ({structType}){{{fieldPairs}}};")

  # ── SliceInit ──
  of lirSliceInit:
    let elemType = v(instr.extra[0])
    be.emitLine(&"{v(instr.dst)} = (Slice_{elemType}){{.data = ({elemType}*){v(instr.src)}, .len = {v(instr.src2)}}};")

  # ── Select (ternary) ──
  of lirSelect:
    let elseVal = if instr.extra.len > 0: v(instr.extra[0]) else: "0"
    be.emitLine(&"{v(instr.dst)} = ({v(instr.src)}) ? {v(instr.src2)} : {elseVal};")

  # ── Raw C ──
  of lirRawC:
    let code = v(instr.src)
    if code.len > 0:
      be.emitLine(code)

  # ── Comment ──
  of lirComment:
    let text = v(instr.src)
    be.emitLine(&"/* {text} */")

# ── Function emission ──

proc emitFunc(be: var LirCBackend, f: LirFunc, funcRetTypes: Table[string, string], funcPtrTypes: Table[string, string]) =
  var paramsStr = ""
  for i, p in f.params:
    if i > 0: paramsStr.add(", ")
    paramsStr.add(cParamDecl(p.cType, p.name))
  if f.params.len == 0:
    paramsStr = "void"

  # Point the function entry at the first Bux location so gdb `list Main` works
  # (otherwise leftover #line from the previous function pollutes the prologue).
  if be.emitDebugLines:
    for instr in f.instrs:
      if instr.locLine > 0:
        be.lastDebugLine = 0
        be.lastDebugFile = ""
        be.emitDebugLine(instr)
        break

  be.emitLine(&"{f.retType} {f.name}({paramsStr}) {{")
  be.indent += 1

  # ── Pass 1: collect types from allocas, params, and instructions ──
  var varTypes = initTable[string, string]()
  var tempsSet: seq[string] = @[]
  for p in f.params:
    varTypes[p.name] = p.cType
    be.tempTypes[p.name] = p.cType
  for instr in f.instrs:
    if instr.kind == lirAlloca and instr.dst.kind == lvkVar and instr.src.kind == lvkType:
      varTypes[instr.dst.strVal] = instr.src.strVal
      be.tempTypes[instr.dst.strVal] = instr.src.strVal
      if instr.dst.strVal notin tempsSet:
        tempsSet.add(instr.dst.strVal)

  # ── Pass 2: iterative type inference for temps ──
  var changed = true
  while changed:
    changed = false
    for instr in f.instrs:
      if instr.dst.kind != lvkTemp or instr.dst.strVal.len == 0:
        continue
      let name = instr.dst.strVal
      let oldType = if be.tempTypes.hasKey(name): be.tempTypes[name] else: ""
      var newType = oldType

      case instr.kind
      of lirStructInit:
        if instr.extra.len > 0 and instr.extra[0].kind == lvkType:
          newType = instr.extra[0].strVal
      of lirSliceInit:
        if instr.extra.len > 0 and instr.extra[0].kind == lvkType:
          newType = "Slice_" & instr.extra[0].strVal
      of lirCast:
        if instr.src2.kind == lvkType:
          newType = instr.src2.strVal
      of lirCall:
        if instr.src.kind == lvkGlobal and funcRetTypes.hasKey(instr.src.strVal):
          newType = funcRetTypes[instr.src.strVal]
      of lirCallIndirect:
        # Conservative; try to infer from dst usage in later passes
        discard
      of lirMov:
        if instr.src.kind == lvkTemp and be.tempTypes.hasKey(instr.src.strVal):
          newType = be.tempTypes[instr.src.strVal]
        elif instr.src.kind == lvkVar and varTypes.hasKey(instr.src.strVal):
          newType = varTypes[instr.src.strVal]
      of lirLoad, lirLoadGlobal:
        # Try to deduce pointee type from pointer vars/temps
        if instr.src.kind == lvkVar and varTypes.hasKey(instr.src.strVal):
          let srcType = varTypes[instr.src.strVal]
          if srcType.endsWith("*"):
            newType = srcType[0 ..< srcType.len - 1]
          elif srcType.startsWith("Slice_"):
            newType = srcType[6 ..< srcType.len]
        elif instr.src.kind == lvkTemp and be.tempTypes.hasKey(instr.src.strVal):
          let srcType = be.tempTypes[instr.src.strVal]
          if srcType.endsWith("*"):
            newType = srcType[0 ..< srcType.len - 1]
          elif srcType.startsWith("Slice_"):
            newType = srcType[6 ..< srcType.len]
      of lirSelect:
        if instr.src2.kind == lvkTemp and be.tempTypes.hasKey(instr.src2.strVal):
          newType = be.tempTypes[instr.src2.strVal]
        elif instr.extra.len > 0 and instr.extra[0].kind == lvkTemp and be.tempTypes.hasKey(instr.extra[0].strVal):
          newType = be.tempTypes[instr.extra[0].strVal]
        elif instr.src2.kind == lvkVar and varTypes.hasKey(instr.src2.strVal):
          newType = varTypes[instr.src2.strVal]
      of lirAddrOf:
        if funcPtrTypes.hasKey(instr.src.strVal):
          newType = funcPtrTypes[instr.src.strVal]
        else:
          newType = "void*";
      of lirFieldPtr, lirArrowFieldPtr, lirIndexPtr, lirPtrAdd:
        newType = "void*"
      of lirAdd, lirSub, lirMul, lirDiv, lirMod, lirNeg,
         lirCmpEq, lirCmpNe, lirCmpLt, lirCmpLe, lirCmpGt, lirCmpGe,
         lirAnd, lirOr, lirXor, lirShl, lirShr, lirNot, lirBNot:
        newType = "int"
      else:
        discard

      if newType != "" and newType != oldType:
        be.tempTypes[name] = newType
        changed = true

  # ── Pass 3: declare temps that were inferred ──
  var declared: seq[string] = @[]
  for instr in f.instrs:
    if instr.kind == lirAlloca and instr.dst.strVal.len > 0 and instr.dst.strVal notin declared:
      declared.add(instr.dst.strVal)
      continue
    if instr.dst.kind == lvkTemp and instr.dst.strVal.len > 0 and instr.dst.strVal notin declared:
      if be.tempTypes.hasKey(instr.dst.strVal):
        let ct = be.tempTypes[instr.dst.strVal]
        if ct != "":
          declared.add(instr.dst.strVal)
          be.emitLine(cParamDecl(ct, instr.dst.strVal) & ";")

  # ── Pass 4: emit instructions ──
  for instr in f.instrs:
    be.emitInstr(instr)

  be.indent -= 1
  be.emitLine("}")
  be.emitLine("")

# ── Struct/Enum emission (from HIR module) ──

proc sanitizeCTypeNamePart(s: string): string =
  result = s
  result = result.replace("const char*", "cstr")
  result = result.replace("unsigned int", "uint")
  result = result.replace(" ", "_")
  result = result.replace("*", "Ptr")
  result = result.replace("(", "")
  result = result.replace(")", "")
  result = result.replace(",", "_")
  result = result.replace(".", "_")

proc typeToCStr(typ: Type): string
proc funcFatTypeName(typ: Type): string
proc funcCodePtrType(typ: Type): string

proc typeToCStr(typ: Type): string =
  ## Duplicate from lir_lower for self-containedness
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
  of tkTuple:
    if typ.inner.len == 0:
      return "Tuple_Empty"
    var parts: seq[string] = @[]
    for e in typ.inner:
      parts.add(sanitizeCTypeNamePart(typeToCStr(e)))
    return "Tuple_" & parts.join("_")
  of tkFunc:
    return funcFatTypeName(typ)
  else: return "int"

proc funcFatTypeName(typ: Type): string =
  if typ == nil or typ.kind != tkFunc:
    return "BuxFn_void"
  let ret = if typ.inner.len > 0: typeToCStr(typ.inner[^1]) else: "void"
  var parts: seq[string] = @[sanitizeCTypeNamePart(ret)]
  if typ.inner.len > 1:
    for p in typ.inner[0 ..^ 2]:
      parts.add(sanitizeCTypeNamePart(typeToCStr(p)))
  else:
    parts.add("void")
  return "BuxFn_" & parts.join("_")

proc funcCodePtrType(typ: Type): string =
  if typ == nil or typ.kind != tkFunc:
    return "void (*)(void*)"
  let ret = if typ.inner.len > 0: typeToCStr(typ.inner[^1]) else: "void"
  var params: seq[string] = @["void* env"]
  if typ.inner.len > 1:
    for p in typ.inner[0 ..^ 2]:
      params.add(typeToCStr(p))
  return ret & " (*)(" & params.join(", ") & ")"

proc emitStructDef(be: var LirCBackend, name: string, fields: seq[tuple[name: string, typ: Type]]) =
  be.emitLine(&"typedef struct {name} {{")
  be.indent += 1
  for f in fields:
    be.emitLine(&"{typeToCStr(f.typ)} {f.name};")
  be.indent -= 1
  be.emitLine(&"}} {name};")
  be.emitLine("")

proc emitEnumDef(be: var LirCBackend, name: string, variants: seq[HirEnumVariant]) =
  var hasData = false
  for v in variants:
    if v.fields.len > 0 or v.namedFields.len > 0:
      hasData = true
      break

  if not hasData:
    # Simple enum
    be.emitLine(&"typedef enum {{")
    be.indent += 1
    for i, v in variants:
      if i < variants.len - 1:
        be.emitLine(&"{name}_{v.name},")
      else:
        be.emitLine(&"{name}_{v.name}")
    be.indent -= 1
    be.emitLine(&"}} {name};")
    be.emitLine("")
  else:
    # Tagged union
    be.emitLine(&"typedef enum {{")
    be.indent += 1
    for i, v in variants:
      if i < variants.len - 1:
        be.emitLine(&"{name}_{v.name},")
      else:
        be.emitLine(&"{name}_{v.name}")
    be.indent -= 1
    be.emitLine(&"}} {name}_Tag;")
    be.emitLine("")

    be.emitLine(&"typedef union {{")
    be.indent += 1
    for v in variants:
      if v.fields.len == 1:
        # Single positional field — flat (compat: data.Variant_0)
        be.emitLine(&"{typeToCStr(v.fields[0])} {v.name}_0;")
      elif v.fields.len > 1:
        # Multi positional — named nested struct Enum_Variant_Payload
        let nestedName = name & "_" & v.name & "_Payload"
        be.emitLine(&"{nestedName} {v.name};")
      elif v.namedFields.len > 0:
        let nestedName = name & "_" & v.name & "_Payload"
        be.emitLine(&"{nestedName} {v.name};")
    be.indent -= 1
    be.emitLine(&"}} {name}_Data;")
    be.emitLine("")

    be.emitLine(&"typedef struct {{")
    be.indent += 1
    be.emitLine(&"{name}_Tag tag;")
    be.emitLine(&"{name}_Data data;")
    be.indent -= 1
    be.emitLine(&"}} {name};")
    be.emitLine("")

# ── Type dependency ordering ──

proc collectValueDeps(typ: Type): seq[string] =
  ## Return type names that must be fully defined before a value of `typ`
  ## can be declared. Pointers/refs only need a forward declaration, so
  ## they do not introduce a dependency.
  if typ == nil: return @[]
  case typ.kind
  of tkNamed:
    return @[typ.name]
  of tkSlice:
    return @[typeToCStr(typ)]
  of tkTuple:
    var deps: seq[string] = @[]
    for e in typ.inner:
      for d in collectValueDeps(e):
        if d notin deps:
          deps.add(d)
      if e != nil and e.kind == tkTuple:
        let tn = typeToCStr(e)
        if tn notin deps:
          deps.add(tn)
    return deps
  of tkPointer, tkRef, tkMutRef, tkFunc:
    return @[]
  else:
    return @[]

proc emitTupleDef(be: var LirCBackend, typ: Type) =
  ## typedef struct { T0 _0; T1 _1; ... } Tuple_...;
  let name = typeToCStr(typ)
  be.emitLine(&"typedef struct {name} {{")
  be.indent += 1
  if typ.inner.len == 0:
    be.emitLine("char _pad;")
  else:
    for i, e in typ.inner:
      be.emitLine(&"{typeToCStr(e)} _{i};")
  be.indent -= 1
  be.emitLine(&"}} {name};")
  be.emitLine("")

proc emitSliceTypeDef(be: var LirCBackend, name: string, elem: string) =
  be.emitLine(&"typedef struct {{ {elem}* data; size_t len; }} {name};")

# ── Module emission ──

proc emitModule*(be: var LirCBackend, builder: LirBuilder, module: HirModule): string =
  ## Emit full C source from LIR builder + HIR module metadata.
  be.output = ""

  # Build function return type lookup table
  var funcRetTypes = initTable[string, string]()
  for f in module.funcs:
    funcRetTypes[f.name] = typeToCStr(f.retType)
  for f in module.externFuncs:
    funcRetTypes[f.name] = typeToCStr(f.retType)

  # Build function-pointer type lookup table (for address-of)
  var funcPtrTypes = initTable[string, string]()
  for f in module.funcs:
    let params = f.params.mapIt(typeToCStr(it.typ)).join(", ")
    let ret = typeToCStr(f.retType)
    funcPtrTypes[f.name] = ret & " (*)(" & params & ")"
  for f in module.externFuncs:
    let params = f.params.mapIt(typeToCStr(it.typ)).join(", ")
    let ret = typeToCStr(f.retType)
    funcPtrTypes[f.name] = ret & " (*)(" & params & ")"

  # Header
  be.emitLine("/* Generated by Bux Compiler (LIR backend) */")
  be.emitLine("#include <stdio.h>")
  be.emitLine("#include <stdlib.h>")
  be.emitLine("#include <stdint.h>")
  be.emitLine("#include <stdbool.h>")
  be.emitLine("#include <string.h>")
  be.emitLine("")
  # Checked integer div/mod (rt/runtime*.c) — always available
  be.emitLine("extern int64_t bux_div_i64(int64_t a, int64_t b);")
  be.emitLine("extern int64_t bux_mod_i64(int64_t a, int64_t b);")
  be.emitLine("")

  # Forward struct declarations
  for s in module.structs:
    be.emitLine(&"typedef struct {s.name} {s.name};")
  if module.structs.len > 0:
    be.emitLine("")
  
  # Forward trait object declarations
  for iface in module.interfaces:
    if not iface.hasAssocTypes:
      be.emitLine(&"typedef struct {iface.name}_FatPtr {iface.name}_FatPtr;")
  if module.interfaces.len > 0:
    be.emitLine("")

  # Extern declarations
  if module.externFuncs.len > 0:
    be.emitLine("/* Extern function declarations */")
    for ef in module.externFuncs:
      let rt = typeToCStr(ef.retType)
      var params: seq[string] = @[]
      for p in ef.params:
        params.add(cParamDecl(typeToCStr(p.typ), p.name))
      if params.len == 0: params.add("void")
      be.emitLine(&"extern {rt} {ef.name}({params.join(\", \")});")
    be.emitLine("")

  # Constants as #define
  if module.consts.len > 0:
    be.emitLine("/* Constants */")
    for c in module.consts:
      if c.value != nil and c.value.kind == hLit:
        case c.value.litToken.kind
        of tkIntLiteral: be.emitLine(&"#define {c.name} {c.value.litToken.text}")
        of tkStringLiteral: be.emitLine(&"#define {c.name} \"{c.value.litToken.text}\"")
        of tkBoolLiteral: be.emitLine(&"#define {c.name} {c.value.litToken.text}")
        else: discard
    be.emitLine("")

  # Collect local type names (structs and enums defined in this module).
  var localTypeNames: HashSet[string]
  for s in module.structs:
    localTypeNames.incl(s.name)
  for e in module.enums:
    localTypeNames.incl(e.name)

  # Emit tuple typedefs early — enums/structs may embed them by value
  # (e.g. Box::Val((int,int)) → Tuple_int_int Val_0 in the union).
  var tupleTypes: seq[Type] = @[]
  var tupleNames: HashSet[string]
  proc registerTuple(t: Type) =
    if t == nil: return
    case t.kind
    of tkTuple:
      for e in t.inner:
        registerTuple(e)
      let name = typeToCStr(t)
      if not tupleNames.contains(name):
        tupleNames.incl(name)
        tupleTypes.add(t)
    of tkPointer, tkRef, tkMutRef, tkSlice:
      if t.inner.len > 0:
        registerTuple(t.inner[0])
    of tkFunc:
      for e in t.inner:
        registerTuple(e)
    else:
      discard

  proc walkHirForTuples(n: HirNode) =
    if n == nil: return
    registerTuple(n.typ)
    case n.kind
    of hAlloca:
      registerTuple(n.allocaType)
    of hBlock:
      for s in n.blockStmts: walkHirForTuples(s)
      walkHirForTuples(n.blockExpr)
    of hIf:
      walkHirForTuples(n.ifCond)
      walkHirForTuples(n.ifThen)
      walkHirForTuples(n.ifElse)
    of hWhile:
      walkHirForTuples(n.whileCond)
      walkHirForTuples(n.whileBody)
    of hLoop:
      walkHirForTuples(n.loopBody)
    of hReturn:
      walkHirForTuples(n.returnValue)
    of hStore:
      walkHirForTuples(n.storePtr)
      walkHirForTuples(n.storeValue)
    of hAssign:
      walkHirForTuples(n.assignTarget)
      walkHirForTuples(n.assignValue)
    of hBinary:
      walkHirForTuples(n.binaryLeft)
      walkHirForTuples(n.binaryRight)
    of hUnary:
      walkHirForTuples(n.unaryOperand)
    of hCall:
      for a in n.callArgs: walkHirForTuples(a)
    of hCallIndirect:
      walkHirForTuples(n.callIndirectCallee)
      for a in n.callIndirectArgs: walkHirForTuples(a)
    of hLoad:
      walkHirForTuples(n.loadPtr)
    of hFieldPtr:
      walkHirForTuples(n.fieldPtrBase)
    of hFieldAccess:
      walkHirForTuples(n.fieldAccessBase)
    of hStructInit:
      for f in n.structInitFields: walkHirForTuples(f.value)
    of hTupleInit:
      for e in n.tupleInitElements: walkHirForTuples(e)
    else:
      discard

  for f in module.funcs:
    registerTuple(f.retType)
    for p in f.params:
      registerTuple(p.typ)
    walkHirForTuples(f.body)
  for ef in module.externFuncs:
    registerTuple(ef.retType)
    for p in ef.params:
      registerTuple(p.typ)
  for s in module.structs:
    for f in s.fields:
      registerTuple(f.typ)
  for e in module.enums:
    for v in e.variants:
      for ft in v.fields:
        registerTuple(ft)
      for nf in v.namedFields:
        registerTuple(nf.typ)

  if tupleTypes.len > 0:
    be.emitLine("/* Tuple types */")
    for tt in tupleTypes:
      be.emitTupleDef(tt)

  # Collect slice types used in struct fields and enum payloads.
  var sliceTypes: seq[tuple[name: string, elem: string]] = @[]
  var sliceNames: HashSet[string]
  proc registerSlice(t: Type) =
    if t == nil or t.kind != tkSlice: return
    let name = typeToCStr(t)
    if sliceNames.contains(name): return
    sliceNames.incl(name)
    let elem = if t.inner.len > 0: typeToCStr(t.inner[0]) else: "void"
    sliceTypes.add((name, elem))

  for s in module.structs:
    for f in s.fields:
      registerSlice(f.typ)
  for e in module.enums:
    for v in e.variants:
      for ft in v.fields:
        registerSlice(ft)
      for nf in v.namedFields:
        registerSlice(nf.typ)

  # Build dependency graph among structs, enums, and slice types.
  # Edge A -> B means "A depends on B, so B must be emitted before A".
  var deps: Table[string, seq[string]]
  for s in module.structs:
    deps[s.name] = @[]
  for e in module.enums:
    deps[e.name] = @[]
  for st in sliceTypes:
    deps[st.name] = @[]

  proc addDeps(node: string, t: Type) =
    for dep in collectValueDeps(t):
      if dep == node: continue
      if localTypeNames.contains(dep) or sliceNames.contains(dep):
        if dep notin deps[node]:
          deps[node].add(dep)

  for s in module.structs:
    for f in s.fields:
      addDeps(s.name, f.typ)
  for e in module.enums:
    for v in e.variants:
      for ft in v.fields:
        addDeps(e.name, ft)
      for nf in v.namedFields:
        addDeps(e.name, nf.typ)
      # Multi-field / named-field nested struct must be defined before the enum
      if v.fields.len > 1 or v.namedFields.len > 0:
        addDeps(e.name, makeNamed(e.name & "_" & v.name & "_Payload"))

  # Topological sort (Kahn's algorithm).
  var inDegree: Table[string, int]
  var dependents: Table[string, seq[string]]
  for node in deps.keys:
    inDegree[node] = 0
  for node, nodeDeps in deps:
    for d in nodeDeps:
      if not inDegree.hasKey(d): inDegree[d] = 0
      inDegree[node] += 1
      dependents.mgetOrPut(d, @[]).add(node)

  var queue: seq[string] = @[]
  for node, deg in inDegree:
    if deg == 0:
      queue.add(node)

  var sorted: seq[string] = @[]
  while queue.len > 0:
    let node = queue.pop()
    sorted.add(node)
    for depNode in dependents.getOrDefault(node):
      inDegree[depNode] -= 1
      if inDegree[depNode] == 0:
        queue.add(depNode)

  if sorted.len < deps.len:
    # Cycle detected; fall back to a safe deterministic order.
    sorted = @[]
    for s in module.structs: sorted.add(s.name)
    for e in module.enums: sorted.add(e.name)
    for st in sliceTypes: sorted.add(st.name)

  # Map type names back to their definitions.
  var structMap: Table[string, seq[tuple[name: string, typ: Type]]]
  for s in module.structs: structMap[s.name] = s.fields
  var enumMap: Table[string, seq[HirEnumVariant]]
  for e in module.enums: enumMap[e.name] = e.variants
  var sliceMap: Table[string, string]
  for st in sliceTypes: sliceMap[st.name] = st.elem

  # Emit type definitions in dependency order.
  for name in sorted:
    if structMap.hasKey(name):
      be.emitStructDef(name, structMap[name])
    elif enumMap.hasKey(name):
      be.emitEnumDef(name, enumMap[name])
    elif sliceMap.hasKey(name):
      be.emitSliceTypeDef(name, sliceMap[name])

  # Fat function-pointer typedefs (BuxFn_*) — before forward decls that use them
  var fatTypes: seq[Type] = @[]
  var fatNames: HashSet[string]
  proc registerFat(t: Type) =
    if t == nil: return
    case t.kind
    of tkFunc:
      for e in t.inner: registerFat(e)
      let n = funcFatTypeName(t)
      if not fatNames.contains(n):
        fatNames.incl(n)
        fatTypes.add(t)
    of tkPointer, tkRef, tkMutRef, tkSlice:
      if t.inner.len > 0: registerFat(t.inner[0])
    of tkTuple:
      for e in t.inner: registerFat(e)
    else: discard
  for f in module.funcs:
    registerFat(f.retType)
    for p in f.params: registerFat(p.typ)
  for ef in module.externFuncs:
    registerFat(ef.retType)
    for p in ef.params: registerFat(p.typ)
  for a in module.funcAdapters:
    registerFat(a.typ)
  for t in module.seenFatTypes:
    registerFat(t)
  if fatTypes.len > 0:
    be.emitLine("/* Fat function pointer types (code + env) */")
    for ft in fatTypes:
      let n = funcFatTypeName(ft)
      let codeT = funcCodePtrType(ft)
      be.emitLine(&"typedef struct {n} {{")
      be.indent += 1
      be.emitLine(cParamDecl(codeT, "code") & ";")
      be.emitLine("void* env;")
      be.indent -= 1
      be.emitLine(&"}} {n};")
      be.emitLine("")

  # Env structs for closures with captures (heap-allocated per value)
  for f in module.funcs:
    if f.captureNames.len > 0 and f.envStructName != "":
      be.emitLine(&"typedef struct {f.envStructName} {{")
      be.indent += 1
      for i in 0 ..< f.captureNames.len:
        let capName = f.captureNames[i]
        let capType = if i < f.captureTypes.len: typeToCStr(f.captureTypes[i]) else: "int"
        be.emitLine(&"{capType} {capName};")
      be.indent -= 1
      be.emitLine(&"}} {f.envStructName};")
      be.emitLine("")

  # Forward function declarations
  for f in module.funcs:
    let rt = typeToCStr(f.retType)
    var params: seq[string] = @[]
    for p in f.params:
      params.add(cParamDecl(typeToCStr(p.typ), p.name))
    if params.len == 0: params.add("void")
    be.emitLine(&"{rt} {f.name}({params.join(\", \")});")
  be.emitLine("")

  # VTable and fat pointer structs
  for iface in module.interfaces:
    if iface.hasAssocTypes: continue
    let iname = iface.name
    be.emitLine(&"typedef struct {iname}_VTable {{")
    be.indent += 1
    for m in iface.methods:
      var paramCTypes: seq[string] = @["void* self"]
      for i in 1 ..< m.params.len:
        paramCTypes.add(cParamDecl(typeToCStr(m.params[i]), "param"))
      let rt = typeToCStr(m.ret)
      be.emitLine(&"{rt} (*{m.name})({paramCTypes.join(\", \")});")
    be.indent -= 1
    be.emitLine(&"}} {iname}_VTable;")
    be.emitLine(&"typedef struct {iname}_FatPtr {{")
    be.indent += 1
    be.emitLine("void* data;")
    be.emitLine(&"{iname}_VTable* vtable;")
    be.indent -= 1
    be.emitLine(&"}} {iname}_FatPtr;")
    be.emitLine("")

  # VTable instances
  for vt in module.vtables:
    if vt.hasAssocTypes: continue
    let varName = vt.concreteType & "_" & vt.interfaceName & "_VTable"
    be.emitLine(&"{vt.interfaceName}_VTable {varName} = {{")
    be.indent += 1
    for m in vt.methodNames:
      be.emitLine(&".{m} = (void*){vt.concreteType}_{m},")
    be.indent -= 1
    be.emitLine("};")
    be.emitLine("")

  # Adapters for named functions used as fat-func values (after forward decls)
  if module.funcAdapters.len > 0:
    be.emitLine("/* Fat-func adapters for named functions */")
    for a in module.funcAdapters:
      let ret = if a.typ.inner.len > 0: typeToCStr(a.typ.inner[^1]) else: "void"
      var params: seq[string] = @["void* env"]
      var argNames: seq[string] = @[]
      if a.typ.inner.len > 1:
        for i, p in a.typ.inner[0 ..^ 2]:
          let pn = "a" & $i
          params.add(typeToCStr(p) & " " & pn)
          argNames.add(pn)
      let argsStr = argNames.join(", ")
      be.emitLine(&"static {ret} __adapt_{a.name}({params.join(\", \")}) {{")
      be.indent += 1
      be.emitLine("(void)env;")
      if ret == "void":
        be.emitLine(&"{a.name}({argsStr});")
      else:
        be.emitLine(&"return {a.name}({argsStr});")
      be.indent -= 1
      be.emitLine("}")
      be.emitLine("")

  # Emit all LIR functions
  for f in builder.funcs:
    be.emitFunc(f, funcRetTypes, funcPtrTypes)

  # C main wrapper
  var hasMain = false
  for f in module.funcs:
    if f.name == "Main":
      hasMain = true
      break
  if hasMain:
    be.emitLine("/* C entry point wrapper */")
    be.emitLine("extern int g_argc;")
    be.emitLine("extern char** g_argv;")
    be.emitLine("int main(int argc, char** argv) {")
    be.emitLine("    g_argc = argc;")
    be.emitLine("    g_argv = argv;")
    be.emitLine("    return Main();")
    be.emitLine("}")

  return be.output
