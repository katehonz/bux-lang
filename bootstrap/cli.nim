import std/[os, strutils, terminal, strformat, osproc, sets]
import lexer, parser, ast, sema, manifest, hir_lower, lir_lower, lir_c_backend
import source_location

type
  ColorMode* = enum
    cmAuto
    cmOn
    cmOff

  GlobalOptions* = object
    color*: ColorMode
    quiet*: bool
    verbose*: bool

proc printUsage*() =
  echo """Bux Programming Language (bootstrap compiler)

Usage: bux [options] <command> [command-options]

Commands:
  new <name>          Create a new Bux package
  init                Initialize a Bux package in the current directory
  add <name> [ver]    Add a dependency (--path, --git)
  install             Resolve and install dependencies
  build               Build the current package
  run                 Build and run the current package
  test                Run tests in tests/ directory
  check               Type-check the current package
  clean               Remove build artifacts
  help                Show this help message
  version             Show version

Global options:
  --color <auto|on|off>   Control colored output (default: auto)
  -q, --quiet             Suppress non-error output
  -v, --verbose           Verbose output
"""

proc parseGlobalOptions(args: seq[string]): tuple[opts: GlobalOptions, rest: seq[string], ok: bool] =
  result.opts = GlobalOptions(color: cmAuto, quiet: false, verbose: false)
  result.rest = @[]
  result.ok = true
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--color":
      if i + 1 >= args.len:
        stderr.writeLine("error: --color requires an argument")
        result.ok = false
        return
      inc i
      case args[i].toLowerAscii()
      of "auto": result.opts.color = cmAuto
      of "on": result.opts.color = cmOn
      of "off": result.opts.color = cmOff
      else:
        stderr.writeLine(&"error: unknown --color value '{args[i]}'")
        result.ok = false
        return
    elif arg == "-q" or arg == "--quiet":
      result.opts.quiet = true
    elif arg == "-v" or arg == "--verbose":
      result.opts.verbose = true
    else:
      result.rest.add(arg)
    inc i

proc shouldUseColor(opts: GlobalOptions): bool =
  case opts.color
  of cmOn: true
  of cmOff: false
  of cmAuto: terminal.isatty(stdout)

proc printError(msg: string, useColor: bool) =
  if useColor:
    stdout.setForegroundColor(fgRed)
    stdout.write("error: ")
    stdout.resetAttributes()
    stdout.writeLine(msg)
  else:
    stderr.writeLine("error: " & msg)

proc printInfo(msg: string, useColor: bool) =
  if useColor:
    stdout.setForegroundColor(fgCyan)
    stdout.write("info: ")
    stdout.resetAttributes()
    stdout.writeLine(msg)
  else:
    echo("info: " & msg)

# ---------------------------------------------------------------------------
# Rust-style diagnostics (snippet + optional help hint)
# ---------------------------------------------------------------------------

proc getSourceLine(path: string, lineNum: uint32): string =
  ## Read a single 1-based line from path. Empty if unavailable.
  if path.len == 0 or lineNum == 0 or not fileExists(path):
    return ""
  try:
    let content = readFile(path)
    var n: uint32 = 1
    for line in content.splitLines():
      if n == lineNum:
        return line
      inc n
  except CatchableError:
    discard
  return ""

proc extractQuotedName(msg: string): string =
  ## Pull the first 'name' from messages like: undeclared identifier 'foo'
  let a = msg.find('\'')
  if a < 0: return ""
  let b = msg.find('\'', a + 1)
  if b <= a + 1: return ""
  return msg[a + 1 .. b - 1]

