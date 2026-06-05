import std/os
import cli

when isMainModule:
  let args = commandLineParams()
  quit(runCli(args))
