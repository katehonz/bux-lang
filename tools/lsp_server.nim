# lsp_server.nim — Bux Language Server Protocol implementation
# Communicates via stdin/stdout JSON-RPC 2.0
#
# Usage: bux-lsp
# The editor spawns this binary and communicates via stdin/stdout.

import std/[json, os, strutils, streams, tables, osproc]

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
  DocumentState = ref object
    uri: string
    content: string
    version: int
    symbols: Table[string, SymbolInfo]
    ordered: seq[string]   ## declaration order for outline

var
  documents = initTable[string, DocumentState]()
  rootPath = ""
  rootUri = ""
  workspaceSymbols = initTable[string, tuple[uri: string, info: SymbolInfo]]()

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
  ## Hover with accurate range for the word under the cursor.
  let uri = paramsNode["textDocument"]["uri"].getStr()
  let position = paramsNode["position"]
  let lineNum = position["line"].getInt()
  let col = position["character"].getInt()

  let doc = getDoc(uri)
  if doc.content == "":
    sendResponse(stream, id, newJNull())
    return

  ensureAnalyzed(doc)
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

  var info: SymbolInfo
  var found = false
  if doc.symbols.hasKey(word):
    info = doc.symbols[word]
    found = true
  elif workspaceSymbols.hasKey(word):
    info = workspaceSymbols[word].info
    found = true
  if not found:
    sendResponse(stream, id, newJNull())
    return

  let md = "```bux\n" & info.detail & "\n```\n\n_" & info.kind & "_"
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
      "serverInfo": {"name": "bux-lsp", "version": "0.2.0"}
    })
    if paramsNode.hasKey("rootPath") and paramsNode["rootPath"].kind != JNull:
      rootPath = paramsNode["rootPath"].getStr()
    if paramsNode.hasKey("rootUri") and paramsNode["rootUri"].kind != JNull:
      rootUri = paramsNode["rootUri"].getStr()
      if rootPath.len == 0:
        rootPath = uriToPath(rootUri)

  of "initialized":
    if rootPath.len > 0:
      scanWorkspace(rootPath)
  
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
    # Refresh symbols immediately (no buxc — diagnostics on save)
    let updated = analyzeFile(uriToPath(uri), doc.content)
    doc.symbols = updated.symbols
    doc.ordered = updated.ordered

  of "textDocument/didSave":
    let td = paramsNode["textDocument"]
    let uri = td["uri"].getStr()
    let doc = getDoc(uri)
    analyzeAndPublishDiagnostics(stream, doc)

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
