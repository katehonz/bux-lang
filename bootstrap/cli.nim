import std/[os, strutils, terminal, strformat, osproc, sets, algorithm, tables, sha1]
import lexer, parser, ast, sema, manifest, hir_lower, lir_lower, lir_c_backend
import source_location
import fmt
import docgen
import registry
import macroexpand

type
  ColorMode* = enum
    cmAuto
    cmOn
    cmOff

  ## Which C runtime shim to link (session 75 — Linux / cloud / embedded).
  RuntimeFlavor* = enum
    rfFull       ## rt/runtime.c — POSIX + OpenSSL
    rfMinimal    ## rt/runtime_minimal.c — thin, static/container/embed friendly
    rfWin        ## rt/runtime_win.c — Windows/MinGW (historical)

  GlobalOptions* = object
    color*: ColorMode
    quiet*: bool
    verbose*: bool
    release*: bool    ## --release: -O2, no -g / no #line (E.4 dual)
    staticLink*: bool ## --static: fully-static binary (implies thin runtime unless full)
    target*: string   ## --target <triple>: cross-compile (e.g. aarch64-linux-gnu)

proc printUsage*() =
  echo """Bux Programming Language (bootstrap compiler)

Usage: bux [options] <command> [command-options]

Commands:
  new <name>          Create a new Bux package
  init                Initialize a Bux package in the current directory
  add <name> [ver]    Add a dependency (--path, --git, or registry)
  install             Resolve and install dependencies
  search [query]      Search the package registry
  build               Build the current package
  run                 Build and run the current package
  test                Run tests in tests/ directory
  check               Type-check the current package
  fmt [path]          Format .bux sources (default: .)
  doc [path]          Generate Markdown API docs from /// comments
  clean               Remove build artifacts
  help                Show this help message
  version             Show version

Command options:
  test --filter <s>   Only run tests whose name contains <s>
  fmt  --check        Exit 1 if any file would be reformatted (CI)
  doc  --out <file>   Write docs to file (default: stdout)
  add  --path / --git Explicit source; else resolve via registry
  install --locked    Verify bux.lock only (CI; no re-resolve)
  build --release     Optimized build (-O2, no debug / #line)
  build --static      Fully-static link (uses minimal runtime; no OpenSSL)
  build --target T    Cross-compile triple (prefers T-gcc, else clang -target)

Registry / toolchain env:
  BUX_REGISTRY            Local path or http(s):// URL to registry.toml
  BUX_REGISTRY_REFRESH=1  Force re-download of HTTP index cache
  BUX_REGISTRY_INSECURE=1 Allow self-signed HTTPS registry (dev/smoke)
  BUX_CFLAGS              Extra flags appended to the C compiler line
  BUX_CC                  C compiler binary (overrides --target pick)
  BUX_RUNTIME             full|minimal|thin|embed|win  (default: full on Unix)
  BUX_STATIC=1            Same as --static

Global options:
  --color <auto|on|off>   Control colored output (default: auto)
  -q, --quiet             Suppress non-error output
  -v, --verbose           Verbose output
  --release               Optimize (-O2), omit -g and #line maps
  --static                Fully-static link + thin runtime (containers / distroless)
  --target <triple>       Cross-compile (e.g. aarch64-linux-gnu)
"""

proc parseGlobalOptions(args: seq[string]): tuple[opts: GlobalOptions, rest: seq[string], ok: bool] =
  result.opts = GlobalOptions(color: cmAuto, quiet: false, verbose: false,
                              release: false, staticLink: false, target: "")
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
    elif arg == "--release":
      result.opts.release = true
    elif arg == "--static":
      result.opts.staticLink = true
    elif arg == "--target":
      if i + 1 >= args.len:
        stderr.writeLine("error: --target requires a triple (e.g. aarch64-linux-gnu)")
        result.ok = false
        return
      inc i
      result.opts.target = args[i]
    elif arg.startsWith("--target="):
      result.opts.target = arg["--target=".len .. ^1]
    else:
      result.rest.add(arg)
    inc i

proc shouldUseColor(opts: GlobalOptions): bool =
  case opts.color
  of cmOn: true
  of cmOff: false
  of cmAuto: terminal.isatty(stdout)

proc wantStaticLink(opts: GlobalOptions): bool =
  ## --static or BUX_STATIC=1
  if opts.staticLink: return true
  let e = getEnv("BUX_STATIC")
  result = e == "1" or e.toLowerAscii() in ["true", "yes", "on"]

