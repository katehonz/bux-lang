import std/[strutils, os, tables]

type
  PackageType* = enum
    ptExecutable
    ptSharedLibrary
    ptStaticLibrary
    ptSource

  Manifest* = object
    name*: string
    version*: string
    pkgType*: PackageType
    output*: string          ## from [Build] Output
    dependencies*: OrderedTableRef[string, string]

type
  TomlValueKind = enum
    tvkString, tvkTable
  TomlValue = object
    case kind*: TomlValueKind
    of tvkString:
      strVal*: string
    of tvkTable:
      tableVal*: OrderedTableRef[string, TomlValue]

proc parseSimpleToml(path: string): OrderedTableRef[string, TomlValue] =
  result = newOrderedTable[string, TomlValue]()
  if not fileExists(path):
    return result
  let content = readFile(path)
  var currentTable = ""
  for rawLine in content.splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    if line.startsWith("[") and line.endsWith("]"):
      currentTable = line[1 ..< ^1]
      if not result.hasKey(currentTable):
        result[currentTable] = TomlValue(kind: tvkTable, tableVal: newOrderedTable[string, TomlValue]())
    else:
      let eqIdx = line.find('=')
      if eqIdx >= 0:
        let key = line[0 ..< eqIdx].strip()
        var val = line[eqIdx + 1 .. ^1].strip()
        # Remove surrounding quotes
        if val.len >= 2 and val[0] == '"' and val[^1] == '"':
          val = val[1 ..< ^1]
        if currentTable != "" and result.hasKey(currentTable):
          result[currentTable].tableVal[key] = TomlValue(kind: tvkString, strVal: val)
        else:
          result[key] = TomlValue(kind: tvkString, strVal: val)

proc loadManifest*(path: string): Manifest =
  let data = parseSimpleToml(path)
  result.name = ""
  result.version = "0.1.0"
  result.pkgType = ptExecutable
  result.output = "Bin"
  result.dependencies = newOrderedTable[string, string]()

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
