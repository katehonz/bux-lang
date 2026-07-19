# lsp_server.nim — Bux Language Server Protocol implementation
# Communicates via stdin/stdout JSON-RPC 2.0
#
# Usage: bux-lsp
# The editor spawns this binary and communicates via stdin/stdout.
#
# Hover uses real bootstrap sema types when possible (globals + stdlib).
# Locals are position-sensitive (scoped) and include inferred `let` types (v0.4.0).
# v0.5.0: textDocument/references + rename (scoped locals + workspace globals).
# v0.6.0: workspace/symbol search.
# v0.7.0: deeper rename — struct fields, enum variants, .member / ::Variant.

import std/[json, os, strutils, streams, tables, osproc, sequtils, sets]
import lexer, parser, ast, sema, types, scope, source_location

# ---------------------------------------------------------------------------
# JSON-RPC Transport
# ---------------------------------------------------------------------------

proc readMessage(stream: FileStream): JsonNode =
  ## Read a single JSON-RPC message from stream.
  ## Format: Content-Length: N\r\n\r\n{json}
  var header = ""
  while true:
    var line = ""
    if not stream.readLine(line):
      return nil
    if line == "\r" or line == "":
      break
    header &= line & "\r\n"
  
  var contentLen = 0
  for hdr in header.split("\r\n"):
    if hdr.toLowerAscii().startsWith("content-length:"):
      try:
        contentLen = parseInt(hdr.split(":")[1].strip())
      except:
        discard
  
  if contentLen <= 0:
    return nil
  
  var body = newString(contentLen)
  if stream.readData(addr body[0], contentLen) != contentLen:
    return nil
  
  try:
    return parseJson(body)
  except:
    return nil

proc sendMessage(stream: FileStream, msg: JsonNode) =
  ## Always write responses on stdout (stream arg kept for call-site compatibility).
  discard stream
  let body = $msg
  let header = "Content-Length: " & $body.len & "\r\n\r\n"
  stdout.write(header)
  stdout.write(body)
  stdout.flushFile()

proc sendResponse(stream: FileStream, id: JsonNode, resultNode: JsonNode) =
  sendMessage(stream, %*{
    "jsonrpc": "2.0",
    "id": id,
    "result": resultNode
  })

proc sendError(stream: FileStream, id: JsonNode, code: int, message: string) =
  sendMessage(stream, %*{
    "jsonrpc": "2.0",
    "id": id,
    "error": {"code": code, "message": message}
  })

proc sendNotification(stream: FileStream, methodName: string, paramsNode: JsonNode) =
  sendMessage(stream, %*{
    "jsonrpc": "2.0",
    "method": methodName,
    "params": paramsNode
  })

# ---------------------------------------------------------------------------
# Document state
# ---------------------------------------------------------------------------

type
  SymbolInfo = object
    line: int          ## 0-based
    col: int           ## 0-based start of name
    kind: string       ## function | variable | struct | enum | …
    detail: string     ## signature / type annotation
    container: string  ## optional parent (module / type)
    fromSema: bool     ## detail came from real type checker
  ## Struct field / enum variant (type member)
  MemberInfo = object
    name: string
    parent: string     ## owning type name
    kind: string       ## field | variant
    line: int          ## 0-based decl line
    col: int           ## 0-based decl col of member name
  ## Scoped local binding for position-sensitive hover / go-to-def
  LocalBinding = object
    name: string
    detail: string     ## e.g. "let x: int" (inferred or annotated)
    kind: string       ## variable | parameter
    declLine: int      ## 0-based declaration line
    declCol: int       ## 0-based start of name
    scopeStartLine: int ## first line where name is visible
    scopeEndLine: int   ## last line where name is visible (inclusive)
    container: string   ## enclosing function name
    inferred: bool      ## type came from initializer, not annotation
  DocumentState = ref object
    uri: string
    content: string
    version: int
    symbols: Table[string, SymbolInfo]
    ordered: seq[string]   ## declaration order for outline
    ## Full-project type index for hover (includes stdlib after sema enrich)
    typeIndex: Table[string, string]   ## name → type / signature string
    kindIndex: Table[string, string]   ## name → kind label
    ## Position-sensitive locals (filled by enrichWithSema)
    locals: seq[LocalBinding]
    ## Type members for field/variant rename (v0.7)
    members: seq[MemberInfo]

var
  documents = initTable[string, DocumentState]()
  rootPath = ""
  rootUri = ""
  workspaceSymbols = initTable[string, tuple[uri: string, info: SymbolInfo]]()
  cachedStdlibDir = ""
  cachedStdlibDecls: seq[Decl] = @[]
  stdlibLoaded = false

proc getDoc(uri: string): DocumentState =
  if not documents.hasKey(uri):
    documents[uri] = DocumentState(uri: uri)
  return documents[uri]

# ---------------------------------------------------------------------------
# File path from URI
# ---------------------------------------------------------------------------

proc uriToPath(uri: string): string =
  if uri.startsWith("file://"):
    result = uri[7..^1]
    # Decode minimal %XX (space)
    result = result.replace("%20", " ")
  else:
    result = uri

proc pathToUri(path: string): string =
  if path.startsWith("file://"):
    return path
  result = "file://" & path

# ---------------------------------------------------------------------------
# Symbol analysis — lightweight scan (not full sema; good enough for hover/def)
# ---------------------------------------------------------------------------

proc isIdentChar(c: char): bool =
  c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc isIdentStart(c: char): bool =
  c in {'a'..'z', 'A'..'Z', '_'}

proc skipWs(s: string, i: var int) =
  while i < s.len and s[i] in {' ', '\t', '\r'}:
    inc i

proc readIdent(s: string, i: var int): string =
  result = ""
  if i >= s.len or not isIdentStart(s[i]):
    return
  while i < s.len and isIdentChar(s[i]):
    result.add(s[i])
    inc i

proc lineColAt(content: string, pos: int): tuple[line, col: int] =
  var line = 0
  var col = 0
  var i = 0
  while i < pos and i < content.len:
    if content[i] == '\n':
      inc line
      col = 0
    else:
      inc col
    inc i
  (line, col)

proc readTypeish(s: string, i: var int): string =
  ## Read a rough type expression: Name, *Name, []Name, func(...)->T, generics
  skipWs(s, i)
  if i >= s.len:
    return ""
  result = ""
  var depth = 0
  while i < s.len:
    let c = s[i]
    if c in {'\n', ';', '{', '=', ','} and depth == 0:
      break
    if c == '(' or c == '[' or c == '<':
      inc depth
    elif c == ')' or c == ']' or c == '>':
      if depth > 0: dec depth
    result.add(c)
    inc i
  result = result.strip()

proc addSymbol(doc: var DocumentState, name: string, info: SymbolInfo) =
  if name.len == 0:
    return
  # Keep first declaration (don't overwrite outer with locals later — last wins for locals is OK for single-file)
  doc.symbols[name] = info
  if name notin doc.ordered:
    doc.ordered.add(name)
  workspaceSymbols[name] = (uri: doc.uri, info: info)

proc addMember(doc: var DocumentState, m: MemberInfo) =
  if m.name.len == 0 or m.parent.len == 0:
    return
  doc.members.add(m)

proc scanTypeBodyMembers(content: string, openBrace: int, parent, bodyKind: string,
                         doc: var DocumentState) =
  ## Scan `{ ... }` after struct/enum for field (`name:`) or variant (`Name` / `Name(`) decls.
  if openBrace < 0 or openBrace >= content.len or content[openBrace] != '{':
    return
  var i = openBrace + 1
  var depth = 1
  var inLineComment = false
  var inBlockComment = false
  var inString = false
  var stringDelim = '\0'
  var escape = false
  while i < content.len and depth > 0:
    let c = content[i]
    if inLineComment:
      if c == '\n': inLineComment = false
      inc i
      continue
    if inBlockComment:
      if c == '*' and i + 1 < content.len and content[i + 1] == '/':
        inBlockComment = false
        i += 2
        continue
      inc i
      continue
    if inString:
      if escape: escape = false
      elif c == '\\': escape = true
      elif c == stringDelim: inString = false
      inc i
      continue
    if c == '/' and i + 1 < content.len and content[i + 1] == '/':
      inLineComment = true
      i += 2
      continue
    if c == '/' and i + 1 < content.len and content[i + 1] == '*':
      inBlockComment = true
      i += 2
      continue
    if c in {'"', '`'}:
      inString = true
      stringDelim = c
      inc i
      continue
    if c == '{':
      inc depth
      inc i
      continue
    if c == '}':
      dec depth
      inc i
      continue
    # Only collect at depth 1 (direct body of the type)
    if depth == 1 and isIdentStart(c):
      let nameStart = i
      let name = readIdent(content, i)
      if name.len == 0:
        inc i
        continue
      # Skip keywords / visibility
      if name in ["pub", "own", "const", "static", "func", "let", "var"]:
        continue
      skipWs(content, i)
      if bodyKind == "struct" or bodyKind == "union" or bodyKind == "interface":
        # Field: Name: Type  (or Name,)
        if i < content.len and content[i] == ':':
          let (line, col) = lineColAt(content, nameStart)
          addMember(doc, MemberInfo(
            name: name, parent: parent, kind: "field", line: line, col: col))
      elif bodyKind == "enum":
        # Variant: Name | Name(...) | Name { ... } — not Name:
        if i >= content.len or content[i] != ':':
          let (line, col) = lineColAt(content, nameStart)
          addMember(doc, MemberInfo(
            name: name, parent: parent, kind: "variant", line: line, col: col))
      continue
    inc i

