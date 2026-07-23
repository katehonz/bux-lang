## registry.nim — Bux package registry index (E.1 + HTTP URL)
##
## Index format (TOML-ish, one package per [[package]] table):
##
##   [[package]]
##   name = "greet"
##   version = "0.1.0"
##   source = "file:packages/greet"   # relative to the index file
##   description = "Hello helpers"
##
##   [[package]]
##   name = "net"
##   version = "1.2.0"
##   source = "https://github.com/bux-lang/net.git"
##
## Lookup order for the index:
##   1. $BUX_REGISTRY — local file path **or** http(s):// URL
##   2. ~/.bux/registry.toml
##   3. <repo>/config/registry.toml next to the compiler / cwd
##
## HTTP indices are downloaded to ~/.bux/cache/registry_http.toml.
## Relative file:/path: sources in a remote index are resolved against that
## cache directory — prefer absolute paths or git URLs for remote registries.

import std/[os, strutils, strformat, algorithm, osproc]

type
  RegistryPackage* = object
    name*: string
    version*: string
    source*: string        ## raw source as written in the index
    description*: string
    resolvedPath*: string  ## absolute path for file: sources (filled on load)

  Registry* = object
    path*: string          ## index file path (local, or cached path for HTTP)
    sourceUrl*: string     ## non-empty when loaded from an HTTP URL
    packages*: seq[RegistryPackage]

proc resolvePackageSource(pkg: var RegistryPackage, indexDir: string) =
  if pkg.source.startsWith("file:"):
    var p = pkg.source["file:".len .. ^1]
    if p.startsWith("//"):
      p = p[2 .. ^1]
    if not p.isAbsolute:
      p = indexDir / p
    # Collapse ../ segments for cleaner lockfiles (session 82)
    pkg.resolvedPath = expandFilename(p)
  elif pkg.source.startsWith("path:"):
    var p = pkg.source["path:".len .. ^1]
    if not p.isAbsolute:
      p = indexDir / p
    pkg.resolvedPath = expandFilename(p)
    pkg.source = "file:" & pkg.resolvedPath

proc parseRegistryToml(content, indexPath: string): seq[RegistryPackage] =
  ## Minimal parser for repeated [[package]] blocks with string keys.
  result = @[]
  var cur: RegistryPackage
  var inPkg = false
  let indexDir = indexPath.parentDir

  for raw in content.splitLines():
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    if line == "[[package]]" or line == "[[Package]]":
      if inPkg and cur.name.len > 0:
        resolvePackageSource(cur, indexDir)
        result.add(cur)
      cur = RegistryPackage()
      inPkg = true
      continue
    if not inPkg:
      continue
    let eq = line.find('=')
    if eq < 0: continue
    let key = line[0 ..< eq].strip().toLowerAscii()
    var val = line[eq + 1 .. ^1].strip()
    if val.len >= 2 and val[0] == '"' and val[^1] == '"':
      val = val[1 ..< ^1]
    case key
    of "name": cur.name = val
    of "version": cur.version = val
    of "source": cur.source = val
    of "description": cur.description = val
    else: discard
  if inPkg and cur.name.len > 0:
    resolvePackageSource(cur, indexDir)
    result.add(cur)

proc isHttpUrl*(s: string): bool =
  s.startsWith("http://") or s.startsWith("https://")

proc registryCacheDir*(): string =
  getHomeDir() / ".bux" / "cache"

proc fetchRegistryUrl*(url: string): string =
  ## Download a remote registry.toml into ~/.bux/cache/.
  ## Returns the local cache path on success, or "" on failure.
  ## Re-fetches when the URL changes or when $BUX_REGISTRY_REFRESH is set.
  let cacheDir = registryCacheDir()
  try:
    createDir(cacheDir)
  except OSError, IOError:
    return ""
  let cachePath = cacheDir / "registry_http.toml"
  let metaPath = cacheDir / "registry_http.url"
  let force = getEnv("BUX_REGISTRY_REFRESH").len > 0
  var cachedUrl = ""
  if fileExists(metaPath):
    try:
      cachedUrl = readFile(metaPath).strip()
    except CatchableError:
      cachedUrl = ""
  if not force and fileExists(cachePath) and cachedUrl == url:
    return cachePath.absolutePath

  # Prefer curl; fall back to wget.
  # BUX_REGISTRY_INSECURE=1 → allow self-signed HTTPS (dev / smoke only).
  let insecure = getEnv("BUX_REGISTRY_INSECURE").len > 0
  var ok = false
  if findExe("curl").len > 0:
    let kflag = if insecure: " -k" else: ""
    let cmd = &"curl -fsSL{kflag} --max-time 30 -o {quoteShell(cachePath)} {quoteShell(url)}"
    let (_, code) = execCmdEx(cmd)
    ok = code == 0 and fileExists(cachePath) and getFileSize(cachePath) > 0
  elif findExe("wget").len > 0:
    let nflag = if insecure: " --no-check-certificate" else: ""
    let cmd = &"wget -q{nflag} -T 30 -O {quoteShell(cachePath)} {quoteShell(url)}"
    let (_, code) = execCmdEx(cmd)
    ok = code == 0 and fileExists(cachePath) and getFileSize(cachePath) > 0
  else:
    return ""

  if not ok:
    return ""
  try:
    writeFile(metaPath, url & "\n")
  except CatchableError:
    discard
  return cachePath.absolutePath

