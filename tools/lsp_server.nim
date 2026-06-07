# lsp_server.nim — Bux Language Server Protocol implementation
# Communicates via stdin/stdout JSON-RPC 2.0
#
# Usage: bux-lsp
# The editor spawns this binary and communicates via stdin/stdout.

import std/[json, os, strutils, streams, tables]

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
  let body = $msg
  let header = "Content-Length: " & $body.len & "\r\n\r\n"
  stream.write(header)
  stream.write(body)
  stream.flush()

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
  SymbolInfo = tuple[line: int, col: int, kind: string, typeName: string]
  DocumentState = ref object
    uri: string
    content: string
    version: int
    symbols: Table[string, SymbolInfo]

var
  documents = initTable[string, DocumentState]()
  rootPath = ""
  rootUri = ""

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
  else:
    result = uri

# ---------------------------------------------------------------------------
# Simple analysis: extract symbols via regex (no full compiler integration yet)
# ---------------------------------------------------------------------------

proc analyzeFile(path: string, content: string): DocumentState =
  result = DocumentState(uri: "file://" & path, content: content)
  
  # Simple symbol extraction: find func/var/let/struct/enum declarations
  var idx = 0
  var line = 0
  var col = 0
  for ch in content:
    if ch == '\n':
      line += 1
      col = 0
      idx += 1
      continue
    col += 1
    idx += 1
  
  # Use string-based pattern matching for common Bux declarations
  var i = 0
  var currLine = 0
  var currCol = 0
  while i < content.len:
    let c = content[i]
    if c == '\n':
      currLine += 1
      currCol = 0
      i += 1
      continue
    currCol += 1
    
    # Match "func Name"
    if content[i..min(i+4, content.len-1)] == "func ":
      var start = i + 5
      var name = ""
      while start < content.len and content[start] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
        name &= content[start]
        start += 1
      if name != "":
        result.symbols[name] = (line: currLine, col: currCol + 5, kind: "function", typeName: "")
        i = start
        continue
    
    # Match "var Name" or "let Name"
    if i + 3 < content.len and (content[i..i+2] == "var " or content[i..i+2] == "let "):
      let kwEnd = if content[i] == 'v': i + 4 else: i + 4
      var name = ""
      var start = kwEnd
      while start < content.len and content[start] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
        name &= content[start]
        start += 1
      if name != "" and name != "":
        result.symbols[name] = (line: currLine, col: currCol + kwEnd - i, kind: "variable", typeName: "")
        i = start
        continue
    
    # Match "struct Name"
    if i + 6 < content.len and content[i..i+5] == "struct ":
      var name = ""
      var start = i + 7
      while start < content.len and content[start] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
        name &= content[start]
        start += 1
      if name != "":
        result.symbols[name] = (line: currLine, col: currCol + 7, kind: "struct", typeName: "")
        i = start
        continue
    
    i += 1

# ---------------------------------------------------------------------------
# Diagnostics (placeholder — emits empty diagnostics)
# ---------------------------------------------------------------------------

proc publishDiagnostics(stream: FileStream, uri: string) =
  sendNotification(stream, "textDocument/publishDiagnostics", %*{
    "uri": uri,
    "diagnostics": []
  })

proc analyzeAndPublishDiagnostics(stream: FileStream, doc: DocumentState) =
  let updated = analyzeFile(uriToPath(doc.uri), doc.content)
  doc.symbols = updated.symbols
  publishDiagnostics(stream, doc.uri)

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

proc handleCompletion(stream: FileStream, id: JsonNode, paramsNode: JsonNode) =
  let uri = paramsNode["textDocument"]["uri"].getStr()
  let position = paramsNode["position"]
  let lineNum = position["line"].getInt()
  let col = position["character"].getInt()
  
  let doc = getDoc(uri)
  if doc.content == "":
    sendResponse(stream, id, %*{"isIncomplete": false, "items": []})
    return
  
  if doc.symbols.len == 0:
    let updated = analyzeFile(uriToPath(uri), doc.content)
    doc.symbols = updated.symbols
  
  let prefix = findWordAt(doc.content, lineNum, col)
  
  var items = newJArray()
  for name, info in doc.symbols.pairs:
    if prefix == "" or name.toLowerAscii().startsWith(prefix.toLowerAscii()):
      items.add(%*{
        "label": name,
        "kind": 6,
        "detail": info.typeName,
        "documentation": info.kind & " [" & info.typeName & "]"
      })
  
  let keywords = ["func", "var", "let", "if", "else", "while", "for", "return",
                  "struct", "enum", "union", "interface", "extend", "module",
                  "import", "true", "false", "null", "self", "match", "break",
                  "continue", "async", "await", "spawn", "const", "type"]
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
  
  if doc.symbols.len == 0:
    let updated = analyzeFile(uriToPath(uri), doc.content)
    doc.symbols = updated.symbols
  
  let word = findWordAt(doc.content, lineNum, col)
  
  if doc.symbols.hasKey(word):
    let info = doc.symbols[word]
    var locs = newJArray()
    locs.add(%*{
      "uri": uri,
      "range": {
        "start": {"line": info.line, "character": info.col},
        "end": {"line": info.line, "character": info.col + word.len}
      }
    })
    sendResponse(stream, id, locs)
  else:
    sendResponse(stream, id, %*[])

# ---------------------------------------------------------------------------
# Hover
# ---------------------------------------------------------------------------

proc handleHover(stream: FileStream, id: JsonNode, paramsNode: JsonNode) =
  let uri = paramsNode["textDocument"]["uri"].getStr()
  let position = paramsNode["position"]
  let lineNum = position["line"].getInt()
  let col = position["character"].getInt()
  
  let doc = getDoc(uri)
  if doc.content == "":
    sendResponse(stream, id, %*{})
    return
  
  if doc.symbols.len == 0:
    let updated = analyzeFile(uriToPath(uri), doc.content)
    doc.symbols = updated.symbols
  
  let word = findWordAt(doc.content, lineNum, col)
  
  if doc.symbols.hasKey(word):
    let info = doc.symbols[word]
    sendResponse(stream, id, %*{
      "contents": {
        "kind": "markdown",
        "value": "**" & word & "**: " & info.typeName & "\n\n" & info.kind
      }
    })
  else:
    sendResponse(stream, id, %*{})

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
        "completionProvider": {"triggerCharacters": ["."]},
        "definitionProvider": true,
        "hoverProvider": true
      },
      "serverInfo": {"name": "bux-lsp", "version": "0.1.0"}
    })
    if paramsNode.hasKey("rootPath") and paramsNode["rootPath"].kind != JNull:
      rootPath = paramsNode["rootPath"].getStr()
    if paramsNode.hasKey("rootUri") and paramsNode["rootUri"].kind != JNull:
      rootUri = paramsNode["rootUri"].getStr()
  
  of "initialized":
    discard
  
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