proc analyzeFile(path: string, content: string): DocumentState =
  result = DocumentState(uri: pathToUri(path), content: content)
  result.symbols = initTable[string, SymbolInfo]()
  result.ordered = @[]
  result.members = @[]

  var i = 0
  var inLineComment = false
  var inBlockComment = false
  var inString = false
  var stringDelim = '\0'
  var escape = false

  while i < content.len:
    let c = content[i]

    # Comments / strings (best-effort skip so "func" in strings is ignored)
    if inLineComment:
      if c == '\n':
        inLineComment = false
      inc i
      continue
    if inBlockComment:
      if c == '*' and i + 1 < content.len and content[i + 1] == '/':
        inBlockComment = false
        i += 2
        continue
      inc i
      continue
    if inString:
      if escape:
        escape = false
      elif c == '\\':
        escape = true
      elif c == stringDelim:
        inString = false
      inc i
      continue

    if c == '/' and i + 1 < content.len and content[i + 1] == '/':
      inLineComment = true
      i += 2
      continue
    if c == '/' and i + 1 < content.len and content[i + 1] == '*':
      inBlockComment = true
      i += 2
      continue
    if c in {'"', '`'} or (c == 'f' and i + 1 < content.len and content[i + 1] == '"'):
      inString = true
      if c == 'f':
        stringDelim = '"'
        i += 2
      else:
        stringDelim = c
        inc i
      continue

    # Keyword must be at token boundary
    template atWord(kw: string): bool =
      (i + kw.len <= content.len and content[i ..< i + kw.len] == kw and
       (i == 0 or not isIdentChar(content[i - 1])) and
       (i + kw.len >= content.len or not isIdentChar(content[i + kw.len])))

    if atWord("func"):
      let kwPos = i
      i += 4
      skipWs(content, i)
      let nameStart = i
      let name = readIdent(content, i)
      if name.len > 0:
        let (line, col) = lineColAt(content, nameStart)
        # signature: from "func" through params + optional return type, stop at '{'
        var j = nameStart
        var depth = 0
        var sigEnd = j
        while j < content.len:
          let ch = content[j]
          if ch == '(' : inc depth
          elif ch == ')' :
            if depth > 0: dec depth
            if depth == 0:
              sigEnd = j + 1
              var k = j + 1
              skipWs(content, k)
              if k + 1 < content.len and content[k] == '-' and content[k + 1] == '>':
                k += 2
                discard readTypeish(content, k)
                sigEnd = k
              break
          elif ch == '{' or ch == '\n' and depth == 0 and j > nameStart + name.len:
            # no-param or broken — still capture name
            if sigEnd <= nameStart:
              sigEnd = i
            break
          inc j
        var sig = content[kwPos ..< min(sigEnd, content.len)].strip()
        # collapse whitespace
        sig = sig.replace("\n", " ").multiReplace([("  ", " "), ("  ", " "), ("  ", " ")])
        addSymbol(result, name, SymbolInfo(
          line: line, col: col, kind: "function", detail: sig, container: ""))
      continue

    if atWord("let") or atWord("var") or atWord("const"):
      let kw = if content[i] == 'l': "let" elif content[i] == 'c': "const" else: "var"
      let kind = if kw == "const": "constant" else: "variable"
      i += kw.len
      skipWs(content, i)
      let nameStart = i
      let name = readIdent(content, i)
      if name.len > 0:
        let (line, col) = lineColAt(content, nameStart)
        skipWs(content, i)
        var typ = ""
        if i < content.len and content[i] == ':':
          inc i
          typ = readTypeish(content, i)
        let detail = if typ.len > 0: kw & " " & name & ": " & typ else: kw & " " & name
        addSymbol(result, name, SymbolInfo(
          line: line, col: col, kind: kind, detail: detail, container: ""))
      continue

    var matchedTypeKw = false
    for (kw, kind) in [("struct", "struct"), ("enum", "enum"), ("union", "struct"),
                       ("interface", "interface"), ("type", "type"), ("module", "module")]:
      if atWord(kw):
        matchedTypeKw = true
        i += kw.len
        skipWs(content, i)
        let nameStart = i
        let name = readIdent(content, i)
        if name.len > 0:
          let (line, col) = lineColAt(content, nameStart)
          var detail = kw & " " & name
          if kind == "type":
            skipWs(content, i)
            if i < content.len and content[i] == '=':
              inc i
              let rhs = readTypeish(content, i)
              if rhs.len > 0:
                detail = "type " & name & " = " & rhs
          addSymbol(result, name, SymbolInfo(
            line: line, col: col, kind: kind, detail: detail, container: ""))
          # Index members inside { ... }
          if kind in ["struct", "enum", "union", "interface"]:
            var j = i
            skipWs(content, j)
            # skip generic params <T>
            if j < content.len and content[j] == '<':
              var gd = 1
              inc j
              while j < content.len and gd > 0:
                if content[j] == '<': inc gd
                elif content[j] == '>': dec gd
                inc j
              skipWs(content, j)
            if j < content.len and content[j] == '{':
              scanTypeBodyMembers(content, j, name, kind, result)
        break
    if not matchedTypeKw:
      inc i

# ---------------------------------------------------------------------------
# Real sema types for hover
# ---------------------------------------------------------------------------

proc typeExprToStr(te: TypeExpr): string =
  if te == nil: return "?"
  case te.kind
  of tekNamed:
    result = te.typeName
    if te.typeArgs.len > 0:
      result &= "<" & te.typeArgs.mapIt(typeExprToStr(it)).join(", ") & ">"
  of tekPath:
    result = te.pathSegments.join("::")
  of tekPointer:
    result = "*" & typeExprToStr(te.pointerPointee)
  of tekOwn:
    result = "own " & typeExprToStr(te.pointerPointee)
  of tekRef:
    if te.refLifetime.len > 0:
      result = "&" & te.refLifetime & " " & typeExprToStr(te.pointerPointee)
    else:
      result = "&" & typeExprToStr(te.pointerPointee)
  of tekMutRef:
    if te.refLifetime.len > 0:
      result = "&" & te.refLifetime & " mut " & typeExprToStr(te.pointerPointee)
    else:
      result = "&mut " & typeExprToStr(te.pointerPointee)
  of tekSlice:
    result = typeExprToStr(te.sliceElement) & "[]"
  of tekTuple:
    result = "(" & te.tupleElements.mapIt(typeExprToStr(it)).join(", ") & ")"
  of tekFunc:
    let ps = te.funcParams.mapIt(typeExprToStr(it)).join(", ")
    let ret = if te.funcRet != nil: typeExprToStr(te.funcRet) else: "void"
    result = "func(" & ps & ") -> " & ret
  of tekSelf:
    result = "self"
  of tekDynRef:
    result = "&dyn " & te.dynInterface

proc formatFuncDetail(name: string, decl: Decl): string =
  if decl == nil or decl.kind != dkFunc:
    return "func " & name
  var parts: seq[string] = @[]
  for p in decl.declFuncParams:
    var s = p.name
    if p.ptype != nil:
      s &= ": " & typeExprToStr(p.ptype)
    parts.add(s)
  result = "func " & name & "(" & parts.join(", ") & ")"
  if decl.declFuncTypeParams.len > 0:
    let tps = decl.declFuncTypeParams.mapIt(it.name).join(", ")
    result = "func " & name & "<" & tps & ">(" & parts.join(", ") & ")"
  if decl.declFuncReturnType != nil:
    result &= " -> " & typeExprToStr(decl.declFuncReturnType)

proc symbolKindFromSema(sk: SymbolKind): string =
  case sk
  of skFunc: "function"
  of skVar: "variable"
  of skConst: "constant"
  of skType: "type"
  of skModule: "module"

