type
  SourceLocation* = object
    line*: uint32      ## 1-based
    column*: uint32    ## 1-based (UTF-8 byte offset in line)
    offset*: uint32    ## byte offset from start of file

proc `$`*(loc: SourceLocation): string =
  $loc.line & ":" & $loc.column
