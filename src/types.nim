import std/[sequtils, strformat, strutils]

type
  TypeKind* = enum
    tkUnknown
    tkVoid
    tkBool
    tkBool8
    tkBool16
    tkBool32
    tkChar8
    tkChar16
    tkChar32
    tkStr
    tkInt8
    tkInt16
    tkInt32
    tkInt64
    tkInt
    tkUInt8
    tkUInt16
    tkUInt32
    tkUInt64
    tkUInt
    tkFloat32
    tkFloat64
    tkPointer
    tkSlice
    tkRange
    tkTuple
    tkNamed
    tkTypeParam
    tkFunc

  Type* = ref object
    kind*: TypeKind
    name*: string
    inner*: seq[Type]       ## for Pointer(pointee), Slice(element), Tuple(elements), Func(params+ret)

# Factories
proc makeUnknown*(): Type = Type(kind: tkUnknown)
proc makeVoid*(): Type = Type(kind: tkVoid)
proc makeBool*(): Type = Type(kind: tkBool)
proc makeBool8*(): Type = Type(kind: tkBool8)
proc makeBool16*(): Type = Type(kind: tkBool16)
proc makeBool32*(): Type = Type(kind: tkBool32)
proc makeChar8*(): Type = Type(kind: tkChar8)
proc makeChar16*(): Type = Type(kind: tkChar16)
proc makeChar32*(): Type = Type(kind: tkChar32)
proc makeStr*(): Type = Type(kind: tkStr)
proc makeInt8*(): Type = Type(kind: tkInt8)
proc makeInt16*(): Type = Type(kind: tkInt16)
proc makeInt32*(): Type = Type(kind: tkInt32)
proc makeInt64*(): Type = Type(kind: tkInt64)
proc makeInt*(): Type = Type(kind: tkInt)
proc makeUInt8*(): Type = Type(kind: tkUInt8)
proc makeUInt16*(): Type = Type(kind: tkUInt16)
proc makeUInt32*(): Type = Type(kind: tkUInt32)
proc makeUInt64*(): Type = Type(kind: tkUInt64)
proc makeUInt*(): Type = Type(kind: tkUInt)
proc makeFloat32*(): Type = Type(kind: tkFloat32)
proc makeFloat64*(): Type = Type(kind: tkFloat64)

proc makePointer*(pointee: Type): Type =
  Type(kind: tkPointer, inner: @[pointee])
proc makeSlice*(element: Type): Type =
  Type(kind: tkSlice, inner: @[element])
proc makeRange*(element: Type): Type =
  Type(kind: tkRange, inner: @[element])
proc makeTuple*(elems: seq[Type]): Type =
  Type(kind: tkTuple, inner: elems)
proc makeNamed*(name: string): Type =
  Type(kind: tkNamed, name: name)
proc makeTypeParam*(name: string): Type =
  Type(kind: tkTypeParam, name: name)
proc makeFunc*(params: seq[Type], ret: Type): Type =
  Type(kind: tkFunc, inner: params & @[ret])

# Predicates
proc isUnknown*(t: Type): bool = t.kind == tkUnknown
proc isVoid*(t: Type): bool = t.kind == tkVoid
proc isBool*(t: Type): bool = t.kind in {tkBool, tkBool8, tkBool16, tkBool32}
proc isNumeric*(t: Type): bool =
  if t.kind in {tkUnknown, tkNamed, tkTypeParam}: return true
  t.kind in {tkInt8, tkInt16, tkInt32, tkInt64, tkInt,
             tkUInt8, tkUInt16, tkUInt32, tkUInt64, tkUInt,
             tkFloat32, tkFloat64}
proc isInteger*(t: Type): bool =
  if t.kind in {tkUnknown, tkNamed, tkTypeParam}: return true
  t.kind in {tkInt8, tkInt16, tkInt32, tkInt64, tkInt,
             tkUInt8, tkUInt16, tkUInt32, tkUInt64, tkUInt}