proc findStdlibDirLocal(root: string): string =
  if root.len == 0: return ""
  let candidates = @[
    root / "lib",
    root / ".." / "lib",
    getAppDir() / "lib",
    getAppDir() / ".." / "lib",
    getCurrentDir() / "lib"
  ]
  for c in candidates:
    if dirExists(c):
      return c.absolutePath
  # Walk up from root looking for lib/
  var cur = root.absolutePath
  for _ in 0 .. 6:
    let lib = cur / "lib"
    if dirExists(lib): return lib
    let parent = cur.parentDir
    if parent == cur: break
    cur = parent
  return ""

proc loadStdlibDecls(stdlibDir: string): seq[Decl] =
  result = @[]
  if stdlibDir.len == 0 or not dirExists(stdlibDir):
    return
  for path in walkDirRec(stdlibDir):
    if not path.endsWith(".bux"): continue
    try:
      let source = readFile(path)
      let lexRes = tokenize(source, path)
      if lexRes.hasErrors: continue
      let parseRes = parse(lexRes.tokens, path)
      if parseRes.diagnostics.len > 0: continue
      for item in parseRes.module.items:
        if item.kind == dkModule:
          for sub in item.declModuleItems:
            result.add(sub)
        else:
          result.add(item)
    except:
      discard

proc ensureStdlibCached() =
  if stdlibLoaded: return
  stdlibLoaded = true
  cachedStdlibDir = findStdlibDirLocal(rootPath)
  if cachedStdlibDir.len == 0:
    # try from open document path later
    return
  cachedStdlibDecls = loadStdlibDecls(cachedStdlibDir)

proc enrichWithSema(doc: DocumentState) =
  ## Run real bootstrap sema (file + stdlib) and fill typeIndex + upgrade symbols.
  if doc.content.len == 0: return
  let path = uriToPath(doc.uri)
  ensureStdlibCached()
  if cachedStdlibDecls.len == 0 and rootPath.len == 0:
    # Try stdlib relative to the file
    let tryRoot = path.parentDir.parentDir  # …/src/Main.bux → package
    cachedStdlibDir = findStdlibDirLocal(tryRoot)
    if cachedStdlibDir.len > 0:
      cachedStdlibDecls = loadStdlibDecls(cachedStdlibDir)

  try:
    let lexRes = tokenize(doc.content, path)
    if lexRes.hasErrors:
      return
    let parseRes = parse(lexRes.tokens, path)
    # Build unified module: stdlib first, then this file
    var unified = newModule("lsp")
    for d in cachedStdlibDecls:
      unified.items.add(d)
    for d in parseRes.module.items:
      if d.kind == dkModule:
        for sub in d.declModuleItems:
          unified.items.add(sub)
      else:
        unified.items.add(d)

    let (semaRes, semaCtx) = analyzeFull(unified)
    discard semaRes  # diagnostics already published via buxc

    doc.typeIndex = initTable[string, string]()
    doc.kindIndex = initTable[string, string]()

    # Index entire global scope for hover (includes stdlib)
    if semaCtx.globalScope != nil:
      for name, sym in semaCtx.globalScope.table.pairs:
        if name.len == 0: continue
        var detail = ""
        var kind = symbolKindFromSema(sym.kind)
        if sym.kind == skFunc and sym.decl != nil and sym.decl.kind == dkFunc:
          detail = formatFuncDetail(name, sym.decl)
        elif sym.typ != nil and not sym.typ.isUnknown:
          detail = name & ": " & sym.typ.toString
          if sym.kind == skFunc:
            detail = sym.typ.toString  # already "func(...) -> T"
            if not detail.startsWith("func"):
              detail = "func " & name & " — " & detail
            else:
              # inject name: func name(...)
              detail = detail.replace("func(", "func " & name & "(")
          elif sym.kind == skConst:
            detail = "const " & name & ": " & sym.typ.toString
          elif sym.kind == skType:
            detail = "type " & name
            kind = "type"
          else:
            detail = (if sym.isMutable: "var " else: "let ") & name & ": " & sym.typ.toString
        elif sym.decl != nil:
          case sym.decl.kind
          of dkStruct:
            detail = "struct " & name
            kind = "struct"
          of dkEnum:
            detail = "enum " & name
            kind = "enum"
          of dkUnion:
            detail = "union " & name
            kind = "struct"
          of dkInterface:
            detail = "interface " & name
            kind = "interface"
          of dkTypeAlias:
            detail = "type " & name
            if sym.decl.declAliasType != nil:
              detail &= " = " & typeExprToStr(sym.decl.declAliasType)
            kind = "type"
          of dkFunc:
            detail = formatFuncDetail(name, sym.decl)
            kind = "function"
          else:
            detail = name
        else:
          detail = name

        doc.typeIndex[name] = detail
        doc.kindIndex[name] = kind

        # Upgrade file-local symbols (already found by lightweight scan)
        if doc.symbols.hasKey(name):
          var info = doc.symbols[name]
          info.detail = detail
          info.kind = kind
          info.fromSema = true
          doc.symbols[name] = info

    # Prefer THIS file's declarations over stdlib when names collide
    # (e.g. user `Max<T>` vs lib/Math `Max(int64,int64)`).
    for d in parseRes.module.items:
      proc indexDecl(dd: Decl) =
        case dd.kind
        of dkFunc:
          let n = dd.declFuncName
          if n.len == 0: return
          let detail = formatFuncDetail(n, dd)
          doc.typeIndex[n] = detail
          doc.kindIndex[n] = "function"
          if doc.symbols.hasKey(n):
            var info = doc.symbols[n]
            info.detail = detail
            info.kind = "function"
            info.fromSema = true
            doc.symbols[n] = info
          else:
            let line = max(0, int(dd.loc.line) - 1)
            let col = max(0, int(dd.loc.column) - 1)
            doc.symbols[n] = SymbolInfo(
              line: line, col: col, kind: "function", detail: detail,
              container: "", fromSema: true)
            if n notin doc.ordered: doc.ordered.add(n)
        of dkStruct:
          let n = dd.declStructName
          doc.typeIndex[n] = "struct " & n
          doc.kindIndex[n] = "struct"
        of dkEnum:
          let n = dd.declEnumName
          doc.typeIndex[n] = "enum " & n
          doc.kindIndex[n] = "enum"
        of dkTypeAlias:
          let n = dd.declAliasName
          var detail = "type " & n
          if dd.declAliasType != nil:
            detail &= " = " & typeExprToStr(dd.declAliasType)
          doc.typeIndex[n] = detail
          doc.kindIndex[n] = "type"
        else:
          discard
      if d.kind == dkModule:
        for sub in d.declModuleItems:
          indexDecl(sub)
      else:
        indexDecl(d)

    # --- Position-sensitive locals + inferred let types ---
    doc.locals = @[]

    proc blockEndLine(blk: Block): int =
      ## Last 0-based line covered by statements in `blk` (best-effort).
      if blk == nil: return 0
      result = max(0, int(blk.loc.line) - 1)
      for stmt in blk.stmts:
        result = max(result, max(0, int(stmt.loc.line) - 1))
        case stmt.kind
        of skIf:
          result = max(result, blockEndLine(stmt.stmtIfThen))
          result = max(result, blockEndLine(stmt.stmtIfElse))
          for br in stmt.stmtIfElseIfs:
            result = max(result, blockEndLine(br.blk))
        of skWhile:
          result = max(result, blockEndLine(stmt.stmtWhileBody))
        of skDoWhile:
          result = max(result, blockEndLine(stmt.stmtDoWhileBody))
        of skLoop:
          result = max(result, blockEndLine(stmt.stmtLoopBody))
        of skFor:
          result = max(result, blockEndLine(stmt.stmtForBody))
        of skMatch:
          for arm in stmt.stmtMatchArms:
            if arm.body != nil and arm.body.kind == ekBlock:
              result = max(result, blockEndLine(arm.body.exprBlock))
            elif arm.body != nil:
              result = max(result, max(0, int(arm.body.loc.line) - 1))
        of skExpr:
          if stmt.stmtExpr != nil and stmt.stmtExpr.kind == ekBlock:
            result = max(result, blockEndLine(stmt.stmtExpr.exprBlock))
        else:
          discard

    proc collectLocals(sema: var Sema, blk: Block, sc: Scope, scopeEnd: int,
                       container: string) =
      if blk == nil: return
      let endLine = max(scopeEnd, blockEndLine(blk))
      for stmt in blk.stmts:
        case stmt.kind
        of skLet:
          let n = stmt.stmtLetName
          if n.len == 0: continue
          var typ: Type = makeUnknown()
          var inferred = false
          if stmt.stmtLetType != nil:
            typ = sema.resolveType(stmt.stmtLetType)
          if (typ == nil or typ.isUnknown) and stmt.stmtLetInit != nil:
            typ = sema.checkExprForLsp(stmt.stmtLetInit, sc)
            inferred = true
          elif stmt.stmtLetType == nil and stmt.stmtLetInit != nil:
            # Explicit absence of annotation — still type the initializer
            typ = sema.checkExprForLsp(stmt.stmtLetInit, sc)
            inferred = true
          let kw = if stmt.stmtLetMut: "var" else: "let"
          let typStr = if typ != nil and not typ.isUnknown: typ.toString else: ""
          let detail =
            if typStr.len > 0: kw & " " & n & ": " & typStr
            else: kw & " " & n
          let line = max(0, int(stmt.loc.line) - 1)
          let col = max(0, int(stmt.loc.column) - 1)
          doc.locals.add(LocalBinding(
            name: n, detail: detail, kind: "variable",
            declLine: line, declCol: col,
            scopeStartLine: line, scopeEndLine: endLine,
            container: container, inferred: inferred and typStr.len > 0))
          # Also keep latest flat entry for outline (position lookup prefers locals)
          doc.symbols[n] = SymbolInfo(
            line: line, col: col, kind: "variable", detail: detail,
            container: container, fromSema: typStr.len > 0)
          if n notin doc.ordered:
            doc.ordered.add(n)
          # Define in scope for subsequent inference
          let sym = Symbol(kind: skVar, name: n, typ: typ,
                           isMutable: stmt.stmtLetMut, isOwn: false)
          discard sc.define(sym)
        of skExpr:
          if stmt.stmtExpr != nil and stmt.stmtExpr.kind == ekBlock:
            var child = newScope(sc)
            collectLocals(sema, stmt.stmtExpr.exprBlock, child,
                          blockEndLine(stmt.stmtExpr.exprBlock), container)
        of skIf:
          var thenSc = newScope(sc)
          collectLocals(sema, stmt.stmtIfThen, thenSc,
                        blockEndLine(stmt.stmtIfThen), container)
          for br in stmt.stmtIfElseIfs:
            var elifSc = newScope(sc)
            collectLocals(sema, br.blk, elifSc, blockEndLine(br.blk), container)
          if stmt.stmtIfElse != nil:
            var elseSc = newScope(sc)
            collectLocals(sema, stmt.stmtIfElse, elseSc,
                          blockEndLine(stmt.stmtIfElse), container)
        of skWhile:
          var wSc = newScope(sc)
          collectLocals(sema, stmt.stmtWhileBody, wSc,
                        blockEndLine(stmt.stmtWhileBody), container)
        of skDoWhile:
          var dSc = newScope(sc)
          collectLocals(sema, stmt.stmtDoWhileBody, dSc,
                        blockEndLine(stmt.stmtDoWhileBody), container)
        of skLoop:
          var lSc = newScope(sc)
          collectLocals(sema, stmt.stmtLoopBody, lSc,
                        blockEndLine(stmt.stmtLoopBody), container)
        of skFor:
          var fSc = newScope(sc)
          if stmt.stmtForVar.len > 0:
            let fline = max(0, int(stmt.loc.line) - 1)
            let fcol = max(0, int(stmt.loc.column) - 1)
            let fend = blockEndLine(stmt.stmtForBody)
            # Best-effort: element type unknown without iterator typing
            let detail = "for " & stmt.stmtForVar
            doc.locals.add(LocalBinding(
              name: stmt.stmtForVar, detail: detail, kind: "variable",
              declLine: fline, declCol: fcol,
              scopeStartLine: fline, scopeEndLine: fend,
              container: container, inferred: false))
            discard fSc.define(Symbol(kind: skVar, name: stmt.stmtForVar,
                                      typ: makeUnknown(), isMutable: false))
          collectLocals(sema, stmt.stmtForBody, fSc,
                        blockEndLine(stmt.stmtForBody), container)
        of skMatch:
          for arm in stmt.stmtMatchArms:
            if arm.body != nil and arm.body.kind == ekBlock:
              var mSc = newScope(sc)
              collectLocals(sema, arm.body.exprBlock, mSc,
                            blockEndLine(arm.body.exprBlock), container)
        else:
          discard

    proc collectFuncLocals(sema: var Sema, d: Decl) =
      if d == nil or d.kind != dkFunc or d.declFuncBody == nil:
        return
      let fname = d.declFuncName
      let bodyEnd = blockEndLine(d.declFuncBody)
      var funcScope = newScope(sema.globalScope)
      # Parameters — visible for entire function body
      let funcStart = max(0, int(d.loc.line) - 1)
      for p in d.declFuncParams:
        if p.name.len == 0: continue
        var pType = makeUnknown()
        if p.ptype != nil:
          pType = sema.resolveType(p.ptype)
        let typStr = if pType != nil and not pType.isUnknown: pType.toString else: ""
        let detail =
          if typStr.len > 0: "param " & p.name & ": " & typStr
          else: "param " & p.name
        let pline = max(0, int(p.loc.line) - 1)
        let pcol = max(0, int(p.loc.column) - 1)
        doc.locals.add(LocalBinding(
          name: p.name, detail: detail, kind: "parameter",
          declLine: pline, declCol: pcol,
          scopeStartLine: funcStart, scopeEndLine: bodyEnd,
          container: fname, inferred: false))
        discard funcScope.define(Symbol(kind: skVar, name: p.name, typ: pType,
                                        isMutable: false))
      collectLocals(sema, d.declFuncBody, funcScope, bodyEnd, fname)

    var semaMut = semaCtx
    for d in parseRes.module.items:
      if d.kind == dkFunc:
        collectFuncLocals(semaMut, d)
      elif d.kind == dkModule:
        for sub in d.declModuleItems:
          if sub.kind == dkFunc:
            collectFuncLocals(semaMut, sub)

  except:
    discard  # sema failures must not crash the LSP

