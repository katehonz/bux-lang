type
  SourceLocation* = object
    line*: uint32      ## 1-based
    column*: uint32    ## 1-based (UTF-8 byte offset in line)
    offset*: uint32    ## byte offset from start of file
    file*: string      ## source file path (empty if unknown)

proc `$`*(loc: SourceLocation): string =
  if loc.file.len > 0:
    loc.file & ":" & $loc.line & ":" & $loc.column
  else:
    $loc.line & ":" & $loc.column