proc underlineLength(lineText: string, col: uint32, message: string): int =
  ## Multi-character underline under the token at `col` (1-based).
  ## Falls back to scanning a source token, or matching a quoted name in the message.
  if lineText.len == 0:
    return 1
  let start = if col > 0: int(col) - 1 else: 0
  if start < 0 or start >= lineText.len:
    return 1

  # Prefer highlighting the quoted identifier/token from the message when it
  # appears on this line (e.g. undeclared identifier 'foo').
  let quoted = extractQuotedName(message)
  if quoted.len > 0:
    let idx = lineText.find(quoted)
    if idx >= 0:
      # If caret is on/near that token, use its full length
      if abs(idx - start) <= quoted.len:
        return quoted.len

  let c0 = lineText[start]
  # String / char / backtick literals
  if c0 == '"' or c0 == '\'' or c0 == '`':
    let quote = c0
    var i = start + 1
    while i < lineText.len:
      if lineText[i] == '\\' and i + 1 < lineText.len:
        i += 2
        continue
      if lineText[i] == quote:
        return i - start + 1
      inc i
    return max(1, lineText.len - start)

  # Identifier or keyword
  if c0.isAlphaAscii or c0 == '_':
    var i = start
    while i < lineText.len and (lineText[i].isAlphaNumeric or lineText[i] == '_'):
      inc i
    return max(1, i - start)

  # Number literal
  if c0.isDigit:
    var i = start
    while i < lineText.len and (lineText[i].isDigit or lineText[i] in {'.', 'x', 'X', 'b', 'B', 'o', 'O', 'a'..'f', 'A'..'F', '_'}):
      inc i
    # optional type suffix: 42i64, 1.0f
    while i < lineText.len and lineText[i] in {'i', 'u', 'f', 'I', 'U', 'F', '0'..'9'}:
      inc i
    return max(1, i - start)

  # Multi-char operators starting at caret
  const multiOps = ["<<=", ">>=", "**", "++", "--", "==", "!=", "<=", ">=",
                    "&&", "||", "<<", ">>", "+=", "-=", "*=", "/=", "%=",
                    "&=", "|=", "^=", "=>", "..", "->"]
  for op in multiOps:
    if start + op.len <= lineText.len and lineText[start .. start + op.len - 1] == op:
      return op.len

  return 1

proc hintForMessage(msg: string): string =
  ## Actionable help text for common compiler errors.
  let m = msg.toLowerAscii()
  if "while it is mutably borrowed" in m:
    return "only one active '&mut' borrow is allowed at a time; end the borrow before reuse"
  if "cannot assign" in m:
    return "ensure the right-hand side type matches the left-hand side"
  if "undeclared identifier" in m:
    return "check the spelling, or import the symbol from the right module"
  if "too few arguments" in m or "too many arguments" in m:
    return "compare the call with the function's parameter list"
  if "missing argument for parameter" in m:
    return "provide the missing argument (positional or named)"
  if "use of moved value" in m:
    return "the value was moved; clone it or restructure ownership"
  if "shared reference" in m or "checked function" in m:
    return "use '&mut T' for mutation, or drop @[Checked] for unchecked code"
  if "double mutable borrow" in m or "already mutably borrowed" in m:
    return "only one active '&mut' borrow is allowed at a time; end the borrow before reuse"
  if "shared-borrow" in m or "shared-borrowed" in m:
    return "exclusive '&mut' and shared '&' cannot overlap on the same variable"
  if "expected expression" in m:
    return "the previous statement may be incomplete (missing value or ';')"
  if "expected type" in m:
    return "write a type name such as 'int', 'String', or 'Array<int>'"
  if "expected field name" in m:
    return "after '.' use an identifier or a tuple index (.0, .1, ...)"
  if "does not implement trait" in m:
    return "add an 'extend Type for Trait { ... }' block, or pick another type"
  if "duplicate symbol" in m:
    return "rename one of the definitions or remove the duplicate"
  if "unterminated" in m:
    return "check for a missing closing quote, backtick, or comment delimiter"
  return ""

