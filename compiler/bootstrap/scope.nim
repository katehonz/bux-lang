import std/tables
import types, ast, source_location

type
  SymbolKind* = enum
    skVar
    skFunc
    skType
    skConst
    skModule

  Symbol* = ref object
    kind*: SymbolKind
    name*: string
    typ*: Type
    decl*: Decl        ## optional back-reference to AST decl
    isMutable*: bool
    isPublic*: bool

  Scope* = ref object
    parent*: Scope
    table*: Table[string, Symbol]  ## O(1) lookup via hash table

proc newScope*(parent: Scope = nil): Scope =
  result = Scope(parent: parent)

proc define*(scope: Scope, sym: Symbol): bool =
  ## Returns false if name already exists in this scope
  if scope.table.hasKey(sym.name):
    return false
  scope.table[sym.name] = sym
  return true

proc lookup*(scope: Scope, name: string): Symbol =
  var cur = scope
  while cur != nil:
    if cur.table.hasKey(name):
      return cur.table[name]
    cur = cur.parent
  return nil

proc lookupLocal*(scope: Scope, name: string): Symbol =
  if scope.table.hasKey(name):
    return scope.table[name]
  return nil