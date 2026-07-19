## fmt.nim — Indentation-based Bux source formatter (bootstrap).
## Mirrors selfhost `src/fmt.bux`: re-indent by brace depth, preserve content.

import std/[strutils, os, algorithm]

proc isInStringOrComment(line: string, pos: int): bool =
  ## Simplified: track `//`, `"..."`, and `'...'` up to `pos`.
  var inString = false
  var inChar = false
  var inComment = false
  var i = 0
  while i < pos and i < line.len:
    let c = line[i]
    let n = if i + 1 < line.len: line[i + 1] else: '\0'
    if inComment:
      inc i
      continue
    if c == '/' and n == '/':
      inComment = true
      inc i
      continue
    if c == '"' and not inChar:
      inString = not inString
    if c == '\'' and not inString:
      inChar = not inChar
    inc i
  return inString or inChar or inComment

proc countBraceDelta(line: string): int =
  var delta = 0
  for i in 0 ..< line.len:
    if isInStringOrComment(line, i):
      continue
    let c = line[i]
    if c == '{':
      inc delta
    elif c == '}':
      dec delta
  return delta

proc formatSource*(source: string): string =
  ## Re-indent each non-empty line to 4 spaces × brace depth.
  ## Idempotent: formatting a clean file is a no-op.
  var sb: string
  var indent = 0
  # Nim's splitLines leaves a trailing "" when the source ends with '\n'.
  # Drop that artifact so we don't accumulate blank lines on re-format.
  var lines = source.splitLines(keepEol = false)
  if source.len > 0 and source.endsWith('\n') and lines.len > 0 and lines[^1].len == 0:
    lines.setLen(lines.len - 1)
  for line in lines:
    let trimmed = line.strip(leading = true, trailing = false)
    if trimmed.len == 0:
      sb.add('\n')
      continue

    let delta = countBraceDelta(trimmed)
    let firstChar = trimmed[0]
    if firstChar == '}':
      dec indent
      if indent < 0:
        indent = 0

    for _ in 0 ..< indent:
      sb.add("    ")
    sb.add(trimmed)
    sb.add('\n')

    if firstChar != '}':
      indent = indent + delta
    else:
      # Net delta after the initial decrease for a leading `}`
      indent = indent + delta + 1
      if indent < 0:
        indent = 0

  return sb

proc formatFile*(path: string, checkOnly: bool): tuple[ok: bool, changed: bool, msg: string] =
  ## Format `path` in place, or only check if reformatting would change it.
  if not fileExists(path):
    return (false, false, "file not found: " & path)
  let source = readFile(path)
  let formatted = formatSource(source)
  if formatted == source:
    return (true, false, "")
  if checkOnly:
    return (true, true, "would reformat")
  try:
    writeFile(path, formatted)
    return (true, true, "formatted")
  except CatchableError as e:
    return (false, false, e.msg)

proc collectBuxFiles*(root: string): seq[string] =
  ## Collect `.bux` files: single file, or recursive directory walk.
  result = @[]
  if fileExists(root) and root.endsWith(".bux"):
    result.add(root)
    return
  if not dirExists(root):
    return
  for path in walkDirRec(root):
    if path.endsWith(".bux"):
      result.add(path)
  result.sort(system.cmp)