proc resolveRuntimeFlavor(opts: GlobalOptions): RuntimeFlavor =
  ## Linux/cloud/embed first. Windows is not a product target (rfWin historical).
  let e = getEnv("BUX_RUNTIME").toLowerAscii()
  case e
  of "full", "posix":
    return rfFull
  of "minimal", "thin", "embed", "embedded", "freestanding":
    return rfMinimal
  of "win", "windows":
    return rfWin
  of "":
    discard
  else:
    # Unknown value → fall through to defaults
    discard
  when defined(windows):
    return rfWin
  # Fully-static containers: OpenSSL static is painful → thin runtime default
  if wantStaticLink(opts):
    return rfMinimal
  # Cross without explicit full: prefer thin (host may lack target libcrypto)
  if opts.target.len > 0:
    return rfMinimal
  return rfFull

proc runtimeFileName(flavor: RuntimeFlavor): string =
  case flavor
  of rfFull: "runtime.c"
  of rfMinimal: "runtime_minimal.c"
  of rfWin: "runtime_win.c"

proc isThinRuntime(flavor: RuntimeFlavor): bool =
  flavor in {rfMinimal, rfWin}

proc findOnPath(bin: string): bool =
  ## True if `bin` resolves as an executable on PATH (or is an absolute path).
  if bin.len == 0: return false
  if '/' in bin or '\\' in bin:
    return fileExists(bin)
  let (outp, code) = execCmdEx(&"command -v {quoteShell(bin)} 2>/dev/null")
  result = code == 0 and outp.strip().len > 0

proc resolveCCompiler(opts: GlobalOptions): string =
  ## Prefer BUX_CC, then <triple>-gcc for --target, then clang -target, else host cc.
  let envCc = getEnv("BUX_CC")
  if envCc.len > 0:
    return envCc
  if opts.target.len > 0:
    let tripleGcc = opts.target & "-gcc"
    if findOnPath(tripleGcc):
      return tripleGcc
    if findOnPath("clang"):
      return "clang"
    # Fall through — user may still have a named cross compiler elsewhere
    return tripleGcc
  when defined(windows):
    return "gcc"
  else:
    return "cc"

proc cTargetFlags(opts: GlobalOptions, ccBin: string): string =
  ## Extra flags for cross: clang needs -target; *-gcc is already a cross binary.
  if opts.target.len == 0: return ""
  let base = ccBin.extractFilename.toLowerAscii()
  if base == "clang" or base.startsWith("clang-"):
    return " -target " & opts.target
  ""

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
  if "cannot return reference to local" in m:
    return "return a value, or return a reference borrowed from a function parameter"
  if "lifetime elision failed" in m:
    return "add an explicit lifetime, e.g. func F<'a>(x: &'a T, y: &'a U) -> &'a T"
  if "lifetime mismatch" in m:
    return "returned reference must share a lifetime with the return type (annotate with 'a)"
  if "no input reference to borrow from" in m:
    return "add a '&T' parameter to borrow from, or return an owned value"
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
      if not args[i].startsWith("-"):
        version = args[i]
      else:
        printError(&"unknown add option '{args[i]}'", useColor)
        return 1
    inc i
  # Append to bux.toml
  var depLine = ""
  if path.len > 0:
    depLine = &"{depName} = {{ Path = \"{path}\" }}"
  elif gitUrl.len > 0:
    depLine = &"{depName} = {{ Version = \"{version}\", Source = \"{gitUrl}\" }}"
  else:
    # Registry resolve (E.1 + HTTP URL)
    let reg = loadRegistry()
    if reg.path.len == 0:
      if reg.sourceUrl.len > 0:
        printError(&"failed to fetch registry from {reg.sourceUrl}", useColor)
        printError("hint: check network, curl/wget, or set BUX_REGISTRY to a local file", useColor)
      else:
        printError("no package registry found (set BUX_REGISTRY or install config/registry.toml)", useColor)
      return 1
    let pkg = registryLookup(reg, depName, version)
    if pkg.name.len == 0:
      printError(&"package '{depName}' not found in registry ({reg.path})", useColor)
      printError("hint: bux search  |  bux add name --git <url>  |  bux add name --path <dir>", useColor)
      return 1
    depLine = formatRegistryDepLine(depName, pkg)
    if not opts.quiet:
      let src = if reg.sourceUrl.len > 0: reg.sourceUrl else: reg.path
      printInfo(&"Resolved '{depName}' {pkg.version} from registry {src}", useColor)
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

