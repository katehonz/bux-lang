import std/[strformat, strutils, tables]
import hir, types, token, source_location

type
  CBackend* = object
    output*: string
    indent*: int
    varCounter*: int
    declaredVars*: seq[string]

proc initCBackend*(): CBackend =
  result.output = ""
  result.indent = 0
  result.varCounter = 0
  result.declaredVars = @[]

proc emit(be: var CBackend, s: string) =
  be.output.add(s)

proc emitLine(be: var CBackend, s: string) =
  for i in 0..<be.indent:
    be.output.add("    ")
  be.output.add(s)
  be.output.add("\n")

proc emitIndent(be: var CBackend) =
  for i in 0..<be.indent:
    be.output.add("    ")

proc freshVar(be: var CBackend): string =
  inc be.varCounter
  result = &"__tmp_{be.varCounter}"

# Type conversion: Bux Type → C type string
proc typeToC*(typ: Type): string =
  if typ == nil: return "void"
  case typ.kind
  of tkVoid: return "void"
  of tkBool: return "bool"
  of tkBool8: return "bool"
  of tkBool16: return "bool"
  of tkBool32: return "bool"
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
      return typeToC(typ.inner[0]) & "*"
    return "void*"
  of tkSlice:
    if typ.inner.len > 0:
      return typeToC(typ.inner[0]) & "*"
    return "void*"
  of tkNamed:
    # Map common Bux type names to C types
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
  of tkTuple: return "void*"  # TODO: proper tuple struct
  of tkFunc: return "void*"  # TODO: function pointer
  else: return "int"

proc operatorToC(op: TokenKind): string =
  case op
  of tkPlus: return "+"
  of tkMinus: return "-"
  of tkStar: return "*"
  of tkSlash: return "/"
  of tkPercent: return "%"
  of tkAmp: return "&"
  of tkPipe: return "|"
  of tkCaret: return "^"
  of tkShl: return "<<"
  of tkShr: return ">>"
  of tkAmpAmp: return "&&"
  of tkPipePipe: return "||"
  of tkEq: return "=="
  of tkNe: return "!="
  of tkLt: return "<"
  of tkLe: return "<="
  of tkGt: return ">"
  of tkGe: return ">="
  of tkBang: return "!"
  of tkTilde: return "~"
  of tkPlusPlus: return "++"
  of tkMinusMinus: return "--"
  of tkAssign: return "="
  of tkPlusAssign: return "+="
  of tkMinusAssign: return "-="
  of tkStarAssign: return "*="
  of tkSlashAssign: return "/="
  of tkPercentAssign: return "%="
  of tkAmpAssign: return "&="
  of tkPipeAssign: return "|="
  of tkCaretAssign: return "^="
  of tkShlAssign: return "<<="
  of tkShrAssign: return ">>="
  else: return "?"

# Forward declaration
proc emitExpr(be: var CBackend, node: HirNode): string
proc emitStmt(be: var CBackend, node: HirNode)