# ---------------------------------------------------------------------------
# Diagnostics — run `buxc check` when available and parse Rust-style errors
# ---------------------------------------------------------------------------

type
  LspDiag = object
    line: int        ## 0-based for LSP
    col: int         ## 0-based
    endCol: int      ## 0-based exclusive
    severity: int    ## 1=error, 2=warning
    message: string

proc findBuxc(): string =
  ## Prefer buxc next to the LSP binary, then PATH.
  let beside = getAppDir() / "buxc"
  if fileExists(beside): return beside
  let beside2 = getCurrentDir() / "buxc"
  if fileExists(beside2): return beside2
  result = findExe("buxc")

proc parseBuxcDiagnostics(output, sourcePath: string): seq[LspDiag] =
  ## Parse lines like:
  ##   error: cannot assign String to int
  ##     --> /path/Main.bux:4:18
  result = @[]
  let lines = output.splitLines()
  var i = 0
  while i < lines.len:
    let line = lines[i]
    var sev = 0
    var msg = ""
    if line.startsWith("error: "):
      sev = 1
      msg = line[7..^1]
    elif line.startsWith("warning: "):
      sev = 2
      msg = line[9..^1]
    else:
      inc i
      continue

    # Skip aggregate headers like "type errors in project"
    if msg.startsWith("type errors") or msg.startsWith("parse errors") or
       msg.startsWith("lex errors"):
      inc i
      continue

    var fileLine = 1
    var fileCol = 1
    if i + 1 < lines.len and lines[i + 1].strip().startsWith("-->"):
      let locPart = lines[i + 1].strip()[3..^1].strip()
      # path:line:col
      let parts = locPart.rsplit(':', maxsplit = 2)
      if parts.len >= 3:
        try:
          fileLine = parseInt(parts[^2])
          fileCol = parseInt(parts[^1])
        except: discard
      # Optionally filter to the open document
      let pathPart = if parts.len >= 3: parts[0] else: ""
      if sourcePath.len > 0 and pathPart.len > 0:
        if not pathPart.endsWith(sourcePath.extractFilename) and
           pathPart != sourcePath:
          i += 1
          continue
    # Estimate end column from message quote or single caret width
    var endCol = fileCol
    let q = msg.find('\'')
    if q >= 0:
      let q2 = msg.find('\'', q + 1)
      if q2 > q + 1:
        endCol = fileCol + (q2 - q - 1)
    if endCol <= fileCol:
      endCol = fileCol + 1

    result.add(LspDiag(
      line: max(0, fileLine - 1),
      col: max(0, fileCol - 1),
      endCol: max(0, endCol - 1),
      severity: sev,
      message: msg
    ))
    inc i

