## LIR → C Backend
## Emits clean, well-structured C code from LIR instructions.
## Since LIR is already linear and low-level, C emission is straightforward.

import std/[strutils, strformat, tables, sequtils]
import lir, hir, types, token

type
  LirCBackend* = object
    output*: string
    indent*: int
    tempTypes*: Table[string, string]  ## Track C types of temp variables

proc initLirCBackend*(): LirCBackend =
  result = LirCBackend(
    indent: 0,
    tempTypes: initTable[string, string](),
  )

proc emit(be: var LirCBackend, s: string) =
  be.output.add(s)

proc emitIndent(be: var LirCBackend) =
  for i in 0 ..< be.indent:
    be.output.add("    ")

proc emitLine(be: var LirCBackend, s: string) =
  be.emitIndent()
  be.output.add(s)
  be.output.add("\n")

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

proc typeFromValue(be: var LirCBackend, v: LirValue): string =
  ## Infer a C type for a value. Temps are tracked; named vars use lookup.
  case v.kind
  of lvkTemp:
    if be.tempTypes.hasKey(v.strVal):
      return be.tempTypes[v.strVal]
    return "int"  # Default
  of lvkString: return "const char*"
  of lvkInt: return "int"
  of lvkFloat: return "double"
  else: return ""

proc setTempType(be: var LirCBackend, temp: string, cType: string) =
  be.tempTypes[temp] = cType

# ── Per-instruction emission ──

proc emitInstr(be: var LirCBackend, instr: LirInstr) =
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
  of lirAdd, lirSub, lirMul, lirDiv, lirMod,
     lirAnd, lirOr, lirXor, lirShl, lirShr:
    let op = case instr.kind
      of lirAdd: "+"
      of lirSub: "-"
      of lirMul: "*"
      of lirDiv: "/"
      of lirMod: "%"
      of lirAnd: "&"
      of lirOr: "|"
      of lirXor: "^"
      of lirShl: "<<"
      of lirShr: ">>"
      else: "?"
    be.emitLine(&"{v(instr.dst)} = {v(instr.src)} {op} {v(instr.src2)};")

  of lirNeg:
    be.emitLine(&"{v(instr.dst)} = -{v(instr.src)};")
  of lirNot:
    be.emitLine(&"{v(instr.dst)} = !{v(instr.src)};")
  of lirBNot:
    be.emitLine(&"{v(instr.dst)} = ~{v(instr.src)};")

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
    var argsStr = ""
    for i, arg in instr.extra:
      if i > 0: argsStr.add(", ")
      argsStr.add(v(arg))
    if instr.dst.kind != lvkVoid:
      be.emitLine(&"{v(instr.dst)} = ({v(instr.src)})({argsStr});")
    else:
      be.emitLine(&"({v(instr.src)})({argsStr});")

  # ── Return ──
  of lirRet:
    if instr.src.kind != lvkVoid:
      be.emitLine(&"return {v(instr.src)};")
    else:
      be.emitLine("return;")

  # ── Alloca ──
  of lirAlloca:
    be.emitLine(&"{v(instr.src)} {v(instr.dst)};")

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