proc printDiagnostic*(severity: string, message: string, loc: SourceLocation,
                      useColor: bool, fallbackFile: string = "") =
  ## Print a Rust-style diagnostic:
  ##   error: message
  ##     --> file:line:col
  ##      |
  ##   42 | source line
  ##      |        ^
  ##      = help: hint
  let isError = severity == "error"
  if useColor:
    stdout.setForegroundColor(if isError: fgRed else: fgYellow)
    stdout.write(severity & ": ")
    stdout.resetAttributes()
    stdout.writeLine(message)
  else:
    let stream = if isError: stderr else: stdout
    stream.writeLine(severity & ": " & message)

  let file = if loc.file.len > 0: loc.file else: fallbackFile
  if loc.line > 0:
    let locStr = if file.len > 0:
      &"{file}:{loc.line}:{loc.column}"
    else:
      &"{loc.line}:{loc.column}"
    if useColor:
      stdout.setForegroundColor(fgCyan)
      stdout.write("  --> ")
      stdout.resetAttributes()
      stdout.writeLine(locStr)
    else:
      stderr.writeLine("  --> " & locStr)

    let lineText = getSourceLine(file, loc.line)
    if lineText.len > 0:
      let gutter = $loc.line
      let pad = " ".repeat(max(gutter.len, 3))
      # If message names a quoted token, prefer caret at that token's start
      var col = loc.column
      let quoted = extractQuotedName(message)
      if quoted.len > 0:
        let idx = lineText.find(quoted)
        if idx >= 0:
          col = uint32(idx + 1)
      let ulen = underlineLength(lineText, col, message)
      stdout.writeLine(pad & " |")
      stdout.writeLine(" " & gutter & " | " & lineText)
      # Multi-char underline under the token (1-based column)
      var caretPad = ""
      if col > 0:
        caretPad = " ".repeat(int(col) - 1)
      let marks = "^".repeat(max(1, ulen))
      stdout.writeLine(pad & " | " & caretPad & marks)

  let hint = hintForMessage(message)
  if hint.len > 0:
    if useColor:
      stdout.setForegroundColor(fgGreen)
      stdout.write("   = help: ")
      stdout.resetAttributes()
      stdout.writeLine(hint)
    else:
      stdout.writeLine("   = help: " & hint)

proc printLexerDiags(diags: seq[LexerDiagnostic], useColor: bool, fallbackFile = "") =
  for d in diags:
    let sev = if d.severity == ldsError: "error" else: "warning"
    printDiagnostic(sev, d.message, d.loc, useColor, fallbackFile)

proc printParserDiags(diags: seq[ParserDiagnostic], useColor: bool, fallbackFile = "") =
  for d in diags:
    let sev = if d.severity == pdsError: "error" else: "warning"
    printDiagnostic(sev, d.message, d.loc, useColor, fallbackFile)

proc printSemaDiags(diags: seq[SemaDiagnostic], useColor: bool, fallbackFile = "") =
  for d in diags:
    let sev = if d.severity == sdsError: "error" else: "warning"
    printDiagnostic(sev, d.message, d.loc, useColor, fallbackFile)

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

proc cmdNew*(args: seq[string], opts: GlobalOptions): int =
  let useColor = shouldUseColor(opts)
  if args.len < 1:
    printError("'new' requires a package name", useColor)
    return 1
  let name = args[0]
  let root = getCurrentDir() / name
  if dirExists(root):
    printError(&"directory '{name}' already exists", useColor)
    return 1
  createDir(root / "src")
  writeFile(root / "bux.toml", &"""[Package]
Name    = "{name}"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
""")
  writeFile(root / "src" / "Main.bux", """import Std::Io::PrintLine;

func Main() -> int {
    PrintLine(c8"Hello, Bux!");
    return 0;
}
""")
  if not opts.quiet:
    printInfo(&"Created Bux package '{name}'", useColor)
  return 0

proc cmdInit*(args: seq[string], opts: GlobalOptions): int =
  let useColor = shouldUseColor(opts)
  let root = getCurrentDir()
  if fileExists(root / "bux.toml"):
    printError("bux.toml already exists", useColor)
    return 1
  let name = splitPath(root).tail
  writeFile(root / "bux.toml", &"""[Package]
Name    = "{name}"
Version = "0.1.0"
Type    = "bin"

[Build]
Output = "Bin"
""")
  if not dirExists(root / "src"):
    createDir(root / "src")
  if not opts.quiet:
    printInfo(&"Initialized Bux package '{name}'", useColor)
  return 0