proc runBuxcDiagnostics(sourcePath, content: string): seq[LspDiag] =
  result = @[]
  let buxc = findBuxc()
  if buxc.len == 0:
    return

  # Prefer package root if this file lives under src/
  var projectDir = sourcePath.parentDir
  if projectDir.endsWith("src"):
    projectDir = projectDir.parentDir
  let toml = projectDir / "bux.toml"

  var cmd: string
  var workDir: string
  if fileExists(toml):
    workDir = projectDir
    cmd = buxc & " check --color off"
  else:
    # Temp package for free-standing buffers
    let tmp = getTempDir() / "bux-lsp-" & $getCurrentProcessId()
    createDir(tmp / "src")
    writeFile(tmp / "bux.toml", """[Package]
Name = "lsp_tmp"
Version = "0.0.0"
Type = "bin"
[Build]
Output = "Bin"
""")
    writeFile(tmp / "src" / "Main.bux", content)
    workDir = tmp
    cmd = buxc & " check --color off"

  try:
    let (output, _) = execCmdEx(cmd, workingDir = workDir)
    result = parseBuxcDiagnostics(output, sourcePath)
  except CatchableError:
    discard

proc publishDiagnostics(stream: FileStream, uri: string, diags: seq[LspDiag] = @[]) =
  var arr = newJArray()
  for d in diags:
    arr.add(%*{
      "range": {
        "start": {"line": d.line, "character": d.col},
        "end": {"line": d.line, "character": d.endCol}
      },
      "severity": d.severity,
      "source": "buxc",
      "message": d.message
    })
  sendNotification(stream, "textDocument/publishDiagnostics", %*{
    "uri": uri,
    "diagnostics": arr
  })

proc analyzeAndPublishDiagnostics(stream: FileStream, doc: DocumentState) =
  let path = uriToPath(doc.uri)
  let updated = analyzeFile(path, doc.content)
  doc.symbols = updated.symbols
  doc.ordered = updated.ordered
  doc.members = updated.members
  # Keep / refresh real types for hover (does not replace lightweight outline)
  enrichWithSema(doc)
  let diags = runBuxcDiagnostics(path, doc.content)
  publishDiagnostics(stream, doc.uri, diags)

proc scanWorkspace(dir: string, depth = 0) =
  ## Index .bux files under the workspace for cross-file go-to-def / hover.
  if depth > 4 or dir.len == 0 or not dirExists(dir):
    return
  let base = dir.extractFilename
  if base in [".git", "build", "examples_pkg", "node_modules", "vendor"]:
    return
  try:
    for kind, path in walkDir(dir):
      if kind == pcDir:
        scanWorkspace(path, depth + 1)
      elif kind == pcFile and path.endsWith(".bux"):
        try:
          let content = readFile(path)
          discard analyzeFile(path, content)
        except CatchableError:
          discard
  except CatchableError:
    discard

# ---------------------------------------------------------------------------
# Completion
# ---------------------------------------------------------------------------

proc findWordAt(content: string, lineNum: int, col: int): string =
  var lines = content.split("\n")
  if lineNum >= lines.len: return ""
  let l = lines[lineNum]
  var start = col
  var endC = col
  while start > 0 and l[start-1] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
    start -= 1
  while endC < l.len and l[endC] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
    endC += 1
  if start < endC:
    result = l[start..endC-1]

proc ensureAnalyzed(doc: DocumentState) =
  if doc.content.len == 0:
    return
  if doc.symbols.len == 0:
    let updated = analyzeFile(uriToPath(doc.uri), doc.content)
    doc.symbols = updated.symbols
    doc.ordered = updated.ordered
    doc.members = updated.members

proc completionKind(kind: string): int =
  case kind
  of "function": 3
  of "variable": 6
  of "constant": 14
  of "struct": 22
  of "enum": 13
  of "interface": 8
  of "type": 25
  of "module": 9
  else: 6

proc handleCompletion(stream: FileStream, id: JsonNode, paramsNode: JsonNode) =
  let uri = paramsNode["textDocument"]["uri"].getStr()
  let position = paramsNode["position"]
  let lineNum = position["line"].getInt()
  let col = position["character"].getInt()

  let doc = getDoc(uri)
  if doc.content == "":
    sendResponse(stream, id, %*{"isIncomplete": false, "items": []})
    return

  ensureAnalyzed(doc)
  if doc.locals.len == 0 and doc.content.len > 0:
    enrichWithSema(doc)
  let prefix = findWordAt(doc.content, lineNum, col)

  var items = newJArray()
  var offered = initHashSet[string]()

  # Position-sensitive locals / params first (highest priority)
  for b in doc.locals:
    if lineNum < b.scopeStartLine or lineNum > b.scopeEndLine: continue
    if prefix != "" and not b.name.toLowerAscii().startsWith(prefix.toLowerAscii()):
      continue
    # Prefer later/narrower binding for same name
    if offered.contains(b.name):
      continue
    offered.incl(b.name)
    let k = if b.kind == "parameter": 6 else: completionKind("variable")
    items.add(%*{
      "label": b.name,
      "kind": k,
      "detail": b.detail,
      "sortText": "0_" & b.name,
      "documentation": {"kind": "markdown",
        "value": "```bux\n" & b.detail & "\n```\n\n_" & b.kind &
                 (if b.inferred: " · inferred" else: "") & "_"}
    })

  for name, info in doc.symbols.pairs:
    if offered.contains(name): continue
    if prefix == "" or name.toLowerAscii().startsWith(prefix.toLowerAscii()):
      offered.incl(name)
      items.add(%*{
        "label": name,
        "kind": completionKind(info.kind),
        "detail": info.detail,
        "sortText": "1_" & name,
        "documentation": {"kind": "markdown", "value": "```bux\n" & info.detail & "\n```\n\n_" & info.kind & "_"}
      })

  # Also offer workspace symbols (other open / scanned files)
  for name, ws in workspaceSymbols.pairs:
    if offered.contains(name): continue
    if prefix == "" or name.toLowerAscii().startsWith(prefix.toLowerAscii()):
      offered.incl(name)
      items.add(%*{
        "label": name,
        "kind": completionKind(ws.info.kind),
        "detail": ws.info.detail & "  (workspace)",
        "sortText": "2_" & name,
        "documentation": {"kind": "markdown", "value": "```bux\n" & ws.info.detail & "\n```"}
      })

  let keywords = ["func", "var", "let", "if", "else", "while", "for", "return",
                  "struct", "enum", "union", "interface", "extend", "module",
                  "import", "true", "false", "null", "self", "match", "break",
                  "continue", "async", "await", "spawn", "const", "type",
                  "defer", "switch", "case", "default", "pub", "own"]
  for kw in keywords:
    if prefix == "" or kw.startsWith(prefix):
      items.add(%*{
        "label": kw,
        "kind": 14,
        "detail": "keyword",
        "sortText": "3_" & kw
      })

  sendResponse(stream, id, %*{"isIncomplete": false, "items": items})

# ---------------------------------------------------------------------------
# Position-sensitive local lookup
# ---------------------------------------------------------------------------

proc lookupLocalAt*(doc: DocumentState, name: string, line: int): tuple[ok: bool, b: LocalBinding] =
  ## Innermost local/parameter binding for `name` visible at `line` (0-based).
  result.ok = false
  var bestSpan = high(int)
  var bestStart = -1
  for b in doc.locals:
    if b.name != name: continue
    if line < b.scopeStartLine or line > b.scopeEndLine: continue
    let span = b.scopeEndLine - b.scopeStartLine
    # Prefer narrower scope; on ties prefer later declaration (shadowing)
    if span < bestSpan or (span == bestSpan and b.scopeStartLine >= bestStart):
      bestSpan = span
      bestStart = b.scopeStartLine
      result.b = b
      result.ok = true

# ---------------------------------------------------------------------------
# Go-to-definition
# ---------------------------------------------------------------------------

proc handleDefinition(stream: FileStream, id: JsonNode, paramsNode: JsonNode) =
  let uri = paramsNode["textDocument"]["uri"].getStr()
  let position = paramsNode["position"]
  let lineNum = position["line"].getInt()
  let col = position["character"].getInt()

  let doc = getDoc(uri)
  if doc.content == "":
    sendResponse(stream, id, %*[])
    return

  ensureAnalyzed(doc)
  if doc.locals.len == 0 and doc.content.len > 0:
    enrichWithSema(doc)

  let word = findWordAt(doc.content, lineNum, col)
  if word.len == 0:
    sendResponse(stream, id, %*[])
    return

  var locs = newJArray()
  # Position-sensitive local first
  let (lok, lb) = lookupLocalAt(doc, word, lineNum)
  if lok:
    locs.add(%*{
      "uri": uri,
      "range": {
        "start": {"line": lb.declLine, "character": lb.declCol},
        "end": {"line": lb.declLine, "character": lb.declCol + word.len}
      }
    })
  elif doc.symbols.hasKey(word):
    let info = doc.symbols[word]
    locs.add(%*{
      "uri": uri,
      "range": {
        "start": {"line": info.line, "character": info.col},
        "end": {"line": info.line, "character": info.col + word.len}
      }
    })
  elif workspaceSymbols.hasKey(word):
    let ws = workspaceSymbols[word]
    locs.add(%*{
      "uri": ws.uri,
      "range": {
        "start": {"line": ws.info.line, "character": ws.info.col},
        "end": {"line": ws.info.line, "character": ws.info.col + word.len}
      }
    })
  sendResponse(stream, id, locs)