proc cmdSearch*(args: seq[string], opts: GlobalOptions): int =
  let useColor = shouldUseColor(opts)
  let query = if args.len > 0: args[0] else: ""
  let reg = loadRegistry()
  if reg.path.len == 0:
    if reg.sourceUrl.len > 0:
      printError(&"failed to fetch registry from {reg.sourceUrl}", useColor)
      printError("hint: need curl or wget; or set BUX_REGISTRY to a local file", useColor)
    else:
      printError("no package registry found (set BUX_REGISTRY path or http(s) URL)", useColor)
    return 1
  if not opts.quiet:
    if reg.sourceUrl.len > 0:
      echo &"Registry: {reg.sourceUrl}"
      echo &"  (cached: {reg.path})"
    else:
      echo &"Registry: {reg.path}"
  let hits = registrySearch(reg, query)
  if hits.len == 0:
    if not opts.quiet:
      echo "No packages matched."
    return 1
  # Dedupe by name showing latest version
  var seen = initTable[string, RegistryPackage]()
  for p in hits:
    seen[p.name.toLowerAscii()] = p
  var names: seq[string] = @[]
  for k in seen.keys:
    names.add(k)
  names.sort(system.cmp)
  for k in names:
    let p = seen[k]
    let desc = if p.description.len > 0: p.description else: p.source
    echo &"  {p.name}  {p.version}  — {desc}"
  return 0


proc packageChecksum*(dir: string): string =
  ## Deterministic sha1 of all `*.bux` under dir (sorted paths + contents).
  ## Used for bux.lock Checksum — cloud install reproducibility (session 79).
  if dir.len == 0 or not dirExists(dir):
    return ""
  var files: seq[string] = @[]
  for f in walkDirRec(dir):
    if f.endsWith(".bux"):
      files.add(f)
  files.sort(system.cmp)
  var blob = ""
  for f in files:
    let rel = relativePath(f, dir)
    blob.add(rel)
    blob.add("\n")
    try:
      blob.add(readFile(f))
    except CatchableError:
      discard
    blob.add("\0")
  result = toLowerAscii($secureHash(blob))

proc verifyLockedInstall*(root: string, useColor: bool, opts: GlobalOptions): int =
  ## `bux install --locked`: require bux.lock and verify path deps + checksums.
  let lockPath = root / "bux.lock"
  if not fileExists(lockPath):
    printError("install --locked: bux.lock missing (run `bux install` first)", useColor)
    return 1
  let lock = loadLockfile(lockPath)
  if lock.entries.len == 0:
    if not opts.quiet:
      printInfo("install --locked: empty lock (no dependencies)", useColor)
    return 0
  for e in lock.entries:
    let src = e.source
    if src.startsWith("http://") or src.startsWith("https://") or src.endsWith(".git"):
      # Git: ensure cache dir exists
      let depDir = getHomeDir() / ".bux" / "packages" / e.name
      if not dirExists(depDir):
        printError(&"install --locked: git package '{e.name}' not cached at {depDir}", useColor)
        printError("hint: run `bux install` once to clone, then commit bux.lock", useColor)
        return 1
      if e.checksum.len > 0:
        let got = packageChecksum(depDir)
        if got != e.checksum:
          printError(&"install --locked: checksum mismatch for '{e.name}'", useColor)
          printError(&"  lock: {e.checksum}", useColor)
          printError(&"  got:  {got}", useColor)
          return 1
    else:
      # Path source (absolute or relative)
      let absPath = if src.isAbsolute: src else: root / src
      if not dirExists(absPath):
        printError(&"install --locked: path '{e.name}' missing: {absPath}", useColor)
        return 1
      if e.checksum.len > 0:
        let got = packageChecksum(absPath)
        if got != e.checksum:
          printError(&"install --locked: checksum mismatch for '{e.name}'", useColor)
          printError(&"  lock: {e.checksum}", useColor)
          printError(&"  got:  {got}", useColor)
          return 1
    if not opts.quiet:
      printInfo(&"locked ok: {e.name} {e.version}", useColor)
  if not opts.quiet:
    printInfo(&"install --locked: {lock.entries.len} package(s) verified", useColor)
  return 0