proc cmdAdd*(args: seq[string], opts: GlobalOptions): int =
  let useColor = shouldUseColor(opts)
  let root = getCurrentDir()
  let manifestPath = root / "bux.toml"
  if not fileExists(manifestPath):
    printError("no bux.toml found", useColor)
    return 1
  if args.len == 0:
    printError("usage: bux add <name> [version] [--path <path>] [--git <url>]", useColor)
    return 1
  let depName = args[0]
  var version = "*"
  var path = ""
  var gitUrl = ""
  var i = 1
  while i < args.len:
    case args[i]
    of "--path":
      if i + 1 < args.len:
        path = args[i + 1]
        inc i
      else:
        printError("--path requires a value", useColor)
        return 1
    of "--git":
      if i + 1 < args.len:
        gitUrl = args[i + 1]
        inc i
      else:
        printError("--git requires a value", useColor)
        return 1
    else:
      version = args[i]
    inc i
  # Append to bux.toml
  var depLine = ""
  if path.len > 0:
    depLine = &"{depName} = {{ Path = \"{path}\" }}"
  elif gitUrl.len > 0:
    depLine = &"{depName} = {{ Version = \"{version}\", Source = \"{gitUrl}\" }}"
  else:
    depLine = &"{depName} = \"{version}\""
  var content = readFile(manifestPath)
  # Ensure [Dependencies] section exists
  if content.find("[Dependencies]") < 0:
    content.add("\n[Dependencies]\n")
  # Append dependency line
  content.add(depLine & "\n")
  writeFile(manifestPath, content)
  if not opts.quiet:
    printInfo(&"Added dependency '{depName}' to bux.toml", useColor)
  return 0

proc cmdInstall*(args: seq[string], opts: GlobalOptions): int =
  let useColor = shouldUseColor(opts)
  let root = getCurrentDir()
  let manifestPath = root / "bux.toml"
  if not fileExists(manifestPath):
    printError("no bux.toml found", useColor)
    return 1
  let man = loadManifest(manifestPath)
  var lock = Lockfile(entries: @[])
  let cacheDir = getHomeDir() / ".bux" / "packages"
  if not dirExists(cacheDir):
    createDir(cacheDir)
  # Resolve each dependency
  for dep in man.dependencies:
    case dep.kind
    of dkPath:
      let absPath = if dep.path.isAbsolute: dep.path else: root / dep.path
      if not dirExists(absPath):
        printError(&"path dependency not found: {absPath}", useColor)
        return 1
      # Read dependency manifest
      let depManifestPath = absPath / "bux.toml"
      if fileExists(depManifestPath):
        let depMan = loadManifest(depManifestPath)
        lock.entries.add(LockEntry(name: dep.name, version: depMan.version, source: absPath))
      else:
        lock.entries.add(LockEntry(name: dep.name, version: "0.0.0", source: absPath))
      if not opts.quiet:
        printInfo(&"Resolved path dependency '{dep.name}' from {absPath}", useColor)
    of dkGit:
      let depDir = cacheDir / dep.name
      if not dirExists(depDir):
        if not opts.quiet:
          printInfo(&"Cloning '{dep.name}' from {dep.gitUrl}...", useColor)
        let (outp, code) = execCmdEx(&"git clone {dep.gitUrl} {depDir} 2>&1")
        if code != 0:
          printError(&"failed to clone {dep.gitUrl}: {outp}", useColor)
          return 1
      else:
        if not opts.quiet:
          printInfo(&"Using cached '{dep.name}' from {depDir}", useColor)
      lock.entries.add(LockEntry(name: dep.name, version: dep.gitVersion, source: dep.gitUrl))
    of dkVersion:
      # For version-based deps without a registry, we just record them
      # TODO: lookup in registry
      lock.entries.add(LockEntry(name: dep.name, version: dep.versionReq, source: "registry"))
      if not opts.quiet:
        printInfo(&"Recorded dependency '{dep.name}' = {dep.versionReq}", useColor)
  # Save lockfile
  let lockPath = root / "bux.lock"
  saveLockfile(lockPath, lock)
  if not opts.quiet:
    printInfo(&"Generated {lockPath}", useColor)
  return 0

proc collectStdlibDecls(stdlibDir: string): seq[Decl]
proc getDeclName(d: Decl): string
proc mergeDecls(stdlibDecls: seq[Decl], userDecls: seq[Decl]): seq[Decl]
proc collectDepDecls(lock: Lockfile, root: string, opts: GlobalOptions): seq[Decl]

