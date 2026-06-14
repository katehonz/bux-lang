import std/[strutils, os, tables, strformat]

type
  PackageType* = enum
    ptExecutable
    ptSharedLibrary
    ptStaticLibrary
    ptSource

  DepKind* = enum
    dkVersion       ## "1.0" or "*"
    dkPath          ## { Path = "../Lib" }
    dkGit           ## { Version = "1.4", Source = "https://..." }

  Dependency* = object
    name*: string
    case kind*: DepKind
    of dkVersion:
      versionReq*: string
    of dkPath:
      path*: string
    of dkGit:
      gitUrl*: string
      gitVersion*: string

  Manifest* = object
    name*: string
    version*: string
    pkgType*: PackageType
    output*: string
    dependencies*: seq[Dependency]
    devDependencies*: seq[Dependency]
    buildDependencies*: seq[Dependency]

# ---------------------------------------------------------------------------
# Extended TOML parser (supports inline tables and arrays)
# ---------------------------------------------------------------------------

type
  TomlValueKind = enum
    tvkString, tvkTable, tvkArray, tvkInlineTable
  TomlValue = object
    case kind*: TomlValueKind
    of tvkString:
      strVal*: string
    of tvkTable:
      tableVal*: OrderedTableRef[string, TomlValue]
    of tvkArray:
      arrayVal*: seq[TomlValue]
    of tvkInlineTable:
      inlineVal*: OrderedTableRef[string, TomlValue]

proc parseInlineTable(s: string): OrderedTableRef[string, TomlValue] =
  result = newOrderedTable[string, TomlValue]()
  var content = s.strip()
  if content.len >= 2 and content[0] == '{' and content[^1] == '}':
    content = content[1 ..< ^1].strip()
  var i = 0
  while i < content.len:
    # skip whitespace
    while i < content.len and content[i] in Whitespace:
      inc i
    if i >= content.len: break
    # parse key
    var keyStart = i
    while i < content.len and content[i] notin {'=', ' ', '\t'}:
      inc i
    let key = content[keyStart ..< i].strip()
    # skip to =
    while i < content.len and content[i] in Whitespace:
      inc i
    if i >= content.len or content[i] != '=': break
    inc i
    while i < content.len and content[i] in Whitespace:
      inc i
    # parse value
    var valStart = i
    if i < content.len and content[i] == '"':
      inc i
      while i < content.len and content[i] != '"':
        inc i
      if i < content.len: inc i
      let val = content[valStart + 1 ..< i - 1]
      result[key] = TomlValue(kind: tvkString, strVal: val)
    elif i < content.len and content[i] == '{':
      # nested inline table (skip for now)
      var braceCount = 1
      inc i
      while i < content.len and braceCount > 0:
        if content[i] == '{': inc braceCount
        elif content[i] == '}': dec braceCount
        inc i
      result[key] = TomlValue(kind: tvkInlineTable, inlineVal: newOrderedTable[string, TomlValue]())
    else:
      while i < content.len and content[i] notin {',', ' ', '\t'}:
        inc i
      let val = content[valStart ..< i].strip()
      result[key] = TomlValue(kind: tvkString, strVal: val)
    # skip to comma or end
    while i < content.len and content[i] in Whitespace:
      inc i
    if i < content.len and content[i] == ',':
      inc i

proc parseArray(s: string): seq[TomlValue] =
  result = @[]
  var content = s.strip()
  if content.len >= 2 and content[0] == '[' and content[^1] == ']':
    content = content[1 ..< ^1].strip()
  if content.len == 0: return
  for item in content.split(','):
    let val = item.strip()
    if val.len >= 2 and val[0] == '"' and val[^1] == '"':
      result.add(TomlValue(kind: tvkString, strVal: val[1 ..< ^1]))
    else:
      result.add(TomlValue(kind: tvkString, strVal: val))

proc parseValue(valStr: string): TomlValue =
  let val = valStr.strip()
  if val.len >= 2 and val[0] == '"' and val[^1] == '"':
    return TomlValue(kind: tvkString, strVal: val[1 ..< ^1])
  elif val.len >= 2 and val[0] == '[' and val[^1] == ']':
    return TomlValue(kind: tvkArray, arrayVal: parseArray(val))
  elif val.len >= 2 and val[0] == '{' and val[^1] == '}':
    return TomlValue(kind: tvkInlineTable, inlineVal: parseInlineTable(val))
  else:
    return TomlValue(kind: tvkString, strVal: val)