proc emitFunc(be: var LirCBackend, f: LirFunc) =
  var paramsStr = ""
  for i, p in f.params:
    if i > 0: paramsStr.add(", ")
    paramsStr.add(&"{p.cType} {p.name}")
  if f.params.len == 0:
    paramsStr = "void"

  be.emitLine(&"{f.retType} {f.name}({paramsStr}) {{")
  be.indent += 1

  # First pass: declare all temp variables at the top of the function
  var tempsSeen: seq[tuple[name: string, cType: string]] = @[]
  var tempsSet: seq[string] = @[]
  for instr in f.instrs:
    # Allocas are explicit declarations — mark name as declared, skip emission here
    if instr.kind == lirAlloca:
      if instr.dst.strVal.len > 0 and instr.dst.strVal notin tempsSet:
        tempsSet.add(instr.dst.strVal)
      continue
    # Temps that are destinations of binary ops, calls, etc.
    if instr.dst.kind == lvkTemp and instr.dst.strVal.len > 0 and instr.dst.strVal notin tempsSet:
      # Infer type based on instruction kind
      var ct = "int"
      case instr.kind
      of lirMov, lirLoad, lirLoadGlobal:
        ct = "int"
      of lirAdd, lirSub, lirMul, lirDiv, lirMod, lirNeg,
         lirCmpEq, lirCmpNe, lirCmpLt, lirCmpLe, lirCmpGt, lirCmpGe:
        ct = "int"
      of lirAnd, lirOr, lirXor, lirShl, lirShr, lirNot, lirBNot:
        ct = "int"
      of lirCall, lirCallIndirect:
        ct = "int"  # Conservative
      of lirAddrOf, lirFieldPtr, lirArrowFieldPtr, lirIndexPtr, lirPtrAdd:
        ct = "void*"
      of lirStructInit, lirSliceInit:
        ct = "int"  # Will be overwritten by the actual type in emit
      of lirCast:
        ct = valToC(be, instr.src2)
      of lirSelect:
        ct = "int"
      else:
        ct = "int"
      tempsSeen.add((instr.dst.strVal, ct))
      tempsSet.add(instr.dst.strVal)
      be.tempTypes[instr.dst.strVal] = ct

  # Declare all temps
  for t in tempsSeen:
    # Skip if the type is a struct type (will be declared inline)
    if t.cType == "int" or t.cType == "void*" or t.cType == "double":
      be.emitLine(&"{t.cType} {t.name};")

  # Emit instructions in order
  for instr in f.instrs:
    be.emitInstr(instr)

  be.indent -= 1
  be.emitLine("}")
  be.emitLine("")

# ── Struct/Enum emission (from HIR module) ──

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
  else: return "int"

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
      if v.fields.len > 0:
        for i, f in v.fields:
          be.emitLine(&"{typeToCStr(f)} {v.name}_{i};")
      elif v.namedFields.len > 0:
        be.emitLine(&"struct {{")
        be.indent += 1
        for nf in v.namedFields:
          be.emitLine(&"{typeToCStr(nf.typ)} {nf.name};")
        be.indent -= 1
        be.emitLine(&"}} {v.name};")
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

# ── Module emission ──

proc emitModule*(be: var LirCBackend, builder: LirBuilder, module: HirModule): string =
  ## Emit full C source from LIR builder + HIR module metadata.
  be.output = ""

  # Header
  be.emitLine("/* Generated by Bux Compiler (LIR backend) */")
  be.emitLine("#include <stdio.h>")
  be.emitLine("#include <stdlib.h>")
  be.emitLine("#include <stdint.h>")
  be.emitLine("#include <stdbool.h>")
  be.emitLine("#include <string.h>")
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
        params.add(&"{typeToCStr(p.typ)} {p.name}")
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

  # Enum definitions
  for e in module.enums:
    be.emitEnumDef(e.name, e.variants)
  if module.enums.len > 0:
    be.emitLine("")

  # Struct definitions
  for s in module.structs:
    be.emitStructDef(s.name, s.fields)

  # Slice types (collect from functions/structs)
  # Simple: scan function params/returns for slice types
  var sliceTypes: seq[tuple[name: string, elem: string]] = @[]
  for f in module.funcs:
    for p in f.params:
      let ct = typeToCStr(p.typ)
      if ct.startsWith("Slice_"):
        let elem = ct[6 .. ^1]
        if not sliceTypes.anyIt(it.name == ct):
          sliceTypes.add((ct, elem))
  if sliceTypes.len > 0:
    for st in sliceTypes:
      be.emitLine(&"typedef struct {{ {st.elem}* data; size_t len; }} {st.name};")
    be.emitLine("")

  # Forward function declarations
  for f in module.funcs:
    let rt = typeToCStr(f.retType)
    var params: seq[string] = @[]
    for p in f.params:
      params.add(&"{typeToCStr(p.typ)} {p.name}")
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
        paramCTypes.add(typeToCStr(m.params[i]) & " param")
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

  # Emit all LIR functions
  for f in builder.funcs:
    be.emitFunc(f)

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