# ---------------------------------------------------------------------------
# Hover
# ---------------------------------------------------------------------------

proc handleHover(stream: FileStream, id: JsonNode, paramsNode: JsonNode) =
  ## Hover with accurate range; prefer real sema types when available.
  ## Locals are resolved by position (shadowing / nested scopes).
  let uri = paramsNode["textDocument"]["uri"].getStr()
  let position = paramsNode["position"]
  let lineNum = position["line"].getInt()
  let col = position["character"].getInt()

  let doc = getDoc(uri)
  if doc.content == "":
    sendResponse(stream, id, newJNull())
    return

  ensureAnalyzed(doc)
  # Lazy sema enrich on first hover if not yet run (e.g. only didChange so far)
  if (doc.typeIndex.len == 0 or doc.locals.len == 0) and doc.content.len > 0:
    enrichWithSema(doc)

  let lines = doc.content.split("\n")
  if lineNum >= lines.len:
    sendResponse(stream, id, newJNull())
    return
  let l = lines[lineNum]
  var start = min(col, l.len)
  var endC = start
  while start > 0 and l[start - 1] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
    dec start
  while endC < l.len and l[endC] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
    inc endC
  if start >= endC:
    sendResponse(stream, id, newJNull())
    return
  let word = l[start ..< endC]

  var detail = ""
  var kind = ""
  var found = false
  var fromSema = false
  var inferred = false
  var scopeNote = ""

  # 1) Position-sensitive local / parameter
  let (lok, lb) = lookupLocalAt(doc, word, lineNum)
  if lok:
    detail = lb.detail
    kind = lb.kind
    found = true
    fromSema = true
    inferred = lb.inferred
    if lb.container.len > 0:
      scopeNote = " in `" & lb.container & "`"

  # 2) File-level / global symbols (functions, types, …)
  if not found and doc.symbols.hasKey(word):
    let info = doc.symbols[word]
    detail = info.detail
    kind = info.kind
    found = true
    fromSema = info.fromSema
    if doc.typeIndex.hasKey(word) and doc.typeIndex[word].len >= detail.len:
      detail = doc.typeIndex[word]
      if doc.kindIndex.hasKey(word):
        kind = doc.kindIndex[word]
      fromSema = true
  elif not found and doc.typeIndex.hasKey(word):
    detail = doc.typeIndex[word]
    kind = if doc.kindIndex.hasKey(word): doc.kindIndex[word] else: "symbol"
    found = true
    fromSema = true
  elif not found and workspaceSymbols.hasKey(word):
    let info = workspaceSymbols[word].info
    detail = info.detail
    kind = info.kind
    found = true

  if not found:
    sendResponse(stream, id, newJNull())
    return

  var md = "```bux\n" & detail & "\n```\n\n_" & kind & "_"
  if scopeNote.len > 0:
    md &= scopeNote
  if fromSema:
    md &= " · sema"
  if inferred:
    md &= " · inferred"

  sendResponse(stream, id, %*{
    "contents": {"kind": "markdown", "value": md},
    "range": {
      "start": {"line": lineNum, "character": start},
      "end": {"line": lineNum, "character": endC}
    }
  })

# ---------------------------------------------------------------------------
# Identifier occurrences (references / rename) — sessions 34 + 39 (deeper)
# ---------------------------------------------------------------------------

type
  IdentAccess = enum
    iaBare       ## plain ident
    iaDot        ## .member
    iaColonColon ## Type::Variant or path::name
    iaFieldInit  ## Name: inside struct literal / pattern (preceded by `{` or `,`)
  IdentHit = object
    line: int   ## 0-based
    col: int    ## 0-based start of name
    len: int
    access: IdentAccess
  RenameTargetKind = enum
    rtkLocal
    rtkGlobal
    rtkMember
    rtkUnknown
  RenameTarget = object
    kind: RenameTargetKind
    name: string
    ## For rtkMember
    parent: string
    memberKind: string
    declLine: int
    declCol: int
    ## For rtkLocal
    local: LocalBinding

proc peekAccessBefore(content: string, start: int): IdentAccess =
  ## Classify how the identifier at `start` is written.
  var k = start - 1
  while k >= 0 and content[k] in {' ', '\t'}:
    dec k
  if k < 0:
    return iaBare
  if content[k] == '.':
    return iaDot
  if content[k] == ':' and k > 0 and content[k - 1] == ':':
    return iaColonColon
  if content[k] == ':' and (k == 0 or content[k - 1] != ':'):
    # This is after the name for `name: type` — check from start side instead
    discard
  # Field init: after `{` or `,` optional whitespace then name then `:`
  var j = start + 1
  while j < content.len and isIdentChar(content[j]):
    inc j
  var t = j
  while t < content.len and content[t] in {' ', '\t'}:
    inc t
  if t < content.len and content[t] == ':':
    # name:  — could be field decl/init if preceded by { or ,
    if k >= 0 and content[k] in {'{', ',', '\n', ';'}:
      return iaFieldInit
  return iaBare

proc collectIdentHits(content, name: string): seq[IdentHit] =
  ## Textual identifier occurrences of `name`, skipping strings/comments.
  result = @[]
  if name.len == 0 or content.len == 0:
    return
  var i = 0
  var inLineComment = false
  var inBlockComment = false
  var inString = false
  var stringDelim = '\0'
  var escape = false
  while i < content.len:
    let c = content[i]
    if inLineComment:
      if c == '\n': inLineComment = false
      inc i
      continue
    if inBlockComment:
      if c == '*' and i + 1 < content.len and content[i + 1] == '/':
        inBlockComment = false
        i += 2
        continue
      inc i
      continue
    if inString:
      if escape: escape = false
      elif c == '\\': escape = true
      elif c == stringDelim: inString = false
      inc i
      continue
    if c == '/' and i + 1 < content.len and content[i + 1] == '/':
      inLineComment = true
      i += 2
      continue
    if c == '/' and i + 1 < content.len and content[i + 1] == '*':
      inBlockComment = true
      i += 2
      continue
    if c in {'"', '`'} or (c == 'f' and i + 1 < content.len and content[i + 1] == '"'):
      inString = true
      if c == 'f':
        stringDelim = '"'
        i += 2
      else:
        stringDelim = c
        inc i
      continue

    if isIdentStart(c):
      let start = i
      var j = i + 1
      while j < content.len and isIdentChar(content[j]):
        inc j
      let ident = content[start ..< j]
      if ident == name:
        let (line, col) = lineColAt(content, start)
        result.add(IdentHit(
          line: line, col: col, len: name.len,
          access: peekAccessBefore(content, start)))
      i = j
      continue
    inc i

proc sameLocal*(a, b: LocalBinding): bool =
  a.name == b.name and a.declLine == b.declLine and a.declCol == b.declCol and
    a.container == b.container

proc locationJson(uri: string, line, col, nameLen: int): JsonNode =
  %*{
    "uri": uri,
    "range": {
      "start": {"line": line, "character": col},
      "end": {"line": line, "character": col + nameLen}
    }
  }

proc lookupMemberAt(doc: DocumentState, name: string, line, col: int): tuple[ok: bool, m: MemberInfo] =
  ## Prefer member decl under cursor; else member if access is .name / ::name on that line.
  result.ok = false
  for m in doc.members:
    if m.name != name: continue
    if m.line == line and col >= m.col and col <= m.col + name.len:
      result.ok = true
      result.m = m
      return
  # Dot / :: access: any member with this name (ambiguous if multiple parents —
  # pick first; refine if line has Parent. or Parent::)
  let lines = doc.content.split("\n")
  if line < 0 or line >= lines.len: return
  let l = lines[line]
  var wordStart = min(col, l.len)
  while wordStart > 0 and l[wordStart - 1] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
    dec wordStart
  # Find parent type name before `.` or `::`
  var parentHint = ""
  var k = wordStart - 1
  while k >= 0 and l[k] in {' ', '\t'}: dec k
  if k >= 0 and l[k] == '.':
    var p = k - 1
    while p >= 0 and l[p] in {' ', '\t'}: dec p
    var pe = p
    while p >= 0 and l[p] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      dec p
    if pe > p:
      parentHint = l[p + 1 .. pe]
  elif k >= 1 and l[k] == ':' and l[k - 1] == ':':
    var p = k - 2
    while p >= 0 and l[p] in {' ', '\t'}: dec p
    var pe = p
    while p >= 0 and l[p] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      dec p
    if pe > p:
      parentHint = l[p + 1 .. pe]

  for m in doc.members:
    if m.name != name: continue
    if parentHint.len > 0 and m.parent != parentHint: continue
    result.ok = true
    result.m = m
    if parentHint.len > 0:
      return
  # If no parent hint and only one member with this name, use it
  var count = 0
  var last: MemberInfo
  for m in doc.members:
    if m.name == name:
      inc count
      last = m
  if count == 1:
    result.ok = true
    result.m = last