proc parseToml*(path: string): OrderedTableRef[string, TomlValue] =
  result = newOrderedTable[string, TomlValue]()
  if not fileExists(path):
    return result
  let content = readFile(path)
  var currentTable = ""
  var currentArrayTable = ""
  for rawLine in content.splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    if line.startsWith("[[") and line.endsWith("]]"):
      # Array of tables
      currentArrayTable = line[2 ..< ^2]
      currentTable = ""
      let newTable = TomlValue(kind: tvkTable, tableVal: newOrderedTable[string, TomlValue]())
      if not result.hasKey(currentArrayTable):
        result[currentArrayTable] = TomlValue(kind: tvkArray, arrayVal: @[newTable])
      else:
        result[currentArrayTable].arrayVal.add(newTable)
    elif line.startsWith("[") and line.endsWith("]"):
      currentTable = line[1 ..< ^1]
      currentArrayTable = ""
      if not result.hasKey(currentTable):
        result[currentTable] = TomlValue(kind: tvkTable, tableVal: newOrderedTable[string, TomlValue]())
    else:
      let eqIdx = line.find('=')
      if eqIdx >= 0:
        let key = line[0 ..< eqIdx].strip()
        let valStr = line[eqIdx + 1 .. ^1].strip()
        let val = parseValue(valStr)
        if currentArrayTable != "" and result.hasKey(currentArrayTable):
          let arr = result[currentArrayTable].arrayVal
          if arr.len > 0:
            arr[^1].tableVal[key] = val
        elif currentTable != "" and result.hasKey(currentTable):
          result[currentTable].tableVal[key] = val
        else:
          result[key] = val

proc parseDepTable(table: OrderedTableRef[string, TomlValue]): seq[Dependency] =
  result = @[]
  for name, val in table:
    case val.kind
    of tvkString:
      result.add(Dependency(name: name, kind: dkVersion, versionReq: val.strVal))
    of tvkInlineTable:
      let t = val.inlineVal
      if t.hasKey("Path"):
        result.add(Dependency(name: name, kind: dkPath, path: t["Path"].strVal))
      elif t.hasKey("Source"):
        var ver = "*"
        if t.hasKey("Version"):
          ver = t["Version"].strVal
        result.add(Dependency(name: name, kind: dkGit, gitUrl: t["Source"].strVal, gitVersion: ver))
      elif t.hasKey("Version"):
        result.add(Dependency(name: name, kind: dkVersion, versionReq: t["Version"].strVal))
      else:
        result.add(Dependency(name: name, kind: dkVersion, versionReq: "*"))
    else:
      discard

# ---------------------------------------------------------------------------
# Lockfile
# ---------------------------------------------------------------------------

type
  LockEntry* = object
    name*: string
    version*: string
    source*: string
    checksum*: string

  Lockfile* = object
    entries*: seq[LockEntry]

proc loadLockfile*(path: string): Lockfile =
  result.entries = @[]
  if not fileExists(path):
    return result
  let data = parseToml(path)
  if data.hasKey("Package"):
    let arr = data["Package"]
    if arr.kind == tvkArray:
      for item in arr.arrayVal:
        if item.kind == tvkTable:
          let t = item.tableVal
          var entry = LockEntry()
          if t.hasKey("Name"): entry.name = t["Name"].strVal
          if t.hasKey("Version"): entry.version = t["Version"].strVal
          if t.hasKey("Source"): entry.source = t["Source"].strVal
          if t.hasKey("Checksum"): entry.checksum = t["Checksum"].strVal
          result.entries.add(entry)

proc saveLockfile*(path: string, lock: Lockfile) =
  var lines: seq[string] = @[]
  for entry in lock.entries:
    lines.add("[[Package]]")
    lines.add(&"Name = \"{entry.name}\"")
    lines.add(&"Version = \"{entry.version}\"")
    lines.add(&"Source = \"{entry.source}\"")
    if entry.checksum.len > 0:
      lines.add(&"Checksum = \"{entry.checksum}\"")
    lines.add("")
  writeFile(path, lines.join("\n"))

# ---------------------------------------------------------------------------
# Manifest loader
# ---------------------------------------------------------------------------

proc loadManifest*(path: string): Manifest =
  let data = parseToml(path)
  result.name = ""
  result.version = "0.1.0"
  result.pkgType = ptExecutable
  result.output = "Bin"
  result.dependencies = @[]
  result.devDependencies = @[]
  result.buildDependencies = @[]

  if data.hasKey("Package"):
    let pkg = data["Package"].tableVal
    if pkg.hasKey("Name"):
      result.name = pkg["Name"].strVal
    if pkg.hasKey("Version"):
      result.version = pkg["Version"].strVal
    if pkg.hasKey("Type"):
      case pkg["Type"].strVal.toLowerAscii()
      of "bin", "executable": result.pkgType = ptExecutable
      of "shared", "sharedlibrary", "dll", "so", "dylib": result.pkgType = ptSharedLibrary
      of "static", "staticlibrary", "lib", "a": result.pkgType = ptStaticLibrary
      of "source": result.pkgType = ptSource
      else: result.pkgType = ptExecutable

  if data.hasKey("Build"):
    let bld = data["Build"].tableVal
    if bld.hasKey("Output"):
      result.output = bld["Output"].strVal

  if data.hasKey("Dependencies"):
    result.dependencies = parseDepTable(data["Dependencies"].tableVal)
  if data.hasKey("DevDependencies"):
    result.devDependencies = parseDepTable(data["DevDependencies"].tableVal)
  if data.hasKey("BuildDependencies"):
    result.buildDependencies = parseDepTable(data["BuildDependencies"].tableVal)