proc emitExpr(be: var CBackend, node: HirNode): string =
  if node == nil: return "0"
  case node.kind
  of hLit:
    case node.litToken.kind
    of tkBoolLiteral:
      if node.litToken.text == "true": return "true"
      else: return "false"
    of tkStringLiteral:
      var text = node.litToken.text
      # Strip c8" c16" c32" prefixes — in C they are just regular string literals
      if text.startsWith("c32\""):
        text = text[3..^1]
      elif text.startsWith("c16\""):
        text = text[3..^1]
      elif text.startsWith("c8\""):
        text = text[2..^1]
      return text
    of tkNull:
      return "NULL"
    else:
      return node.litToken.text

  of hVar:
    return node.varName

  of hSelf:
    return "self"

  of hUnary:
    let operand = be.emitExpr(node.unaryOperand)
    let op = operatorToC(node.unaryOp)
    if node.unaryOp == tkStar:
      return &"(*{operand})"
    elif node.unaryOp == tkAmp:
      return &"(&{operand})"
    else:
      return &"({op}{operand})"

  of hBinary:
    let left = be.emitExpr(node.binaryLeft)
    let right = be.emitExpr(node.binaryRight)
    let op = operatorToC(node.binaryOp)
    return &"({left} {op} {right})"

  of hCall:
    var args: seq[string] = @[]
    for arg in node.callArgs:
      args.add(be.emitExpr(arg))
    let argsStr = args.join(", ")
    return &"{node.callCallee}({argsStr})"

  of hCallIndirect:
    let callee = be.emitExpr(node.callIndirectCallee)
    var args: seq[string] = @[]
    for arg in node.callIndirectArgs:
      args.add(be.emitExpr(arg))
    let argsStr = args.join(", ")
    return &"({callee})({argsStr})"

  of hLoad:
    # Optimize: load(field_ptr(base, field)) → base.field (avoids & on temporaries)
    if node.loadPtr != nil and node.loadPtr.kind == hFieldPtr:
      let base = be.emitExpr(node.loadPtr.fieldPtrBase)
      return &"({base}.{node.loadPtr.fieldName})"
    # Optimize: load(arrow_field(base, field)) → base->field
    if node.loadPtr != nil and node.loadPtr.kind == hArrowField:
      let base = be.emitExpr(node.loadPtr.arrowFieldBase)
      return &"({base}->{node.loadPtr.arrowFieldName})"
    # Optimize: load(index_ptr(base, idx)) → base[idx]
    if node.loadPtr != nil and node.loadPtr.kind == hIndexPtr:
      let base = be.emitExpr(node.loadPtr.indexPtrBase)
      let idx = be.emitExpr(node.loadPtr.indexPtrIndex)
      return &"({base}[{idx}])"
    let ptrExpr = be.emitExpr(node.loadPtr)
    return &"(*{ptrExpr})"

  of hFieldPtr:
    let base = be.emitExpr(node.fieldPtrBase)
    return &"(&({base}.{node.fieldName}))"

  of hArrowField:
    let base = be.emitExpr(node.arrowFieldBase)
    return &"(&({base}->{node.arrowFieldName}))"

  of hIndexPtr:
    let base = be.emitExpr(node.indexPtrBase)
    let idx = be.emitExpr(node.indexPtrIndex)
    return &"(&({base}[{idx}]))"

  of hStructInit:
    # C99 compound literal: (StructName){.field1 = val1, .field2 = val2}
    var fields: seq[string] = @[]
    for f in node.structInitFields:
      let val = be.emitExpr(f.value)
      fields.add(&".{f.name} = {val}")
    let fieldsStr = fields.join(", ")
    return &"(({node.structInitName}){{{fieldsStr}}})"

  of hSliceInit:
    # For now, use a static array
    var elems: seq[string] = @[]
    for e in node.sliceInitElements:
      elems.add(be.emitExpr(e))
    let elemsStr = elems.join(", ")
    return &"{{{elemsStr}}}"

  of hTupleInit:
    var elems: seq[string] = @[]
    for e in node.tupleInitElements:
      elems.add(be.emitExpr(e))
    return &"{{{elems.join(\", \")}}}"

  of hCast:
    let operand = be.emitExpr(node.castOperand)
    let typ = typeToC(node.castType)
    return &"(({typ}){operand})"

  of hIs:
    return "true"  # TODO: proper type checking

  of hSizeOf:
    let typ = typeToC(node.sizeOfType)
    return &"sizeof({typ})"

  of hIf:
    # Ternary expression
    let cond = be.emitExpr(node.ifCond)
    let thenE = be.emitExpr(node.ifThen)
    let elseE = be.emitExpr(node.ifElse)
    return &"({cond} ? {thenE} : {elseE})"

  of hAssign:
    let target = be.emitExpr(node.assignTarget)
    let value = be.emitExpr(node.assignValue)
    let op = operatorToC(node.assignOp)
    return &"({target} {op} {value})"

  of hBlock:
    # For block expressions, just emit the last expression
    if node.blockExpr != nil:
      return be.emitExpr(node.blockExpr)
    elif node.blockStmts.len > 0:
      return be.emitExpr(node.blockStmts[^1])
    return "0"

  of hMatch:
    return "0"  # TODO: match expression lowering

  else:
    return "0"