proc classifyRenameTarget(doc: DocumentState, word: string, line, col: int): RenameTarget =
  result.kind = rtkUnknown
  result.name = word
  ensureAnalyzed(doc)
  if doc.locals.len == 0 and doc.content.len > 0:
    enrichWithSema(doc)

  # 1) Type member (field/variant) when cursor is on decl or qualified access
  let (mok, mem) = lookupMemberAt(doc, word, line, col)
  if mok:
    # Prefer member over local if this is clearly a member access or member decl
    let lines = doc.content.split("\n")
    var isMemberCtx = false
    if line >= 0 and line < lines.len:
      let l = lines[line]
      var ws = min(col, l.len)
      while ws > 0 and l[ws - 1] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
        dec ws
      let absStart = block:
        var off = 0
        for li in 0 ..< line:
          off += lines[li].len + 1
        off + ws
      let acc = peekAccessBefore(doc.content, absStart)
      isMemberCtx = acc in {iaDot, iaColonColon, iaFieldInit} or
                    (mem.line == line and mem.col == ws)
    if isMemberCtx or not lookupLocalAt(doc, word, line).ok:
      result.kind = rtkMember
      result.parent = mem.parent
      result.memberKind = mem.kind
      result.declLine = mem.line
      result.declCol = mem.col
      return

  # 2) Local / param (scoped)
  let (lok, lb) = lookupLocalAt(doc, word, line)
  if lok:
    result.kind = rtkLocal
    result.local = lb
    return

  # 3) Global / type / function
  if doc.symbols.hasKey(word) or doc.typeIndex.hasKey(word) or workspaceSymbols.hasKey(word):
    result.kind = rtkGlobal
    return

  result.kind = rtkUnknown

proc hitMatchesMember(h: IdentHit, m: MemberInfo): bool =
  ## Member rename: decl, .name, ::name, and field init `name:` — not bare locals.
  if h.line == m.line and h.col == m.col:
    return true
  case h.access
  of iaDot, iaColonColon, iaFieldInit:
    return true
  of iaBare:
    return false

proc collectReferences(doc: DocumentState, word: string, lineNum: int,
                       includeDecl: bool, col: int = 0): seq[JsonNode] =
  ## Collect LSP Location nodes for references at `word` on `lineNum`.
  result = @[]
  if word.len == 0: return
  ensureAnalyzed(doc)
  if doc.locals.len == 0 and doc.content.len > 0:
    enrichWithSema(doc)

  let target = classifyRenameTarget(doc, word, lineNum, col)
  let hits = collectIdentHits(doc.content, word)

  case target.kind
  of rtkLocal:
    for h in hits:
      let (ok, b) = lookupLocalAt(doc, word, h.line)
      if not ok or not sameLocal(b, target.local):
        continue
      if not includeDecl and h.line == target.local.declLine and h.col == target.local.declCol:
        continue
      result.add(locationJson(doc.uri, h.line, h.col, h.len))
    return

  of rtkMember:
    let m = MemberInfo(
      name: target.name, parent: target.parent, kind: target.memberKind,
      line: target.declLine, col: target.declCol)
    for h in hits:
      if not hitMatchesMember(h, m):
        continue
      if not includeDecl and h.line == m.line and h.col == m.col:
        continue
      result.add(locationJson(doc.uri, h.line, h.col, h.len))
    # Workspace: other files may reference Parent::name or .name
    var seenUri = initHashSet[string]()
    seenUri.incl(doc.uri)
    for u, d in documents.pairs:
      if d.content.len == 0 or seenUri.contains(u): continue
      seenUri.incl(u)
      ensureAnalyzed(d)
      for h in collectIdentHits(d.content, word):
        if hitMatchesMember(h, m):
          result.add(locationJson(u, h.line, h.col, h.len))
    return

  of rtkGlobal, rtkUnknown:
    let isFileSym = doc.symbols.hasKey(word) or doc.typeIndex.hasKey(word)
    let isWsSym = workspaceSymbols.hasKey(word)
    if not isFileSym and not isWsSym and target.kind == rtkUnknown:
      for h in hits:
        # Unknown bare rename: only bare idents (avoid eating .x members)
        if h.access == iaBare:
          result.add(locationJson(doc.uri, h.line, h.col, h.len))
      return

    for h in hits:
      if not includeDecl and doc.symbols.hasKey(word):
        let info = doc.symbols[word]
        if h.line == info.line and h.col == info.col:
          continue
      # Global type/func rename: bare + ::qualified, not .member of other types
      if h.access == iaDot:
        continue
      result.add(locationJson(doc.uri, h.line, h.col, h.len))

    if isWsSym or isFileSym:
      var seenUri = initHashSet[string]()
      seenUri.incl(doc.uri)
      for u, d in documents.pairs:
        if d.content.len == 0 or seenUri.contains(u): continue
        seenUri.incl(u)
        for h in collectIdentHits(d.content, word):
          if h.access == iaDot: continue
          result.add(locationJson(u, h.line, h.col, h.len))
      if rootPath.len > 0 and dirExists(rootPath):
        var stack: seq[tuple[dir: string, depth: int]] = @[(rootPath, 0)]
        while stack.len > 0:
          let (dir, depth) = stack.pop()
          if depth > 4: continue
          let base = dir.extractFilename
          if base in [".git", "build", "examples_pkg", "node_modules", "vendor", "nimcache"]:
            continue
          try:
            for kind, path in walkDir(dir):
              if kind == pcDir:
                stack.add((path, depth + 1))
              elif kind == pcFile and path.endsWith(".bux"):
                let u = pathToUri(path.absolutePath)
                if seenUri.contains(u): continue
                seenUri.incl(u)
                try:
                  let text = readFile(path)
                  for h in collectIdentHits(text, word):
                    if h.access == iaDot: continue
                    result.add(locationJson(u, h.line, h.col, h.len))
                except CatchableError:
                  discard
          except CatchableError:
            discard

proc handleReferences(stream: FileStream, id: JsonNode, paramsNode: JsonNode) =
  let uri = paramsNode["textDocument"]["uri"].getStr()
  let position = paramsNode["position"]
  let lineNum = position["line"].getInt()
  let col = position["character"].getInt()
  var includeDecl = true
  if paramsNode.hasKey("context") and paramsNode["context"].hasKey("includeDeclaration"):
    includeDecl = paramsNode["context"]["includeDeclaration"].getBool()

  let doc = getDoc(uri)
  if doc.content == "":
    sendResponse(stream, id, %*[])
    return

  let word = findWordAt(doc.content, lineNum, col)
  if word.len == 0:
    sendResponse(stream, id, %*[])
    return

  var arr = newJArray()
  for loc in collectReferences(doc, word, lineNum, includeDecl, col):
    arr.add(loc)
  sendResponse(stream, id, arr)

proc isValidIdentName(s: string): bool =
  if s.len == 0: return false
  if not isIdentStart(s[0]): return false
  for i in 1 ..< s.len:
    if not isIdentChar(s[i]): return false
  true

proc handlePrepareRename(stream: FileStream, id: JsonNode, paramsNode: JsonNode) =
  let uri = paramsNode["textDocument"]["uri"].getStr()
  let position = paramsNode["position"]
  let lineNum = position["line"].getInt()
  let col = position["character"].getInt()
  let doc = getDoc(uri)
  if doc.content == "":
    sendResponse(stream, id, newJNull())
    return
  let lines = doc.content.split("\n")
  if lineNum >= lines.len:
    sendResponse(stream, id, newJNull())
    return
  let l = lines[lineNum]
  var start = min(col, l.len)
  var endC = start
  while start > 0 and l[start - 1] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
    dec start
  while endC < l.len and l[endC] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
    inc endC
  if start >= endC:
    sendResponse(stream, id, newJNull())
    return
  let word = l[start ..< endC]
  # Reject keywords
  const kws = ["func", "var", "let", "if", "else", "while", "for", "return",
               "struct", "enum", "true", "false", "null", "self", "match",
               "import", "module", "type", "const", "pub", "own"]
  if word in kws:
    sendResponse(stream, id, newJNull())
    return
  sendResponse(stream, id, %*{
    "range": {
      "start": {"line": lineNum, "character": start},
      "end": {"line": lineNum, "character": endC}
    },
    "placeholder": word
  })

