# lsp_server.nim — Bux Language Server Protocol implementation
# Communicates via stdin/stdout JSON-RPC 2.0
#
# Usage: bux-lsp
# The editor spawns this binary and communicates via stdin/stdout.
#
# Hover uses real bootstrap sema types when possible (globals + stdlib);
# completion/outline still use a fast lightweight scan.

import std/[json, os, strutils, streams, tables, osproc, sequtils]
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
  DocumentState = ref object
    uri: string
    content: string
    version: int
    symbols: Table[string, SymbolInfo]
    ordered: seq[string]   ## declaration order for outline
    ## Full-project type index for hover (includes stdlib after sema enrich)
    typeIndex: Table[string, string]   ## name → type / signature string
    kindIndex: Table[string, string]   ## name → kind label

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

proc analyzeFile(path: string, content: string): DocumentState =
  result = DocumentState(uri: pathToUri(path), content: content)
  result.symbols = initTable[string, SymbolInfo]()
  result.ordered = @[]

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
    result = "&" & typeExprToStr(te.pointerPointee)
  of tekMutRef:
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

    # Walk this file's AST for local lets with explicit types (function bodies)
    proc walkBlock(blk: Block, container: string) =
      if blk == nil: return
      for stmt in blk.stmts:
        case stmt.kind
        of skLet:
          let n = stmt.stmtLetName
          if n.len == 0: continue
          var typStr = ""
          if stmt.stmtLetType != nil:
            typStr = typeExprToStr(stmt.stmtLetType)
          let kw = if stmt.stmtLetMut: "var" else: "let"
          let detail = if typStr.len > 0: kw & " " & n & ": " & typStr else: kw & " " & n
          let loc = stmt.loc
          let line = max(0, int(loc.line) - 1)
          let col = max(0, int(loc.column) - 1)
          # Prefer sema-enriched detail if name already global; else add local
          if not doc.symbols.hasKey(n) or not doc.symbols[n].fromSema:
            doc.symbols[n] = SymbolInfo(
              line: line, col: col, kind: "variable", detail: detail,
              container: container, fromSema: typStr.len > 0)
            if n notin doc.ordered:
              doc.ordered.add(n)
          if typStr.len > 0:
            doc.typeIndex[n] = detail
            doc.kindIndex[n] = "variable"
        of skExpr:
          if stmt.stmtExpr != nil and stmt.stmtExpr.kind == ekBlock:
            walkBlock(stmt.stmtExpr.exprBlock, container)
        of skIf:
          walkBlock(stmt.stmtIfThen, container)
          walkBlock(stmt.stmtIfElse, container)
          for br in stmt.stmtIfElseIfs:
            walkBlock(br.blk, container)
        of skWhile:
          walkBlock(stmt.stmtWhileBody, container)
        of skFor:
          walkBlock(stmt.stmtForBody, container)
        of skLoop:
          walkBlock(stmt.stmtLoopBody, container)
        else:
          discard

    for d in parseRes.module.items:
      if d.kind == dkFunc and d.declFuncBody != nil:
        walkBlock(d.declFuncBody, d.declFuncName)
      elif d.kind == dkModule:
        for sub in d.declModuleItems:
          if sub.kind == dkFunc and sub.declFuncBody != nil:
            walkBlock(sub.declFuncBody, sub.declFuncName)

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
  let prefix = findWordAt(doc.content, lineNum, col)

  var items = newJArray()
  for name, info in doc.symbols.pairs:
    if prefix == "" or name.toLowerAscii().startsWith(prefix.toLowerAscii()):
      items.add(%*{
        "label": name,
        "kind": completionKind(info.kind),
        "detail": info.detail,
        "documentation": {"kind": "markdown", "value": "```bux\n" & info.detail & "\n```\n\n_" & info.kind & "_"}
      })

  # Also offer workspace symbols (other open / scanned files)
  for name, ws in workspaceSymbols.pairs:
    if doc.symbols.hasKey(name):
      continue
    if prefix == "" or name.toLowerAscii().startsWith(prefix.toLowerAscii()):
      items.add(%*{
        "label": name,
        "kind": completionKind(ws.info.kind),
        "detail": ws.info.detail & "  (workspace)",
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
        "detail": "keyword"
      })

  sendResponse(stream, id, %*{"isIncomplete": false, "items": items})

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
  let word = findWordAt(doc.content, lineNum, col)
  if word.len == 0:
    sendResponse(stream, id, %*[])
    return

  var locs = newJArray()
  if doc.symbols.hasKey(word):
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
  if doc.typeIndex.len == 0 and doc.content.len > 0:
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

  # Prefer file-local symbol (may be sema-upgraded)
  if doc.symbols.hasKey(word):
    let info = doc.symbols[word]
    detail = info.detail
    kind = info.kind
    found = true
    # Prefer pure sema typeIndex when richer
    if doc.typeIndex.hasKey(word) and doc.typeIndex[word].len >= detail.len:
      detail = doc.typeIndex[word]
      if doc.kindIndex.hasKey(word):
        kind = doc.kindIndex[word]
  elif doc.typeIndex.hasKey(word):
    detail = doc.typeIndex[word]
    kind = if doc.kindIndex.hasKey(word): doc.kindIndex[word] else: "symbol"
    found = true
  elif workspaceSymbols.hasKey(word):
    let info = workspaceSymbols[word].info
    detail = info.detail
    kind = info.kind
    found = true

  if not found:
    sendResponse(stream, id, newJNull())
    return

  var md = "```bux\n" & detail & "\n```\n\n_" & kind & "_"
  if doc.symbols.hasKey(word) and doc.symbols[word].fromSema:
    md &= " · sema"
  elif doc.typeIndex.hasKey(word):
    md &= " · sema"

  sendResponse(stream, id, %*{
    "contents": {"kind": "markdown", "value": md},
    "range": {
      "start": {"line": lineNum, "character": start},
      "end": {"line": lineNum, "character": endC}
    }
  })

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
        "documentSymbolProvider": true
      },
      "serverInfo": {"name": "bux-lsp", "version": "0.3.0"}
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