proc findRegistryIndex*(): tuple[path: string, url: string] =
  ## Locate the registry index. Returns (localPath, sourceUrl).
  ## sourceUrl is non-empty only when the index was (or should be) fetched via HTTP.
  result = ("", "")
  let env = getEnv("BUX_REGISTRY")
  if env.len > 0:
    if isHttpUrl(env):
      let local = fetchRegistryUrl(env)
      if local.len > 0:
        return (local, env)
      return ("", env)  # URL set but fetch failed — caller can report
    if fileExists(env):
      return (env.absolutePath, "")
  let homeIdx = getHomeDir() / ".bux" / "registry.toml"
  if fileExists(homeIdx):
    return (homeIdx, "")
  let candidates = @[
    getAppDir() / ".." / "config" / "registry.toml",
    getAppDir() / "config" / "registry.toml",
    getCurrentDir() / "config" / "registry.toml",
    getCurrentDir() / ".." / "config" / "registry.toml",
  ]
  for c in candidates:
    if fileExists(c):
      return (c.absolutePath, "")
  return ("", "")

proc loadRegistry*(path: string = ""): Registry =
  result.path = ""
  result.sourceUrl = ""
  result.packages = @[]
  if path.len > 0:
    if isHttpUrl(path):
      result.sourceUrl = path
      result.path = fetchRegistryUrl(path)
    else:
      result.path = path
  else:
    let (p, u) = findRegistryIndex()
    result.path = p
    result.sourceUrl = u
  if result.path.len == 0 or not fileExists(result.path):
    return
  try:
    let content = readFile(result.path)
    result.packages = parseRegistryToml(content, result.path)
  except CatchableError:
    result.packages = @[]

proc registryLookup*(reg: Registry, name: string, versionReq: string = "*"): RegistryPackage =
  ## Find a package by name. versionReq `*` picks the last matching entry
  ## (index order; put newest last). Exact version matches preferred.
  result = RegistryPackage()
  var candidates: seq[RegistryPackage] = @[]
  for p in reg.packages:
    if p.name.toLowerAscii() == name.toLowerAscii():
      candidates.add(p)
  if candidates.len == 0:
    return
  if versionReq.len == 0 or versionReq == "*":
    return candidates[^1]
  for p in candidates:
    if p.version == versionReq:
      return p
  # Semver prefix match: "1" matches "1.0.0"
  for p in candidates:
    if p.version.startsWith(versionReq):
      return p
  return candidates[^1]

proc registrySearch*(reg: Registry, query: string): seq[RegistryPackage] =
  result = @[]
  let q = query.toLowerAscii()
  for p in reg.packages:
    if q.len == 0 or
       q in p.name.toLowerAscii() or
       q in p.description.toLowerAscii():
      result.add(p)
  result.sort(proc (a, b: RegistryPackage): int =
    cmp(a.name.toLowerAscii(), b.name.toLowerAscii()))

proc isGitSource*(source: string): bool =
  source.startsWith("http://") or source.startsWith("https://") or
    source.startsWith("git@") or source.startsWith("git://") or
    source.startsWith("ssh://")

proc isFileSource*(source: string): bool =
  source.startsWith("file:") or source.startsWith("path:")

proc formatRegistryDepLine*(name: string, pkg: RegistryPackage): string =
  ## Produce a bux.toml Dependencies line for a resolved registry package.
  if pkg.resolvedPath.len > 0 and dirExists(pkg.resolvedPath):
    return &"{name} = {{ Path = \"{pkg.resolvedPath}\" }}"
  if isGitSource(pkg.source):
    let ver = if pkg.version.len > 0: pkg.version else: "*"
    return &"{name} = {{ Version = \"{ver}\", Source = \"{pkg.source}\" }}"
  if isFileSource(pkg.source) and pkg.resolvedPath.len > 0:
    return &"{name} = {{ Path = \"{pkg.resolvedPath}\" }}"
  # Fallback: version-only (install will re-resolve)
  let ver = if pkg.version.len > 0: pkg.version else: "*"
  return &"{name} = \"{ver}\""
