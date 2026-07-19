## registry.nim — Bux package registry index (E.1)
##
## Index format (TOML-ish, one package per [[package]] table):
##
##   [[package]]
##   name = "greet"
##   version = "0.1.0"
##   source = "file:packages/greet"   # relative to the registry file
##   description = "Hello helpers"
##
##   [[package]]
##   name = "net"
##   version = "1.2.0"
##   source = "https://github.com/bux-lang/net.git"
##
## Lookup order for the index file:
##   1. $BUX_REGISTRY (file path)
##   2. ~/.bux/registry.toml
##   3. <repo>/config/registry.toml next to the compiler / cwd

import std/[os, strutils, strformat, algorithm]

type
  RegistryPackage* = object
    name*: string
    version*: string
    source*: string        ## raw source as written in the index
    description*: string
    resolvedPath*: string  ## absolute path for file: sources (filled on load)

  Registry* = object
    path*: string          ## index file path
    packages*: seq[RegistryPackage]

proc resolvePackageSource(pkg: var RegistryPackage, indexDir: string) =
  if pkg.source.startsWith("file:"):
    var p = pkg.source["file:".len .. ^1]
    if p.startsWith("//"):
      p = p[2 .. ^1]
    if not p.isAbsolute:
      p = indexDir / p
    pkg.resolvedPath = p.absolutePath
  elif pkg.source.startsWith("path:"):
    var p = pkg.source["path:".len .. ^1]
    if not p.isAbsolute:
      p = indexDir / p
    pkg.resolvedPath = p.absolutePath
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

proc findRegistryIndex*(): string =
  ## Locate the registry index file.
  let env = getEnv("BUX_REGISTRY")
  if env.len > 0 and fileExists(env):
    return env.absolutePath
  let homeIdx = getHomeDir() / ".bux" / "registry.toml"
  if fileExists(homeIdx):
    return homeIdx
  let candidates = @[
    getAppDir() / ".." / "config" / "registry.toml",
    getAppDir() / "config" / "registry.toml",
    getCurrentDir() / "config" / "registry.toml",
    getCurrentDir() / ".." / "config" / "registry.toml",
  ]
  for c in candidates:
    if fileExists(c):
      return c.absolutePath
  return ""

proc loadRegistry*(path: string = ""): Registry =
  result.path = if path.len > 0: path else: findRegistryIndex()
  result.packages = @[]
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