proc cmdInstall*(args: seq[string], opts: GlobalOptions): int =
  let useColor = shouldUseColor(opts)
  var lockedOnly = false
  for a in args:
    if a == "--locked":
      lockedOnly = true
    elif a.startsWith("-"):
      printError(&"unknown install option '{a}'", useColor)
      return 1
  let root = getCurrentDir()
  if lockedOnly:
    return verifyLockedInstall(root, useColor, opts)
  let manifestPath = root / "bux.toml"
  if not fileExists(manifestPath):
    printError("no bux.toml found", useColor)
    return 1
  let man = loadManifest(manifestPath)
  var lock = Lockfile(entries: @[])
  let cacheDir = getHomeDir() / ".bux" / "packages"
  if not dirExists(cacheDir):
    createDir(cacheDir)
  let reg = loadRegistry()
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
      let csum = packageChecksum(absPath)
      if fileExists(depManifestPath):
        let depMan = loadManifest(depManifestPath)
        lock.entries.add(LockEntry(name: dep.name, version: depMan.version, source: absPath, checksum: csum))
      else:
        lock.entries.add(LockEntry(name: dep.name, version: "0.0.0", source: absPath, checksum: csum))
      if not opts.quiet:
        printInfo(&"Resolved path dependency '{dep.name}' from {absPath}", useColor)
    of dkGit:
      let depDir = cacheDir / dep.name
      if not dirExists(depDir):
        if not opts.quiet:
          printInfo(&"Cloning '{dep.name}' from {dep.gitUrl}...", useColor)
        let (outp, code) = execCmdEx(&"git clone --quiet {quoteShell(dep.gitUrl)} {quoteShell(depDir)} 2>&1")
        if code != 0:
          printError(&"failed to clone {dep.gitUrl}: {outp}", useColor)
          return 1
      else:
        if not opts.quiet:
          printInfo(&"Using cached '{dep.name}' from {depDir}", useColor)
      # Lock stores git URL; build loads from cache by name
      let csumGit = packageChecksum(depDir)
      lock.entries.add(LockEntry(name: dep.name, version: dep.gitVersion, source: dep.gitUrl, checksum: csumGit))
    of dkVersion:
      # Registry lookup (E.1)
      if reg.path.len == 0:
        printError(&"cannot resolve '{dep.name}': no package registry (set BUX_REGISTRY)", useColor)
        return 1
      let pkg = registryLookup(reg, dep.name, dep.versionReq)
      if pkg.name.len == 0:
        printError(&"package '{dep.name}' not found in registry", useColor)
        return 1
      if pkg.resolvedPath.len > 0 and dirExists(pkg.resolvedPath):
        let csum = packageChecksum(pkg.resolvedPath)
        lock.entries.add(LockEntry(name: dep.name, version: pkg.version, source: pkg.resolvedPath, checksum: csum))
        if not opts.quiet:
          printInfo(&"Resolved '{dep.name}' {pkg.version} → {pkg.resolvedPath}", useColor)
      elif isGitSource(pkg.source):
        let depDir = cacheDir / dep.name
        if not dirExists(depDir):
          if not opts.quiet:
            printInfo(&"Cloning '{dep.name}' from {pkg.source}...", useColor)
          let (outp, code) = execCmdEx(&"git clone --quiet {quoteShell(pkg.source)} {quoteShell(depDir)} 2>&1")
          if code != 0:
            printError(&"failed to clone {pkg.source}: {outp}", useColor)
            return 1
        let csumG = packageChecksum(depDir)
        lock.entries.add(LockEntry(name: dep.name, version: pkg.version, source: pkg.source, checksum: csumG))
        if not opts.quiet:
          printInfo(&"Resolved '{dep.name}' {pkg.version} → git {pkg.source}", useColor)
      else:
        printError(&"registry entry '{dep.name}' has unusable source '{pkg.source}'", useColor)
        return 1
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
  let macRes = expandMacros(unifiedModule)
  if macRes.diagnostics.len > 0:
    printError("macro expansion errors", useColor)
    for d in macRes.diagnostics:
      printDiagnostic("error", d.message, d.loc, useColor)
    return 1
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
  of dkMacro: d.declMacroName
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
  var opts = opts
  var pathArgs: seq[string] = @[]
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--release":
      opts.release = true
    elif a == "--static":
      opts.staticLink = true
    elif a == "--target":
      if i + 1 < args.len:
        inc i
        opts.target = args[i]
    elif a.startsWith("--target="):
      opts.target = a["--target=".len .. ^1]
    elif a.startsWith("-"):
      # ignore unknown flags for forward-compat
      discard
    else:
      pathArgs.add(a)
    inc i
  let useColor = shouldUseColor(opts)
  let root = if pathArgs.len > 0: absolutePath(pathArgs[0]) else: getCurrentDir()
  let (pctx, status) = prepareProject(root, useColor, opts)
  if status != 0:
    return status

  # Create build directory
  let buildDir = root / "build"
  if not dirExists(buildDir):
    createDir(buildDir)

  let unifiedModule = mergeProject(pctx)

  # Phase 2b: expand declarative macro! / quote! before type checking
  let macRes = expandMacros(unifiedModule)
  if macRes.diagnostics.len > 0:
    printError("macro expansion errors", useColor)
    for d in macRes.diagnostics:
      printDiagnostic("error", d.message, d.loc, useColor)
    return 1

  # Phase 3: Sema + HIR + C codegen on unified module
  let (semaRes, semaCtx) = analyzeFull(unifiedModule)
  if semaRes.hasErrors:
    printError("type errors in project", useColor)
    printSemaDiags(semaRes.diagnostics, useColor)
    return 1
  
  let hirMod = lowerModule(unifiedModule, semaCtx)
  let lirBuilder = lowerModuleToLir(hirMod)
  # Debug builds: #line maps into .bux for gdb. Release: skip maps + -O2.
  var lirCbe = initLirCBackend(emitDebugLines = not opts.release)
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
  # Runtime pick: full POSIX | minimal (Linux static/embed) | win (historical).
  # See resolveRuntimeFlavor — BUX_RUNTIME, --static, --target.
  let flavor = resolveRuntimeFlavor(opts)
  let thinRt = isThinRuntime(flavor)
  let runtimeName = runtimeFileName(flavor)
  let runtimeSrc = baseDir / "rt" / runtimeName
  if fileExists(runtimeSrc):
    copyFile(runtimeSrc, runtimeDst)
  else:
    printError(&"{runtimeName} not found in rt/", useColor)
    return 1

  let ioSrc = baseDir / "rt" / "io.c"
  if fileExists(ioSrc):
    copyFile(ioSrc, ioDst)
  else:
    printError("io.c not found in rt/", useColor)
    return 1

  # Compile with cc — debug default (-O0 -g) or --release (-O2)
  let outputName = if pctx.man.name != "": pctx.man.name else: "bux_out"
  let exeSuffix = when defined(windows): ".exe" else: ""
  let outputFile = buildDir / (outputName & exeSuffix)
  let optFlags = if opts.release: "-O2 -DNDEBUG" else: "-O0 -g"
  let extraCflags = getEnv("BUX_CFLAGS")
  var cflags = if extraCflags.len > 0: optFlags & " " & extraCflags else: optFlags
  let doStatic = wantStaticLink(opts)
  if doStatic:
    cflags = cflags & " -static"
  # Host / cross C toolchain + link flags
  let ccBin = resolveCCompiler(opts)
  cflags = cflags & cTargetFlags(opts, ccBin)
  let ldStable =
    when defined(linux):
      if thinRt: "" else: " -Wl,--build-id=none"
    else:
      ""
  # Note: -l libs must come *after* .c/.o inputs (GNU ld left-to-right).
  let (hostCflags, hostLibs) =
    if thinRt:
      # gc-sections drops mono stdlib that is never called (crypto/tasks, …)
      (" -ffunction-sections -fdata-sections", " -Wl,--gc-sections -lm")
    else:
      (" -pthread" & ldStable, " -lm -lssl -lcrypto")
  let ccCmd = &"{ccBin} {cflags}{hostCflags} -o {outputFile} {cFile} {runtimeDst} {ioDst}{hostLibs} 2>&1"
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
  let exeSuffix = when defined(windows): ".exe" else: ""
  var outputFile = root / "build" / (outputName & exeSuffix)
  if not fileExists(outputFile):
    # Fallback without suffix (cross-env / older builds)
    outputFile = root / "build" / outputName
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