proc emitStmt(be: var CBackend, node: HirNode) =
  if node == nil: return
  case node.kind
  of hReturn:
    if node.returnValue != nil:
      let val = be.emitExpr(node.returnValue)
      be.emitLine(&"return {val};")
    else:
      be.emitLine("return;")

  of hIf:
    let cond = be.emitExpr(node.ifCond)
    be.emitLine(&"if ({cond}) {{")
    inc be.indent
    be.emitStmt(node.ifThen)
    dec be.indent
    if node.ifElse != nil:
      be.emitLine("} else {")
      inc be.indent
      be.emitStmt(node.ifElse)
      dec be.indent
    be.emitLine("}")

  of hWhile:
    let cond = be.emitExpr(node.whileCond)
    be.emitLine(&"while ({cond}) {{")
    inc be.indent
    be.emitStmt(node.whileBody)
    dec be.indent
    be.emitLine("}")

  of hLoop:
    be.emitLine("while (1) {")
    inc be.indent
    be.emitStmt(node.loopBody)
    dec be.indent
    be.emitLine("}")

  of hBreak:
    be.emitLine("break;")

  of hContinue:
    be.emitLine("continue;")

  of hBlock:
    if node.isScope:
      be.emitLine("{")
      inc be.indent
    for stmt in node.blockStmts:
      be.emitStmt(stmt)
    if node.blockExpr != nil:
      let val = be.emitExpr(node.blockExpr)
      be.emitLine(&"{val};")
    if node.isScope:
      dec be.indent
      be.emitLine("}")

  of hAlloca:
    let typ = typeToC(node.allocaType)
    be.emitLine(&"{typ} {node.allocaName};")

  of hStore:
    let ptrExpr = be.emitExpr(node.storePtr)
    let val = be.emitExpr(node.storeValue)
    be.emitLine(&"{ptrExpr} = {val};")

  of hAssign:
    let target = be.emitExpr(node.assignTarget)
    let value = be.emitExpr(node.assignValue)
    let op = operatorToC(node.assignOp)
    be.emitLine(&"{target} {op} {value};")

  of hCall:
    let expr = be.emitExpr(node)
    be.emitLine(&"{expr};")

  of hCallIndirect:
    let expr = be.emitExpr(node)
    be.emitLine(&"{expr};")

  else:
    # Expression statement
    let expr = be.emitExpr(node)
    be.emitLine(&"{expr};")

proc emitFunc*(be: var CBackend, hfunc: HirFunc) =
  let retType = typeToC(hfunc.retType)
  var params: seq[string] = @[]
  for p in hfunc.params:
    params.add(&"{typeToC(p.typ)} {p.name}")
  if params.len == 0:
    params.add("void")
  let paramsStr = params.join(", ")
  be.emitLine(&"{retType} {hfunc.name}({paramsStr}) {{")
  inc be.indent
  if hfunc.body != nil:
    if hfunc.body.kind == hBlock:
      for stmt in hfunc.body.blockStmts:
        be.emitStmt(stmt)
      if hfunc.body.blockExpr != nil and hfunc.retType.kind != tkVoid:
        let val = be.emitExpr(hfunc.body.blockExpr)
        be.emitLine(&"return {val};")
    else:
      be.emitStmt(hfunc.body)
  dec be.indent
  be.emitLine("}")
  be.emitLine("")

proc emitStruct*(be: var CBackend, name: string, fields: seq[tuple[name: string, typ: Type]]) =
  be.emitLine(&"typedef struct {name} {{")
  inc be.indent
  for f in fields:
    let typ = typeToC(f.typ)
    be.emitLine(&"{typ} {f.name};")
  dec be.indent
  be.emitLine(&"}} {name};")
  be.emitLine("")