proc handleRename(stream: FileStream, id: JsonNode, paramsNode: JsonNode) =
  let uri = paramsNode["textDocument"]["uri"].getStr()
  let position = paramsNode["position"]
  let lineNum = position["line"].getInt()
  let col = position["character"].getInt()
  let newName = if paramsNode.hasKey("newName"): paramsNode["newName"].getStr() else: ""

  if not isValidIdentName(newName):
    sendError(stream, id, -32602, "invalid identifier: '" & newName & "'")
    return

  let doc = getDoc(uri)
  if doc.content == "":
    sendResponse(stream, id, %*{"changes": newJObject()})
    return

  let word = findWordAt(doc.content, lineNum, col)
  if word.len == 0:
    sendResponse(stream, id, %*{"changes": newJObject()})
    return
  if word == newName:
    sendResponse(stream, id, %*{"changes": newJObject()})
    return

  let refs = collectReferences(doc, word, lineNum, includeDecl = true, col = col)
  # Group TextEdits by URI
  var byUri = initTable[string, JsonNode]()
  for loc in refs:
    let u = loc["uri"].getStr()
    if not byUri.hasKey(u):
      byUri[u] = newJArray()
    let r = loc["range"]
    byUri[u].add(%*{
      "range": r,
      "newText": newName
    })

  var changes = newJObject()
  for u, edits in byUri.pairs:
    changes[u] = edits

  sendResponse(stream, id, %*{"changes": changes})

# ---------------------------------------------------------------------------
# Document symbols (outline)
# ---------------------------------------------------------------------------

proc symbolKindLsp(kind: string): int =
  case kind
  of "function": 12
  of "variable": 13
  of "constant": 14
  of "struct": 23
  of "enum": 10
  of "interface": 11
  of "type": 5
  of "module": 2
  else: 13

proc handleDocumentSymbol(stream: FileStream, id: JsonNode, paramsNode: JsonNode) =
  let uri = paramsNode["textDocument"]["uri"].getStr()
  let doc = getDoc(uri)
  if doc.content == "":
    sendResponse(stream, id, %*[])
    return
  ensureAnalyzed(doc)
  var arr = newJArray()
  for name in doc.ordered:
    if not doc.symbols.hasKey(name):
      continue
    let info = doc.symbols[name]
    arr.add(%*{
      "name": name,
      "detail": info.detail,
      "kind": symbolKindLsp(info.kind),
      "range": {
        "start": {"line": info.line, "character": 0},
        "end": {"line": info.line, "character": info.col + name.len}
      },
      "selectionRange": {
        "start": {"line": info.line, "character": info.col},
        "end": {"line": info.line, "character": info.col + name.len}
      }
    })
  sendResponse(stream, id, arr)

proc handleWorkspaceSymbol(stream: FileStream, id: JsonNode, paramsNode: JsonNode) =
  ## workspace/symbol — fuzzy-ish substring filter over workspace + open docs.
  let query = if paramsNode.hasKey("query"): paramsNode["query"].getStr().toLowerAscii() else: ""
  var arr = newJArray()
  var seen = initHashSet[string]()  # name@uri

  proc maybeAdd(name, uri: string, info: SymbolInfo) =
    if query.len > 0 and query notin name.toLowerAscii() and
       query notin info.detail.toLowerAscii() and
       query notin info.kind.toLowerAscii():
      return
    let key = name & "@" & uri
    if seen.contains(key): return
    seen.incl(key)
    var item = %*{
      "name": name,
      "kind": symbolKindLsp(info.kind),
      "location": {
        "uri": uri,
        "range": {
          "start": {"line": info.line, "character": info.col},
          "end": {"line": info.line, "character": info.col + name.len}
        }
      }
    }
    if info.detail.len > 0:
      item["containerName"] = %info.kind
    arr.add(item)

  # Open documents first (freshest)
  for uri, doc in documents.pairs:
    ensureAnalyzed(doc)
    for name, info in doc.symbols.pairs:
      maybeAdd(name, uri, info)

  # Workspace index from scan
  for name, ws in workspaceSymbols.pairs:
    maybeAdd(name, ws.uri, ws.info)

  # Cap result size for IDE responsiveness
  if arr.len > 200:
    var capped = newJArray()
    var i = 0
    while i < 200:
      capped.add(arr[i])
      inc i
    arr = capped

  sendResponse(stream, id, arr)

# ---------------------------------------------------------------------------
# Main message loop
# ---------------------------------------------------------------------------

proc handleMessage(stream: FileStream, msg: JsonNode) =
  if not msg.hasKey("method"):
    return
  
  let methodName = msg["method"].getStr()
  let id = if msg.hasKey("id"): msg["id"] else: nil
  let paramsNode = if msg.hasKey("params"): msg["params"] else: %*{}
  
  case methodName:
  of "initialize":
    sendResponse(stream, id, %*{
      "capabilities": {
        "textDocumentSync": 1,
        "completionProvider": {"triggerCharacters": [".", ":"]},
        "definitionProvider": true,
        "hoverProvider": true,
        "documentSymbolProvider": true,
        "referencesProvider": true,
        "renameProvider": {"prepareProvider": true},
        "workspaceSymbolProvider": true
      },
      "serverInfo": {"name": "bux-lsp", "version": "0.7.0"}
    })
    if paramsNode.hasKey("rootPath") and paramsNode["rootPath"].kind != JNull:
      rootPath = paramsNode["rootPath"].getStr()
    if paramsNode.hasKey("rootUri") and paramsNode["rootUri"].kind != JNull:
      rootUri = paramsNode["rootUri"].getStr()
      if rootPath.len == 0:
        rootPath = uriToPath(rootUri)
    # Preload stdlib for hover types
    if rootPath.len > 0:
      ensureStdlibCached()

  of "initialized":
    if rootPath.len > 0:
      scanWorkspace(rootPath)
      ensureStdlibCached()
  
  of "shutdown":
    sendResponse(stream, id, %*{})
  
  of "exit":
    quit(0)
  
  of "textDocument/didOpen":
    let td = paramsNode["textDocument"]
    let uri = td["uri"].getStr()
    let content = td["text"].getStr()
    var doc = getDoc(uri)
    doc.content = content
    if td.hasKey("version"):
      doc.version = td["version"].getInt()
    # Lightweight scan + sema enrich + buxc diagnostics
    analyzeAndPublishDiagnostics(stream, doc)
  
  of "textDocument/didChange":
    let td = paramsNode["textDocument"]
    let uri = td["uri"].getStr()
    var doc = getDoc(uri)
    let changes = paramsNode["contentChanges"]
    if changes.len > 0:
      doc.content = changes[changes.len - 1]["text"].getStr()
    if td.hasKey("version"):
      doc.version = td["version"].getInt()
    # Fast path: lightweight symbols only; keep previous typeIndex until save/hover refresh
    let updated = analyzeFile(uriToPath(uri), doc.content)
    doc.symbols = updated.symbols
    doc.ordered = updated.ordered
    doc.members = updated.members
    # Re-apply typeIndex details onto matching names (don't drop sema types mid-edit)
    for name, detail in doc.typeIndex.pairs:
      if doc.symbols.hasKey(name):
        var info = doc.symbols[name]
        info.detail = detail
        info.fromSema = true
        if doc.kindIndex.hasKey(name):
          info.kind = doc.kindIndex[name]
        doc.symbols[name] = info

  of "textDocument/didSave":
    let td = paramsNode["textDocument"]
    let uri = td["uri"].getStr()
    discard getDoc(uri)
    analyzeAndPublishDiagnostics(stream, getDoc(uri))

  of "textDocument/completion":
    handleCompletion(stream, id, paramsNode)

  of "textDocument/definition":
    handleDefinition(stream, id, paramsNode)

  of "textDocument/hover":
    handleHover(stream, id, paramsNode)

  of "textDocument/documentSymbol":
    handleDocumentSymbol(stream, id, paramsNode)

  of "textDocument/references":
    handleReferences(stream, id, paramsNode)

  of "textDocument/prepareRename":
    handlePrepareRename(stream, id, paramsNode)

  of "textDocument/rename":
    handleRename(stream, id, paramsNode)

  of "workspace/symbol":
    handleWorkspaceSymbol(stream, id, paramsNode)

  else:
    if id != nil:
      sendError(stream, id, -32601, "method not found: " & methodName)

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

proc main() =
  let stream = newFileStream(stdin)
  
  while true:
    let msg = readMessage(stream)
    if msg == nil:
      break
    handleMessage(stream, msg)

when isMainModule:
  main()