proc findStdlibDir(root: string): string =
  let searchPaths = @[
    getAppDir() / ".." / "lib",
    getAppDir() / "lib",
    root / "lib",
  ]
  for path in searchPaths:
    if dirExists(path):
      return path
  return ""

type
  ProjectContext = object
    root: string
    man: Manifest
    stdlibDir: string
    stdlibDecls: seq[Decl]
    depDecls: seq[Decl]
    allModuleItems: seq[Decl]
    hasMain: bool

proc prepareProject(root: string, useColor: bool, opts: GlobalOptions): (ProjectContext, int) =
  var pctx: ProjectContext
  pctx.root = root
  let manifestPath = root / "bux.toml"
  if not fileExists(manifestPath):
    printError("no bux.toml found", useColor)
    return (pctx, 1)
  pctx.man = loadManifest(manifestPath)
  let srcDir = root / "src"
  if not dirExists(srcDir):
    printError("no src/ directory found", useColor)
    return (pctx, 1)

  pctx.stdlibDir = findStdlibDir(root)
  pctx.stdlibDecls = collectStdlibDecls(pctx.stdlibDir)
  let lock = loadLockfile(root / "bux.lock")
  pctx.depDecls = collectDepDecls(lock, root, opts)

  pctx.allModuleItems = @[]
  pctx.hasMain = false
  for kind, path in walkDir(srcDir):
    if kind == pcFile and path.endsWith(".bux"):
      let source = readFile(path)
      let lexRes = tokenize(source, path)
      if lexRes.hasErrors:
        printError(&"lex errors in {path}", useColor)
        printLexerDiags(lexRes.diagnostics, useColor, path)
        return (pctx, 1)
      let parseRes = parse(lexRes.tokens, path)
      if parseRes.diagnostics.len > 0:
        printError(&"parse errors in {path}", useColor)
        printParserDiags(parseRes.diagnostics, useColor, path)
        return (pctx, 1)
      for decl in parseRes.module.items:
        if decl.kind == dkModule:
          for sub in decl.declModuleItems:
            pctx.allModuleItems.add(sub)
        else:
          pctx.allModuleItems.add(decl)
      if splitFile(path).name == "Main":
        pctx.hasMain = true

  if not pctx.hasMain:
    printError("no Main.bux found in src/", useColor)
    return (pctx, 1)

  return (pctx, 0)

proc mergeProject(pctx: ProjectContext): Module =
  let stdlibAndDeps = mergeDecls(pctx.stdlibDecls, pctx.depDecls)
  let mergedItems = mergeDecls(stdlibAndDeps, pctx.allModuleItems)
  var unifiedModule = newModule("main")
  unifiedModule.items = mergedItems
  return unifiedModule

proc cmdCheck*(args: seq[string], opts: GlobalOptions): int =
  let useColor = shouldUseColor(opts)
  let root = if args.len > 0: absolutePath(args[0]) else: getCurrentDir()
  let (pctx, status) = prepareProject(root, useColor, opts)
  if status != 0:
    return status
  let unifiedModule = mergeProject(pctx)
  let semaRes = analyze(unifiedModule)
  if semaRes.hasErrors:
    printError("type errors in project", useColor)
    printSemaDiags(semaRes.diagnostics, useColor)
    return 1
  if not opts.quiet:
    printInfo("check passed", useColor)
  return 0

proc collectStdlibDecls(stdlibDir: string): seq[Decl] =
  result = @[]
  if not dirExists(stdlibDir): return
  for path in walkDirRec(stdlibDir):
    if path.endsWith(".bux"):
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

proc getDeclName(d: Decl): string =
  case d.kind
  of dkFunc: d.declFuncName
  of dkExternFunc: d.declExtFuncName
  of dkStruct: d.declStructName
  of dkEnum: d.declEnumName
  of dkUnion: d.declUnionName
  of dkInterface: d.declInterfaceName
  of dkConst: d.declConstName
  of dkTypeAlias: d.declAliasName
  else: ""

