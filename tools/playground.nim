# playground.nim — Bux language web playground
# Uses hunos HTTP server to accept Bux code, compile with buxc, run, and return output
#
# Usage: nim c -r tools/playground.nim
# Then open http://localhost:8407 in browser

import std/[os, osproc, strutils, json]
import hunos, hunos/router

const
  Buxc = "./buxc"              # path to buxc binary
  Port = 8407                  # playground port
  TimeoutMs = 5000             # max execution time (5 seconds)

# --------------- HTML frontend ---------------
const PlaygroundHTML = staticRead("playground.html")

# --------------- helpers ---------------

proc compileAndRun(code: string): tuple[output: string, exitCode: int, isError: bool] =
  ## Compile code with buxc, run the resulting binary, capture output.
  var tmpDir = "/tmp/bux-playground-" & $getCurrentProcessId()
  createDir(tmpDir)
  createDir(tmpDir / "src")
  
  # Write Main.bux
  writeFile(tmpDir / "src" / "Main.bux", code)
  
  # Write bux.toml
  writeFile(tmpDir / "bux.toml", "[package]\nname = \"playground\"\nversion = \"0.1.0\"\ntype = \"bin\"\n\n[build]\noutput = \"Bin\"\n")
  
  # Build with buxc
  let buildResult = execCmdEx(Buxc & " build " & tmpDir)
  let buildOutput = buildResult.output
  
  if buildResult.exitCode != 0:
    removeDir(tmpDir)
    return (buildOutput, buildResult.exitCode, true)
  
  # Run the binary (named "playground" from bux.toml)
  let binary = tmpDir / "build" / "playground"
  if not fileExists(binary):
    removeDir(tmpDir)
    return ("Binary not found after build:\n" & buildOutput, 1, true)
  
  let runResult = execCmdEx("timeout " & $TimeoutMs div 1000 & " " & binary)
  let runOutput = runResult.output
  
  # Cleanup
  removeDir(tmpDir)
  
  return (buildOutput & "\n" & runOutput, runResult.exitCode, runResult.exitCode != 0)

# --------------- route handlers ---------------

proc handlePlayground(request: Request) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html; charset=utf-8"
  request.respond(200, headers, PlaygroundHTML)

proc handleCompile(request: Request) =
  if request.httpMethod != HttpPost:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(405, headers, "Method not allowed")
    return
  
  let code = request.body
  
  if code.len == 0:
    var headers: HttpHeaders
    headers["Content-Type"] = "application/json"
    request.respond(400, headers, $(%*{"error": "no code provided"}))
    return
  
  let (output, exitCode, isError) = compileAndRun(code)
  
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  headers["Access-Control-Allow-Origin"] = "*"
  
  let response = $(%*{
    "output": output,
    "exitCode": exitCode,
    "isError": isError
  })
  
  request.respond(200, headers, response)

# --------------- main ---------------

proc main() =
  echo "Bux Playground"
  echo "Serving on http://localhost:" & $Port
  echo "Open your browser and start coding!"
  
  var router: Router
  router.get("/", handlePlayground)
  router.post("/compile", handleCompile)
  
  let server = newServer(router)
  server.serve(Port(Port))

when isMainModule:
  main()