proc parseTestArgs(args: seq[string]): tuple[filter: string, paths: seq[string], ok: bool] =
  ## Parse `test` args: optional `--filter <s>` / `--filter=<s>`, rest are ignored paths.
  result.filter = ""
  result.paths = @[]
  result.ok = true
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--filter":
      if i + 1 >= args.len:
        stderr.writeLine("error: --filter requires an argument")
        result.ok = false
        return
      inc i
      result.filter = args[i]
    elif a.startsWith("--filter="):
      result.filter = a["--filter=".len .. ^1]
    elif a == "--help" or a == "-h":
      echo "Usage: bux test [--filter <name>] [project-dir]"
      echo "  --filter <name>   Only run tests whose filename contains <name>"
      result.ok = false  # treat as early exit without error in caller? use special
      # Signal help via empty filter and a sentinel path
      result.paths = @["__help__"]
      return
    elif a.startsWith("-"):
      stderr.writeLine(&"error: unknown test option '{a}'")
      result.ok = false
      return
    else:
      result.paths.add(a)
    inc i

proc parseFmtArgs(args: seq[string]): tuple[checkOnly: bool, paths: seq[string], ok: bool, help: bool] =
  result.checkOnly = false
  result.paths = @[]
  result.ok = true
  result.help = false
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--check":
      result.checkOnly = true
    elif a == "--help" or a == "-h":
      result.help = true
      return
    elif a.startsWith("-"):
      stderr.writeLine(&"error: unknown fmt option '{a}'")
      result.ok = false
      return
    else:
      result.paths.add(a)
    inc i