proc collectDepDecls(lock: Lockfile, root: string, opts: GlobalOptions): seq[Decl] =
  ## Collect declarations from all locked dependencies.
  let cacheDir = getHomeDir() / ".bux" / "packages"
  let useColor = shouldUseColor(opts)
  for entry in lock.entries:
    var depSrcDir = ""
    if dirExists(entry.source):
      # Path-based dependency
      depSrcDir = entry.source / "src"
    elif entry.source.startsWith("http") or entry.source.startsWith("git@"):
      # Git-based dependency in cache
      depSrcDir = cacheDir / entry.name / "src"
    if depSrcDir == "" or not dirExists(depSrcDir):
      continue
    for kind, path in walkDir(depSrcDir):
      if kind == pcFile and path.endsWith(".bux"):
        let source = readFile(path)
        let lexRes = tokenize(source, path)
        if lexRes.hasErrors:
          continue
        let parseRes = parse(lexRes.tokens, path)
        if parseRes.diagnostics.len > 0:
          continue
        for decl in parseRes.module.items:
          if decl.kind == dkModule:
            for sub in decl.declModuleItems:
              result.add(sub)
          else:
            result.add(decl)
    if not opts.quiet:
      printInfo(&"Loaded dependency '{entry.name}' from {depSrcDir}", useColor)

proc mergeDecls(stdlibDecls: seq[Decl], userDecls: seq[Decl]): seq[Decl] =
  ## Merge stdlib and user declarations.
  ## User funcs shadow stdlib funcs with the same name (simple overload avoidance).
  var userNames: HashSet[string]
  for d in userDecls:
    let name = getDeclName(d)
    if name != "":
      userNames.incl(name)
  result = @[]
  for d in stdlibDecls:
    let name = getDeclName(d)
    if name == "" or name notin userNames:
      result.add(d)
  for d in userDecls:
    result.add(d)

proc cmdBuild*(args: seq[string], opts: GlobalOptions): int =
  let useColor = shouldUseColor(opts)
  let root = if args.len > 0: absolutePath(args[0]) else: getCurrentDir()
  let (pctx, status) = prepareProject(root, useColor, opts)
  if status != 0:
    return status

  # Create build directory
  let buildDir = root / "build"
  if not dirExists(buildDir):
    createDir(buildDir)

  let unifiedModule = mergeProject(pctx)

  # Phase 3: Sema + HIR + C codegen on unified module
  let (semaRes, semaCtx) = analyzeFull(unifiedModule)
  if semaRes.hasErrors:
    printError("type errors in project", useColor)
    printSemaDiags(semaRes.diagnostics, useColor)
    return 1
  
  let hirMod = lowerModule(unifiedModule, semaCtx)
  let lirBuilder = lowerModuleToLir(hirMod)
  var lirCbe = initLirCBackend()
  var allCCode = lirCbe.emitModule(lirBuilder, hirMod)

  # Write C file
  let cFile = buildDir / "main.c"
  writeFile(cFile, allCCode)

  # Copy runtime files (rt/ is sibling of lib/)
  let stdlibDir = pctx.stdlibDir
  let runtimeDst = buildDir / "runtime.c"
  let ioDst = buildDir / "io.c"
  if stdlibDir == "":
    printError("stdlib directory not found", useColor)
    return 1

  let baseDir = stdlibDir.parentDir()
  let runtimeSrc = baseDir / "rt" / "runtime.c"
  if fileExists(runtimeSrc):
    copyFile(runtimeSrc, runtimeDst)
  else:
    printError("runtime.c not found in rt/", useColor)
    return 1

  let ioSrc = baseDir / "rt" / "io.c"
  if fileExists(ioSrc):
    copyFile(ioSrc, ioDst)
  else:
    printError("io.c not found in rt/", useColor)
    return 1

  # Compile with cc
  let outputName = if pctx.man.name != "": pctx.man.name else: "bux_out"
  let outputFile = buildDir / outputName
  let ccCmd = &"cc -O0 -g -pthread -Wl,--build-id=none -o {outputFile} {cFile} {runtimeDst} {ioDst} -lm -lcrypto 2>&1"
  if opts.verbose:
    printInfo(&"running: {ccCmd}", useColor)
  let (output, exitCode) = execCmdEx(ccCmd)
  if exitCode != 0:
    printError("C compilation failed:", useColor)
    echo output
    return 1

  if not opts.quiet:
    printInfo(&"build: {outputFile}", useColor)
  return 0