proc emitEnum*(be: var CBackend, name: string, variants: seq[HirEnumVariant]) =
  # Check if this is a simple enum (no data) or algebraic enum (with data)
  var hasData = false
  for v in variants:
    if v.fields.len > 0 or v.namedFields.len > 0:
      hasData = true
      break
  
  if not hasData:
    # Simple enum - generate as before
    be.emitLine(&"typedef enum {{")
    inc be.indent
    for i, v in variants:
      if i < variants.len - 1:
        be.emitLine(&"{name}_{v.name},")
      else:
        be.emitLine(&"{name}_{v.name}")
    dec be.indent
    be.emitLine(&"}} {name};")
    be.emitLine("")
  else:
    # Algebraic enum - generate tagged union
    # 1. Generate tag enum
    be.emitLine(&"typedef enum {{")
    inc be.indent
    for i, v in variants:
      if i < variants.len - 1:
        be.emitLine(&"{name}_{v.name},")
      else:
        be.emitLine(&"{name}_{v.name}")
    dec be.indent
    be.emitLine(&"}} {name}_Tag;")
    be.emitLine("")
    
    # 2. Generate union for data
    be.emitLine(&"typedef union {{")
    inc be.indent
    for v in variants:
      if v.fields.len > 0:
        # Positional fields
        for i, f in v.fields:
          let typ = typeToC(f)
          be.emitLine(&"{typ} {v.name}_{i};")
      elif v.namedFields.len > 0:
        # Named fields - generate as struct
        be.emitLine(&"struct {{")
        inc be.indent
        for nf in v.namedFields:
          let typ = typeToC(nf.typ)
          be.emitLine(&"{typ} {nf.name};")
        dec be.indent
        be.emitLine(&"}} {v.name};")
    dec be.indent
    be.emitLine(&"}} {name}_Data;")
    be.emitLine("")
    
    # 3. Generate main struct with tag + union
    be.emitLine(&"typedef struct {{")
    inc be.indent
    be.emitLine(&"{name}_Tag tag;")
    be.emitLine(&"{name}_Data data;")
    dec be.indent
    be.emitLine(&"}} {name};")
    be.emitLine("")

proc emitExternDecl*(be: var CBackend, efunc: HirFunc) =
  let retType = typeToC(efunc.retType)
  var params: seq[string] = @[]
  for p in efunc.params:
    params.add(&"{typeToC(p.typ)} {p.name}")
  if params.len == 0:
    params.add("void")
  let paramsStr = params.join(", ")
  be.emitLine(&"extern {retType} {efunc.name}({paramsStr});")

proc emitModule*(be: var CBackend, module: HirModule): string =
  # Header
  be.emitLine("/* Generated by Bux Compiler */")
  be.emitLine("#include <stdio.h>")
  be.emitLine("#include <stdlib.h>")
  be.emitLine("#include <stdint.h>")
  be.emitLine("#include <stdbool.h>")
  be.emitLine("#include <string.h>")
  be.emitLine("")

  # Forward declarations
  for s in module.structs:
    be.emitLine(&"typedef struct {s.name} {s.name};")
  if module.structs.len > 0:
    be.emitLine("")

  # Extern function declarations
  if module.externFuncs.len > 0:
    be.emitLine("/* Extern function declarations */")
    for ef in module.externFuncs:
      be.emitExternDecl(ef)
    be.emitLine("")

  # Const declarations as #define
  if module.consts.len > 0:
    be.emitLine("/* Constants */")
    for c in module.consts:
      let val = c.value
      if val != nil and val.kind == hLit:
        let tok = val.litToken
        case tok.kind
        of tkIntLiteral:
          be.emitLine(&"#define {c.name} {tok.text}")
        of tkStringLiteral:
          be.emitLine(&"#define {c.name} \"{tok.text}\"")
        of tkBoolLiteral:
          be.emitLine(&"#define {c.name} {tok.text}")
        else:
          be.emitLine(&"/* const {c.name} (unsupported literal kind) */")
      else:
        be.emitLine(&"/* const {c.name} (complex expression) */")
    be.emitLine("")

  # Struct definitions
  for s in module.structs:
    be.emitStruct(s.name, s.fields)

  # Enum definitions
  for e in module.enums:
    be.emitEnum(e.name, e.variants)

  # Forward declarations for all functions
  for f in module.funcs:
    let retType = typeToC(f.retType)
    var params: seq[string] = @[]
    for p in f.params:
      params.add(typeToC(p.typ) & " " & p.name)
    if params.len == 0:
      params.add("void")
    be.emitLine(retType & " " & f.name & "(" & params.join(", ") & ");")
  be.emitLine("")

  # Function definitions
  var hasMain = false
  for f in module.funcs:
    be.emitFunc(f)
    if f.name == "Main":
      hasMain = true

  # Generate C main wrapper if Bux Main exists
  if hasMain:
    be.emitLine("/* C entry point wrapper */")
    be.emitLine("extern int g_argc;")
    be.emitLine("extern char** g_argv;")
    be.emitLine("int main(int argc, char** argv) {")
    be.emitLine("    g_argc = argc;")
    be.emitLine("    g_argv = argv;")
    be.emitLine("    return Main();")
    be.emitLine("}")
    be.emitLine("")

  return be.output