proc cmdTest*(args: seq[string], opts: GlobalOptions): int =
  let useColor = shouldUseColor(opts)
  let (filter, paths, ok) = parseTestArgs(args)
  if not ok:
    if paths.len == 1 and paths[0] == "__help__":
      return 0
    return 1
  let root = if paths.len > 0: absolutePath(paths[0]) else: getCurrentDir()
  let testsDir = root / "tests"
  var testFiles: seq[string] = @[]
  if dirExists(testsDir):
    for kind, path in walkDir(testsDir):
      if kind == pcFile and path.endsWith(".bux"):
        let testName = splitFile(path).name
        if filter.len > 0 and filter notin testName:
          continue
        testFiles.add(path)
  testFiles.sort(system.cmp)
  if testFiles.len == 0:
    if filter.len > 0:
      printError(&"no tests matching filter '{filter}' in tests/", useColor)
    else:
      printError("no tests found in tests/ directory", useColor)
    return 1

  if not opts.quiet:
    if filter.len > 0:
      echo &"Running tests (filter: {filter}) in {testsDir}"
    else:
      echo &"Running tests in {testsDir}"
    echo "┌──────────────────────────────┬────────┐"
    echo "│ Test                         │ Status │"
    echo "├──────────────────────────────┼────────┤"

  var passed = 0
  var failed = 0
  for testFile in testFiles:
    let testName = splitFile(testFile).name
    let tmpDir = getTempDir() / "bux_test_" & testName
    removeDir(tmpDir)
    createDir(tmpDir / "src")
    copyFile(testFile, tmpDir / "src" / "Main.bux")
    writeFile(tmpDir / "bux.toml",
      "[Package]\nName    = \"" & testName & "\"\nVersion = \"0.1.0\"\nType    = \"bin\"\n\n[Build]\nOutput = \"Bin\"\n")
    let buildRes = cmdBuild(@[tmpDir], opts)
    var status: string
    var statusOk = false
    if buildRes != 0:
      status = "FAIL"
      failed += 1
    else:
      var execFile = tmpDir / "build" / testName
      if not fileExists(execFile):
        execFile = tmpDir / "build" / "bux_out"
      let exitCode = execCmd(execFile)
      if exitCode == 0:
        status = "PASS"
        statusOk = true
        passed += 1
      else:
        status = &"FAIL:{exitCode}"
        failed += 1
    removeDir(tmpDir)

    if not opts.quiet:
      # Pad name to 28 chars for the table column
      var nameCol = testName
      if nameCol.len > 28:
        nameCol = nameCol[0 .. 24] & "..."
      else:
        nameCol = nameCol & repeat(' ', 28 - nameCol.len)
      var stCol = status
      if stCol.len < 6:
        stCol = stCol & repeat(' ', 6 - stCol.len)
      if useColor:
        if statusOk:
          stdout.setForegroundColor(fgGreen)
        else:
          stdout.setForegroundColor(fgRed)
        stdout.writeLine(&"│ {nameCol} │ {stCol} │")
        stdout.resetAttributes()
      else:
        echo &"│ {nameCol} │ {stCol} │"

  if not opts.quiet:
    echo "└──────────────────────────────┴────────┘"
    echo &"\nResults: {passed} passed, {failed} failed, {testFiles.len} total"
  # CI-friendly exit codes: 0 = all pass, 1 = some failed
  return if failed > 0: 1 else: 0