proc cmdRun*(args: seq[string], opts: GlobalOptions): int =
  let useColor = shouldUseColor(opts)
  let root = if args.len > 0: absolutePath(args[0]) else: getCurrentDir()
  let buildRes = cmdBuild(args, opts)
  if buildRes != 0:
    return buildRes
  let man = loadManifest(root / "bux.toml")
  let outputName = if man.name != "": man.name else: "bux_out"
  let outputFile = root / "build" / outputName
  if not fileExists(outputFile):
    printError("executable not found after build", useColor)
    return 1
  let exitCode = execCmd(outputFile)
  return exitCode

proc cmdClean*(args: seq[string], opts: GlobalOptions): int =
  let useColor = shouldUseColor(opts)
  let root = getCurrentDir()
  let buildDir = root / "build"
  if dirExists(buildDir):
    removeDir(buildDir)
  if not opts.quiet:
    printInfo("clean: build directory removed", useColor)
  return 0

proc cmdTest*(args: seq[string], opts: GlobalOptions): int =
  let useColor = shouldUseColor(opts)
  let root = getCurrentDir()
  let testsDir = root / "tests"
  var testFiles: seq[string] = @[]
  if dirExists(testsDir):
    for kind, path in walkDir(testsDir):
      if kind == pcFile and path.endsWith(".bux"):
        testFiles.add(path)
  if testFiles.len == 0:
    printError("no tests found in tests/ directory", useColor)
    return 1
  var passed = 0
  var failed = 0
  for testFile in testFiles:
    let testName = splitFile(testFile).name
    let tmpDir = getTempDir() / "bux_test_" & testName
    removeDir(tmpDir)
    createDir(tmpDir / "src")
    copyFile(testFile, tmpDir / "src" / "Main.bux")
    writeFile(tmpDir / "bux.toml", "[package]\nname = \"" & testName & "\"\nversion = \"0.1.0\"\n")
    let buildRes = cmdBuild(@[tmpDir], opts)
    if buildRes != 0:
      printError(&"  FAIL {testName} (build)", useColor)
      failed += 1
      continue
    var execFile = tmpDir / "build" / testName
    if not fileExists(execFile):
      execFile = tmpDir / "build" / "bux_out"
    let exitCode = execCmd(execFile)
    if exitCode == 0:
      printInfo(&"  PASS {testName}", useColor)
      passed += 1
    else:
      printError(&"  FAIL {testName} (exit {exitCode})", useColor)
      failed += 1
    removeDir(tmpDir)
  echo &"\nResults: {passed} passed, {failed} failed"
  return if failed > 0: 1 else: 0

proc cmdVersion*(args: seq[string], opts: GlobalOptions): int =
  echo "bux 0.1.0 (bootstrap)"
  return 0

proc runCli*(args: seq[string]): int =
  let (opts, rest, ok) = parseGlobalOptions(args)
  if not ok:
    return 1
  if rest.len == 0:
    printUsage()
    return 0

  let cmd = rest[0]
  let cmdArgs = if rest.len > 1: rest[1..^1] else: @[]

  case cmd
  of "new": return cmdNew(cmdArgs, opts)
  of "init": return cmdInit(cmdArgs, opts)
  of "add": return cmdAdd(cmdArgs, opts)
  of "install": return cmdInstall(cmdArgs, opts)
  of "build": return cmdBuild(cmdArgs, opts)
  of "run": return cmdRun(cmdArgs, opts)
  of "check": return cmdCheck(cmdArgs, opts)
  of "test": return cmdTest(cmdArgs, opts)
  of "clean": return cmdClean(cmdArgs, opts)
  of "version", "--version", "-v": return cmdVersion(cmdArgs, opts)
  of "help", "--help", "-h":
    printUsage()
    return 0
  else:
    let useColor = shouldUseColor(opts)
    printError(&"unknown command '{cmd}'", useColor)
    return 1