proc isFloat*(t: Type): bool =
  if t.kind in {tkUnknown, tkNamed, tkTypeParam}: return true
  t.kind in {tkFloat32, tkFloat64}
proc isSigned*(t: Type): bool =
  if t.kind in {tkUnknown, tkNamed, tkTypeParam}: return true
  t.kind in {tkInt8, tkInt16, tkInt32, tkInt64, tkInt}
proc isPointer*(t: Type): bool = t.kind == tkPointer
proc isSlice*(t: Type): bool = t.kind == tkSlice

# Comparison
proc `==`*(a, b: Type): bool =
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  if a.kind != b.kind: return false
  if a.kind in {tkNamed, tkTypeParam} and a.name != b.name: return false
  if a.inner.len != b.inner.len: return false
  for i in 0 ..< a.inner.len:
    if a.inner[i] != b.inner[i]: return false
  return true

proc `!=`*(a, b: Type): bool = not (a == b)

# Assignment compatibility
proc isAssignableTo*(a, b: Type): bool =
  if a.isUnknown or b.isUnknown: return true
  if b.kind == tkTypeParam: return true
  if a == b: return true
  # float32 -> float64
  if a.kind == tkFloat32 and b.kind == tkFloat64: return true
  # int64 <-> int (on x64)
  if a.kind == tkInt64 and b.kind == tkInt: return true
  if a.kind == tkInt and b.kind == tkInt64: return true
  if a.kind == tkUInt64 and b.kind == tkUInt: return true
  if a.kind == tkUInt and b.kind == tkUInt64: return true
  # smaller int -> int/uint
  if b.kind == tkInt and a.kind in {tkInt8, tkInt16, tkInt32}: return true
  if b.kind == tkUInt and a.kind in {tkUInt8, tkUInt16, tkUInt32}: return true
  # int <-> uint (for convenience in bootstrap)
  if a.kind == tkInt and b.kind == tkUInt: return true
  if a.kind == tkUInt and b.kind == tkInt: return true
  # numeric exact match required otherwise
  if a.isNumeric and b.isNumeric: return false
  # bool across widths
  if a.isBool and b.isBool: return true
  # pointer to opaque / null pointer
  if a.isPointer and b.isPointer:
    if a.inner.len > 0 and a.inner[0].isUnknown:
      return true
    if b.inner.len > 0 and b.inner[0].isUnknown:
      return true
  return false

# String representation
proc toString*(t: Type): string =
  case t.kind
  of tkUnknown: "?"
  of tkVoid: "void"
  of tkBool: "bool"
  of tkBool8: "bool8"
  of tkBool16: "bool16"
  of tkBool32: "bool32"
  of tkChar8: "char8"
  of tkChar16: "char16"
  of tkChar32: "char32"
  of tkStr: "String"
  of tkInt8: "int8"
  of tkInt16: "int16"
  of tkInt32: "int32"
  of tkInt64: "int64"
  of tkInt: "int"
  of tkUInt8: "uint8"
  of tkUInt16: "uint16"
  of tkUInt32: "uint32"
  of tkUInt64: "uint64"
  of tkUInt: "uint"
  of tkFloat32: "float32"
  of tkFloat64: "float64"
  of tkPointer: "*" & t.inner[0].toString
  of tkSlice:
    if t.inner.len > 0: t.inner[0].toString & "[]"
    else: "Slice<?>"
  of tkRange:
    if t.inner.len > 0: "Range<" & t.inner[0].toString & ">"
    else: "Range<?>"
  of tkTuple:
    "(" & t.inner.mapIt(it.toString).join(", ") & ")"
  of tkNamed: t.name
  of tkTypeParam: t.name
  of tkFunc:
    if t.inner.len == 0: "func()"
    else:
      let params = t.inner[0..^2].mapIt(it.toString).join(", ")
      let ret = t.inner[^1].toString
      "func(" & params & ") -> " & ret
