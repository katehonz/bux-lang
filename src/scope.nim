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
    symbols*: seq[Symbol]

proc newScope*(parent: Scope = nil): Scope =
  result = Scope(parent: parent)

proc define*(scope: Scope, sym: Symbol): bool =
  ## Returns false if name already exists in this scope
  for s in scope.symbols:
    if s.name == sym.name:
      return false
  scope.symbols.add(sym)
  return true

proc lookup*(scope: Scope, name: string): Symbol =
  var cur = scope
  while cur != nil:
    for s in cur.symbols:
      if s.name == name:
        return s
    cur = cur.parent
  return nil

proc lookupLocal*(scope: Scope, name: string): Symbol =
  for s in scope.symbols:
    if s.name == name:
      return s
  return nil