proc cmdFmt*(args: seq[string], opts: GlobalOptions): int =
  let useColor = shouldUseColor(opts)
  let (checkOnly, paths, ok, help) = parseFmtArgs(args)
  if not ok:
    return 1
  if help:
    echo "Usage: bux fmt [--check] [path...]"
    echo "  --check   Do not write; exit 1 if any file would be reformatted"
    echo "  path      File or directory (default: .)"
    return 0

  let targets = if paths.len > 0: paths else: @["."]
  var files: seq[string] = @[]
  for t in targets:
    let collected = collectBuxFiles(t)
    for f in collected:
      if f notin files:
        files.add(f)
  files.sort(system.cmp)

  if files.len == 0:
    printError("no .bux files found", useColor)
    return 1

  var changed = 0
  var failed = 0
  var unchanged = 0
  for path in files:
    let (okf, didChange, msg) = formatFile(path, checkOnly)
    if not okf:
      printError(&"{path}: {msg}", useColor)
      failed += 1
      continue
    if didChange:
      changed += 1
      if not opts.quiet:
        if checkOnly:
          printError(&"  would reformat {path}", useColor)
        else:
          printInfo(&"  formatted {path}", useColor)
    else:
      unchanged += 1
      if opts.verbose and not opts.quiet:
        echo &"  ok {path}"

  if not opts.quiet:
    if checkOnly:
      echo &"\nfmt --check: {changed} would reformat, {unchanged} ok, {failed} errors"
    else:
      echo &"\nFormatted {changed}/{files.len} files ({unchanged} already clean)"

  if failed > 0:
    return 1
  if checkOnly and changed > 0:
    return 1
  return 0

proc cmdDoc*(args: seq[string], opts: GlobalOptions): int =
  ## Generate Markdown docs from `///` / adjacent `/* */` comments.
  var outPath = ""
  var paths: seq[string] = @[]
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--out" or a == "-o":
      if i + 1 >= args.len:
        stderr.writeLine("error: --out requires a path")
        return 1
      inc i
      outPath = args[i]
    elif a.startsWith("--out="):
      outPath = a["--out=".len .. ^1]
    elif a == "--help" or a == "-h":
      echo "Usage: bux doc [--out file.md] [path...]"
      echo "  Scans .bux files for /// and /* */ docs preceding declarations."
      echo "  Default path: lib/ (stdlib) when omitted."
      return 0
    elif a.startsWith("-"):
      stderr.writeLine(&"error: unknown doc option '{a}'")
      return 1
    else:
      paths.add(a)
    inc i

  if paths.len == 0:
    # Prefer stdlib if present
    if dirExists("lib"):
      paths = @["lib"]
    else:
      paths = @["."]

  let items = generateDocs(paths)
  let title =
    if paths.len == 1 and paths[0] == "lib": "Bux Standard Library"
    else: "API Reference"
  let md = renderMarkdown(items, title)

  if outPath.len > 0:
    try:
      let parent = parentDir(outPath)
      if parent.len > 0 and not dirExists(parent):
        createDir(parent)
      writeFile(outPath, md)
      if not opts.quiet:
        echo &"Wrote {items.len} documented items → {outPath}"
    except CatchableError as e:
      stderr.writeLine("error: " & e.msg)
      return 1
  else:
    stdout.write(md)
  if items.len == 0 and not opts.quiet:
    stderr.writeLine("warning: no /// or /* */ documented declarations found")
  return 0

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
  of "search": return cmdSearch(cmdArgs, opts)
  of "build": return cmdBuild(cmdArgs, opts)
  of "run": return cmdRun(cmdArgs, opts)
  of "check": return cmdCheck(cmdArgs, opts)
  of "test": return cmdTest(cmdArgs, opts)
  of "fmt": return cmdFmt(cmdArgs, opts)
  of "doc": return cmdDoc(cmdArgs, opts)
  of "clean": return cmdClean(cmdArgs, opts)
  of "version", "--version", "-v": return cmdVersion(cmdArgs, opts)
  of "help", "--help", "-h":
    printUsage()
    return 0
  else:
    let useColor = shouldUseColor(opts)
    printError(&"unknown command '{cmd}'", useColor)
    return 1
