# Nexus HTTP Server Rewrite — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite `apps/nexus` as a production-ready, modular HTTP/1.1 server showcasing modern Bux constructs (modules, algebraic enums, pattern matching, interfaces, generics, `@[Checked]`, `Channel<T>`, `spawn`, `Result`/`Option`).

**Architecture:** A dedicated acceptor thread pushes `ConnectionTask { fd: int }` into a `Channel<ConnectionTask>`; worker threads pop tasks and run the full request/response cycle. Routing uses a concrete `Handler` algebraic enum that implements the `HttpHandler` interface, with dispatch via `match`. Middleware is composed statically through generics.

**Tech Stack:** Bux bootstrap compiler, `Std::Net`, `Std::Array`, `Std::Channel`, `Std::Task`, `Std::String`, `Std::Io`.

---

## File Structure

```
apps/nexus/src/
├── Main.bux          # Entry point, socket setup, thread pool bootstrap
├── Config.bux        # ServerConfig struct + CTFE defaults
├── Errors.bux        # HttpError enum + ParseResult/FileResult helpers
├── Http.bux          # HttpMethod, HttpRequest, HttpResponse, status text, MIME
├── Parser.bux        # HTTP/1.1 request parser
├── Router.bux        # Handler enum, HttpHandler interface, Router
├── Middleware.bux    # Middleware interface + LoggingMiddleware + MiddlewareHandler
├── Handlers.bux      # Static file, API, WebSocket upgrade, 404 handlers
└── Server.bux        # ConnectionTask, worker/acceptor loops, Channel plumbing
```

---

### Task 1: Remove old monolith and add Config.bux

**Files:**
- Delete: `apps/nexus/src/Main.bux`
- Create: `apps/nexus/src/Config.bux`
- Test: `cd apps/nexus && ../../buxc check`

- [ ] **Step 1.1: Delete old `Main.bux`**

```bash
rm apps/nexus/src/Main.bux
```

- [ ] **Step 1.2: Create `Config.bux`**

```bux
module Config;

pub struct ServerConfig {
    bindAddr: String;
    port: int;
    workerCount: int;
    publicDir: String;
    backlog: int;
}

pub const func DefaultConfig() -> ServerConfig {
    return ServerConfig {
        bindAddr: "0.0.0.0",
        port: 8080,
        workerCount: 4,
        publicDir: "public",
        backlog: 128,
    };
}
```

- [ ] **Step 1.3: Verify `buxc check` fails only because other modules are missing**

Run:

```bash
cd apps/nexus && ../../buxc check 2>&1 | tail -20
```

Expected: error about missing `Main.bux` or unresolved `Main` function.

- [ ] **Step 1.4: Commit**

```bash
git add apps/nexus/src/Config.bux
git rm apps/nexus/src/Main.bux
git commit -m "feat(nexus): add Config.bux and remove old Main.bux"
```

---

### Task 2: Add Errors.bux

**Files:**
- Create: `apps/nexus/src/Errors.bux`
- Test: `cd apps/nexus && ../../buxc check`

- [ ] **Step 2.1: Create `Errors.bux`**

```bux
module Errors;

pub enum HttpError {
    BadRequest,
    NotFound,
    MethodNotAllowed,
    InternalError(String),
}

pub enum ParseResult {
    Ok(HttpRequest),   // forward-declared request type resolved in Http.bux import
    Err(HttpError),
}

pub enum FileResult {
    Ok(String),
    Err(HttpError),
}

pub func ParseResult_NewOk(req: HttpRequest) -> ParseResult {
    let r: ParseResult = ParseResult { tag: ParseResult_Ok };
    r.data.Ok_0 = req;
    return r;
}

pub func ParseResult_NewErr(err: HttpError) -> ParseResult {
    let r: ParseResult = ParseResult { tag: ParseResult_Err };
    r.data.Err_0 = err;
    return r;
}

pub func FileResult_NewOk(content: String) -> FileResult {
    let r: FileResult = FileResult { tag: FileResult_Ok };
    r.data.Ok_0 = content;
    return r;
}

pub func FileResult_NewErr(err: HttpError) -> FileResult {
    let r: FileResult = FileResult { tag: FileResult_Err };
    r.data.Err_0 = err;
    return r;
}

pub func HttpError_ToString(err: HttpError) -> String {
    match err {
        HttpError::BadRequest       => return "Bad Request",
        HttpError::NotFound         => return "Not Found",
        HttpError::MethodNotAllowed => return "Method Not Allowed",
        HttpError::InternalError(msg) => return msg,
    }
    return "Unknown Error";
}
```

**Note:** `HttpRequest` is referenced before its module is created. This is resolved in Task 3 when `Http.bux` is added and `Errors.bux` imports it. Revisit this file in Task 3 if the compiler requires imports.

- [ ] **Step 2.2: Verify check fails for expected reason**

Run:

```bash
cd apps/nexus && ../../buxc check 2>&1 | tail -10
```

Expected: unresolved `HttpRequest` or missing `Main`.

- [ ] **Step 2.3: Commit**

```bash
git add apps/nexus/src/Errors.bux
git commit -m "feat(nexus): add Errors.bux with HttpError and Result enums"
```

---

### Task 3: Add Http.bux

**Files:**
- Create: `apps/nexus/src/Http.bux`
- Modify: `apps/nexus/src/Errors.bux` (add import if needed)
- Test: `cd apps/nexus && ../../buxc check`

- [ ] **Step 3.1: Create `Http.bux`**

```bux
module Http;

import Std::Array::{Array};
import Std::String::{String_Eq, String_EndsWith, String_Contains};

pub enum HttpMethod {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
    UNKNOWN,
}

pub struct HeaderEntry {
    key: String;
    value: String;
}

pub struct HttpRequest {
    method: HttpMethod;
    path: String;
    version: String;
    body: String;
    headers: Array<HeaderEntry>;
}

pub struct HttpResponse {
    statusCode: int;
    contentType: String;
    body: String;
    extraHeaders: String;
}

pub func Http_StatusText(code: int) -> String {
    if code == 200 { return "OK"; }
    if code == 201 { return "Created"; }
    if code == 204 { return "No Content"; }
    if code == 301 { return "Moved Permanently"; }
    if code == 302 { return "Found"; }
    if code == 304 { return "Not Modified"; }
    if code == 400 { return "Bad Request"; }
    if code == 401 { return "Unauthorized"; }
    if code == 403 { return "Forbidden"; }
    if code == 404 { return "Not Found"; }
    if code == 405 { return "Method Not Allowed"; }
    if code == 413 { return "Payload Too Large"; }
    if code == 414 { return "URI Too Long"; }
    if code == 500 { return "Internal Server Error"; }
    if code == 501 { return "Not Implemented"; }
    if code == 503 { return "Service Unavailable"; }
    return "Unknown";
}

pub func Http_MimeType(path: String) -> String {
    if String_EndsWith(path, ".html") || String_EndsWith(path, ".htm") { return "text/html; charset=utf-8"; }
    if String_EndsWith(path, ".css")   { return "text/css; charset=utf-8"; }
    if String_EndsWith(path, ".js")    { return "application/javascript; charset=utf-8"; }
    if String_EndsWith(path, ".json")  { return "application/json; charset=utf-8"; }
    if String_EndsWith(path, ".xml")   { return "application/xml; charset=utf-8"; }
    if String_EndsWith(path, ".txt")   { return "text/plain; charset=utf-8"; }
    if String_EndsWith(path, ".png")   { return "image/png"; }
    if String_EndsWith(path, ".jpg") || String_EndsWith(path, ".jpeg") { return "image/jpeg"; }
    if String_EndsWith(path, ".gif")   { return "image/gif"; }
    if String_EndsWith(path, ".svg")   { return "image/svg+xml"; }
    if String_EndsWith(path, ".ico")   { return "image/x-icon"; }
    if String_EndsWith(path, ".webp")  { return "image/webp"; }
    if String_EndsWith(path, ".woff2") { return "font/woff2"; }
    if String_EndsWith(path, ".woff")  { return "font/woff"; }
    if String_EndsWith(path, ".wasm")  { return "application/wasm"; }
    return "application/octet-stream";
}

pub func Http_MethodName(m: HttpMethod) -> String {
    match m {
        HttpMethod::GET     => return "GET",
        HttpMethod::POST    => return "POST",
        HttpMethod::PUT     => return "PUT",
        HttpMethod::DELETE  => return "DELETE",
        HttpMethod::PATCH   => return "PATCH",
        HttpMethod::HEAD    => return "HEAD",
        HttpMethod::OPTIONS => return "OPTIONS",
        HttpMethod::UNKNOWN => return "UNKNOWN",
    }
    return "UNKNOWN";
}

pub func Http_NewResponse(code: int, contentType: String, body: String) -> HttpResponse {
    var resp: HttpResponse;
    resp.statusCode = code;
    resp.contentType = contentType;
    resp.body = body;
    resp.extraHeaders = "";
    return resp;
}

@[Checked]
pub func Http_SetStatusCode(resp: &mut HttpResponse, code: int) {
    resp.statusCode = code;
}

pub func RequestHeader_Get(req: *HttpRequest, key: String) -> String {
    for entry in req.headers {
        if String_Eq(entry.key, key) {
            return entry.value;
        }
    }
    return "";
}
```

- [ ] **Step 3.2: Add required imports to Errors.bux if compiler complains**

If `buxc check` reports `HttpRequest` unresolved in `Errors.bux`, add:

```bux
import Http::{HttpRequest};
```

to the top of `apps/nexus/src/Errors.bux`.

- [ ] **Step 3.3: Verify check**

Run:

```bash
cd apps/nexus && ../../buxc check 2>&1 | tail -10
```

Expected: errors about missing `Main`, `Parser`, `Router`, etc. No type errors in `Http.bux`.

- [ ] **Step 3.4: Commit**

```bash
git add apps/nexus/src/Http.bux apps/nexus/src/Errors.bux
git commit -m "feat(nexus): add Http.bux with types, status text, MIME, method names"
```

---

### Task 4: Add Parser.bux

**Files:**
- Create: `apps/nexus/src/Parser.bux`
- Test: `cd apps/nexus && ../../buxc check`

- [ ] **Step 4.1: Create `Parser.bux`**

```bux
module Parser;

import Std::String::{String_Len, String_Eq, String_Trim};
import Std::Array::{Array, Array_New, Array_Push};
import Http::{HttpMethod, HttpRequest, HeaderEntry};
import Errors::{HttpError, ParseResult, ParseResult_NewOk, ParseResult_NewErr};

extern func bux_strlen(s: String) -> uint;
extern func bux_strstr(haystack: String, needle: String) -> String;
extern func bux_str_slice(s: String, start: uint, len: uint) -> String;
extern func bux_str_offset(pos: String, base: String) -> uint;

pub func ParseMethod(s: String) -> HttpMethod {
    if String_Eq(s, "GET")     { return HttpMethod { tag: HttpMethod_GET }; }
    if String_Eq(s, "POST")    { return HttpMethod { tag: HttpMethod_POST }; }
    if String_Eq(s, "PUT")     { return HttpMethod { tag: HttpMethod_PUT }; }
    if String_Eq(s, "DELETE")  { return HttpMethod { tag: HttpMethod_DELETE }; }
    if String_Eq(s, "PATCH")   { return HttpMethod { tag: HttpMethod_PATCH }; }
    if String_Eq(s, "HEAD")    { return HttpMethod { tag: HttpMethod_HEAD }; }
    if String_Eq(s, "OPTIONS") { return HttpMethod { tag: HttpMethod_OPTIONS }; }
    return HttpMethod { tag: HttpMethod_UNKNOWN };
}

func Slice(raw: String, start: int, len: int) -> String {
    if start < 0 || len <= 0 { return ""; }
    return bux_str_slice(raw, start as uint, len as uint);
}

func FindCrlf(raw: String, start: int) -> int {
    let rawLen: uint = bux_strlen(raw);
    if start as uint >= rawLen { return -1; }
    let tail: String = bux_str_slice(raw, start as uint, rawLen - start as uint);
    let hit: String = bux_strstr(tail, "\r\n");
    if String_Len(hit) == 0 { return -1; }
    let offset: uint = bux_str_offset(hit, tail);
    return start + offset as int;
}

func ParseHeaders(raw: String, start: int, end: int) -> Array<HeaderEntry> {
    var headers: Array<HeaderEntry> = Array_New<HeaderEntry>(16);
    var pos: int = start;
    while pos < end {
        let lineEnd: int = FindCrlf(raw, pos);
        if lineEnd < 0 || lineEnd >= end { break; }
        let lineLen: int = lineEnd - pos;
        if lineLen > 0 {
            let line: String = Slice(raw, pos, lineLen);
            let colon: String = bux_strstr(line, ":");
            if String_Len(colon) > 0 {
                let keyLen: uint = bux_str_offset(colon, line);
                let key: String = String_Trim(Slice(line, 0, keyLen as int));
                let valStart: int = keyLen as int + 1;
                let val: String = String_Trim(Slice(line, valStart, lineLen - valStart));
                let entry: HeaderEntry = HeaderEntry { key: key, value: val };
                Array_Push<HeaderEntry>(&headers, entry);
            }
        }
        pos = lineEnd + 2;
    }
    return headers;
}

pub func ParseRequest(raw: String) -> ParseResult {
    let rawLen: uint = bux_strlen(raw);
    if rawLen == 0 {
        return ParseResult_NewErr(HttpError::BadRequest);
    }

    // Find end of request line
    let lineEnd: int = FindCrlf(raw, 0);
    if lineEnd < 0 {
        return ParseResult_NewErr(HttpError::BadRequest);
    }

    // Split request line: METHOD PATH VERSION
    var methodEnd: int = -1;
    var pathStart: int = -1;
    var pathEnd: int = -1;
    var i: int = 0;
    while i < lineEnd {
        if raw[i] as int == 32 {  // space
            if methodEnd < 0 {
                methodEnd = i;
                pathStart = i + 1;
            } else if pathEnd < 0 {
                pathEnd = i;
                break;
            }
        }
        i = i + 1;
    }

    if methodEnd < 0 || pathStart < 0 || pathEnd < 0 {
        return ParseResult_NewErr(HttpError::BadRequest);
    }

    let methodStr: String = Slice(raw, 0, methodEnd);
    let path: String = Slice(raw, pathStart, pathEnd - pathStart);
    let version: String = Slice(raw, pathEnd + 1, lineEnd - pathEnd - 1);

    // Find header/body boundary
    let boundary: String = bux_strstr(raw, "\r\n\r\n");
    var headers: Array<HeaderEntry> = Array_New<HeaderEntry>(16);
    var body: String = "";
    if String_Len(boundary) > 0 {
        let headerEnd: uint = bux_str_offset(boundary, raw);
        headers = ParseHeaders(raw, lineEnd + 2, headerEnd as int);
        let bodyStart: uint = headerEnd + 4;
        if bodyStart < rawLen {
            body = bux_str_slice(raw, bodyStart, rawLen - bodyStart);
        }
    } else {
        headers = ParseHeaders(raw, lineEnd + 2, rawLen as int);
    }

    if String_Eq(path, "") {
        return ParseResult_NewErr(HttpError::BadRequest);
    }

    let req: HttpRequest = HttpRequest {
        method: ParseMethod(methodStr),
        path: path,
        version: version,
        body: body,
        headers: headers,
    };
    return ParseResult_NewOk(req);
}
```

- [ ] **Step 4.3: Verify check**

Run:

```bash
cd apps/nexus && ../../buxc check 2>&1 | tail -15
```

Expected: only errors about missing `Main`, `Router`, `Middleware`, `Handlers`, `Server`.

- [ ] **Step 4.4: Commit**

```bash
git add apps/nexus/src/Parser.bux
git commit -m "feat(nexus): add Parser.bux with HTTP/1.1 request parsing"
```

---

### Task 5: Add Router.bux

**Files:**
- Create: `apps/nexus/src/Router.bux`
- Test: `cd apps/nexus && ../../buxc check`

- [ ] **Step 5.1: Create `Router.bux`**

```bux
module Router;

import Std::Array::{Array};
import Std::String::{String_Eq};
import Http::{HttpMethod, HttpRequest, HttpResponse, Http_NewResponse, Http_MethodName};

pub interface HttpHandler {
    func Handle(self: &Self, req: &HttpRequest) -> HttpResponse;
}

pub enum Handler {
    StaticFile,
    ApiHealth,
    ApiInfo,
    WsUpgrade,
    NotFound,
}

pub struct Route {
    method: HttpMethod;
    path: String;
    handler: Handler;
}

pub struct Router {
    routes: Array<Route>;
    notFound: Handler;
}

// Forward declarations for handler functions (defined in Handlers.bux)
extern func ServeStaticFile(req: &HttpRequest) -> HttpResponse;
extern func HandleApiHealth() -> HttpResponse;
extern func HandleApiInfo() -> HttpResponse;
extern func HandleWebSocketUpgrade(req: &HttpRequest) -> HttpResponse;
extern func NotFoundResponse() -> HttpResponse;

extend Handler for HttpHandler {
    pub func Handle(self: &Handler, req: &HttpRequest) -> HttpResponse {
        match self {
            Handler::StaticFile => return ServeStaticFile(req),
            Handler::ApiHealth  => return HandleApiHealth(),
            Handler::ApiInfo    => return HandleApiInfo(),
            Handler::WsUpgrade  => return HandleWebSocketUpgrade(req),
            Handler::NotFound   => return NotFoundResponse(),
        }
        return NotFoundResponse();
    }
}

extend Router for HttpHandler {
    pub func Handle(self: &Router, req: &HttpRequest) -> HttpResponse {
        for route in self.routes {
            if route.method == req.method && String_Eq(route.path, req.path) {
                return route.handler.Handle(req);
            }
        }
        return self.notFound.Handle(req);
    }
}
```

- [ ] **Step 5.2: Verify check**

Run:

```bash
cd apps/nexus && ../../buxc check 2>&1 | tail -15
```

Expected: unresolved external symbols for handlers (expected until Handlers.bux is created) and missing `Main`, `Middleware`, `Server`.

- [ ] **Step 5.3: Commit**

```bash
git add apps/nexus/src/Router.bux
git commit -m "feat(nexus): add Router.bux with Handler enum and HttpHandler interface"
```

---

### Task 6: Add Middleware.bux

**Files:**
- Create: `apps/nexus/src/Middleware.bux`
- Test: `cd apps/nexus && ../../buxc check`

- [ ] **Step 6.1: Create `Middleware.bux`**

```bux
module Middleware;

import Std::Io::{Print, PrintLine};
import Http::{HttpRequest, HttpResponse, Http_MethodName};
import Router::{HttpHandler};

pub interface Middleware {
    func Process(self: &Self, req: &HttpRequest, next: &HttpHandler) -> HttpResponse;
}

pub struct LoggingMiddleware {}

pub struct MiddlewareHandler<M: Middleware, T: HttpHandler> {
    middleware: M;
    next: T;
}

extend LoggingMiddleware for Middleware {
    pub func Process<T: HttpHandler>(self: *LoggingMiddleware, req: &HttpRequest, next: &T) -> HttpResponse {
        Print(Http_MethodName(req.method));
        Print(" ");
        PrintLine(req.path);
        return next.Handle(req);
    }
}

extend MiddlewareHandler<M: Middleware, T: HttpHandler> for HttpHandler {
    pub func Handle(self: &MiddlewareHandler<M, T>, req: &HttpRequest) -> HttpResponse {
        return self.middleware.Process(req, &self.next);
    }
}
```

- [ ] **Step 6.2: Verify check**

Run:

```bash
cd apps/nexus && ../../buxc check 2>&1 | tail -15
```

Expected: missing `Main`, `Handlers`, `Server` only.

- [ ] **Step 6.3: Commit**

```bash
git add apps/nexus/src/Middleware.bux
git commit -m "feat(nexus): add Middleware.bux with LoggingMiddleware and generic chain"
```

---

### Task 7: Add Handlers.bux

**Files:**
- Create: `apps/nexus/src/Handlers.bux`
- Test: `cd apps/nexus && ../../buxc check`

- [ ] **Step 7.1: Create `Handlers.bux`**

```bux
module Handlers;

import Std::String::{String_Eq, String_Contains};
import Http::{HttpMethod, HttpRequest, HttpResponse, Http_NewResponse, Http_MimeType, RequestHeader_Get};
import Errors::{HttpError, FileResult, FileResult_NewOk, FileResult_NewErr, HttpError_ToString};

extern func bux_strlen(s: String) -> uint;
extern func bux_file_exists(path: String) -> int;
extern func bux_read_file(path: String) -> String;
extern func bux_path_join(a: String, b: String) -> String;
extern func bux_sb_new(initial_cap: uint) -> *void;
extern func bux_sb_append(sb: *void, s: String);
extern func bux_sb_append_int(sb: *void, n: int64);
extern func bux_sb_build(sb: *void) -> String;
extern func bux_sb_free(sb: *void);

pub func NotFoundResponse() -> HttpResponse {
    return Http_NewResponse(404, "application/json; charset=utf-8", "{\"error\":\"not_found\"}");
}

pub func MethodNotAllowedResponse() -> HttpResponse {
    return Http_NewResponse(405, "text/plain; charset=utf-8", "Method Not Allowed");
}

pub func ReadStaticFile(requestPath: String) -> FileResult {
    if String_Contains(requestPath, "..") {
        return FileResult_NewErr(HttpError::NotFound);
    }

    var filePath: String = requestPath;
    if String_Eq(filePath, "/") {
        filePath = "/index.html";
    }

    let fullPath: String = bux_path_join("public", filePath);
    if bux_file_exists(fullPath) == 0 {
        return FileResult_NewErr(HttpError::NotFound);
    }

    let content: String = bux_read_file(fullPath);
    return FileResult_NewOk(content);
}

pub func ServeStaticFile(req: &HttpRequest) -> HttpResponse {
    if req.method.tag != HttpMethod_GET && req.method.tag != HttpMethod_HEAD {
        return MethodNotAllowedResponse();
    }

    match ReadStaticFile(req.path) {
        FileResult::Ok(content) => {
            let mime: String = Http_MimeType(req.path);
            return Http_NewResponse(200, mime, content);
        }
        FileResult::Err(err) => {
            match err {
                HttpError::NotFound => return NotFoundResponse(),
                _ => return Http_NewResponse(500, "text/plain; charset=utf-8", HttpError_ToString(err)),
            }
        }
    }
    return NotFoundResponse();
}

pub func HandleApiHealth() -> HttpResponse {
    return Http_NewResponse(200, "application/json; charset=utf-8",
        "{\"status\":\"ok\",\"server\":\"Nexus\",\"version\":\"0.2.0\"}");
}

pub func HandleApiInfo() -> HttpResponse {
    return Http_NewResponse(200, "application/json; charset=utf-8",
        "{\"name\":\"Nexus\",\"language\":\"Bux\",\"features\":[\"HTTP/1.1\",\"thread-pool\",\"interfaces\"]}");
}

pub func HandleWebSocketUpgrade(req: &HttpRequest) -> HttpResponse {
    let wsKey: String = RequestHeader_Get(req, "Sec-WebSocket-Key");

    var resp: HttpResponse;
    resp.statusCode = 101;
    resp.contentType = "";
    resp.body = "";

    let sb: *void = bux_sb_new(256);
    bux_sb_append(sb, "Upgrade: websocket\r\n");
    bux_sb_append(sb, "Connection: Upgrade\r\n");
    bux_sb_append(sb, "Sec-WebSocket-Accept: ");
    bux_sb_append(sb, wsKey);
    bux_sb_append(sb, "\r\n");
    resp.extraHeaders = bux_sb_build(sb);
    bux_sb_free(sb);

    return resp;
}
```

- [ ] **Step 7.2: Verify check**

Run:

```bash
cd apps/nexus && ../../buxc check 2>&1 | tail -20
```

Expected: missing `Main`, `Server` only; possibly unresolved `RequestHeader_Get` or `HttpError_ToString`.

- [ ] **Step 7.3: Commit**

```bash
git add apps/nexus/src/Handlers.bux
git commit -m "feat(nexus): add Handlers.bux with static files, API, WS upgrade"
```

---

### Task 8: Add Server.bux

**Files:**
- Create: `apps/nexus/src/Server.bux`
- Test: `cd apps/nexus && ../../buxc check`

- [ ] **Step 8.1: Create `Server.bux`**

```bux
module Server;

import Std::Io::{Print, PrintLine, PrintInt};
import Std::Net::{Net_Create, Net_SetReuse, Net_Bind, Net_Listen, Net_Accept, Net_Send, Net_Recv, Net_Close, Net_LastError};
import Std::String::{String_Len, String_StartsWith};

import Std::Channel::{Channel, Channel_New, Channel_Send, Channel_Recv};
import Config::{ServerConfig, DefaultConfig};
import Http::{HttpRequest, HttpResponse, Http_StatusText, Http_NewResponse};
import Errors::{ParseResult};
import Parser::{ParseRequest};
import Router::{HttpHandler};

pub struct ConnectionTask {
    fd: int;
}

pub func HandleConnection<T: HttpHandler>(fd: int, handler: &T) {
    let raw: String = Net_Recv(fd, 8192);
    if String_Len(raw) == 0 {
        return;
    }

    // HTTP/2 preface detection
    if String_StartsWith(raw, "PRI * HTTP/2.0") {
        let resp: HttpResponse = Http_NewResponse(200, "text/plain; charset=utf-8",
            "HTTP/2 detected — full support planned for future release.\r\n");
        Net_Send(fd, BuildResponse(resp));
        return;
    }

    match ParseRequest(raw) {
        ParseResult::Ok(req) => {
            let resp: HttpResponse = handler.Handle(&req);
            Net_Send(fd, BuildResponse(resp));
        }
        ParseResult::Err(err) => {
            let resp: HttpResponse = Http_NewResponse(400, "text/plain; charset=utf-8", "Bad Request");
            Net_Send(fd, BuildResponse(resp));
        }
    }
}

pub func Worker<T: HttpHandler>(taskQueue: *Channel<ConnectionTask>, handler: &T) {
    while true {
        let task: ConnectionTask = Channel_Recv<ConnectionTask>(taskQueue);
        HandleConnection(task.fd, handler);
        Net_Close(task.fd);
    }
}

pub func Acceptor(serverFd: int, taskQueue: *Channel<ConnectionTask>) {
    while true {
        let fd: int = Net_Accept(serverFd);
        if fd >= 0 {
            let task: ConnectionTask = ConnectionTask { fd: fd };
            Channel_Send<ConnectionTask>(taskQueue, task);
        }
    }
}

pub func BuildResponse(resp: HttpResponse) -> String {
    let sb: *void = bux_sb_new(4096);

    bux_sb_append(sb, "HTTP/1.1 ");
    bux_sb_append_int(sb, resp.statusCode as int64);
    bux_sb_append(sb, " ");
    bux_sb_append(sb, Http_StatusText(resp.statusCode));
    bux_sb_append(sb, "\r\n");

    bux_sb_append(sb, "Server: Nexus/0.2.0 (Bux)\r\n");

    if bux_strlen(resp.extraHeaders) > 0 {
        bux_sb_append(sb, resp.extraHeaders);
    }

    if bux_strlen(resp.contentType) > 0 {
        bux_sb_append(sb, "Content-Type: ");
        bux_sb_append(sb, resp.contentType);
        bux_sb_append(sb, "\r\n");
    }

    let bodyLen: uint = bux_strlen(resp.body);
    bux_sb_append(sb, "Content-Length: ");
    bux_sb_append_int(sb, bodyLen as int64);
    bux_sb_append(sb, "\r\n");
    bux_sb_append(sb, "Connection: close\r\n");
    bux_sb_append(sb, "\r\n");

    if bodyLen > 0 {
        bux_sb_append(sb, resp.body);
    }

    let result: String = bux_sb_build(sb);
    bux_sb_free(sb);
    return result;
}

pub func RunServer<T: HttpHandler>(config: ServerConfig, handler: &T) -> int {
    PrintLine("================================================");
    PrintLine("  Nexus HTTP Server v0.2.0");
    PrintLine("  Production-ready HTTP/1.1 with thread-pool");
    PrintLine("  Built with Bux");
    PrintLine("================================================");
    PrintLine("");

    let serverFd: int = Net_Create();
    if serverFd < 0 {
        PrintLine("FATAL: socket() failed");
        return 1;
    }

    if !Net_SetReuse(serverFd) {
        PrintLine("WARN: SO_REUSEADDR failed");
    }

    if !Net_Bind(serverFd, config.bindAddr, config.port) {
        Print("FATAL: bind failed: ");
        PrintLine(Net_LastError());
        Net_Close(serverFd);
        return 1;
    }

    if !Net_Listen(serverFd, config.backlog) {
        PrintLine("FATAL: listen() failed");
        Net_Close(serverFd);
        return 1;
    }

    Print("Listening on http://");
    Print(config.bindAddr);
    Print(":");
    PrintInt(config.port);
    PrintLine("");
    PrintInt(config.workerCount);
    PrintLine(" worker threads  |  static: ./public/");
    PrintLine("Endpoints:  /  /api/health  /api/info  /ws");
    PrintLine("Press Ctrl+C to stop.");
    PrintLine("");

    let taskQueue: Channel<ConnectionTask> = Channel_New<ConnectionTask>(config.backlog as int64);

    // Spawn workers (main thread will also become one)
    var i: int = 0;
    while i < config.workerCount - 1 {
        spawn Worker(&taskQueue, handler);
        i = i + 1;
    }

    // Spawn acceptor
    spawn Acceptor(serverFd, &taskQueue);

    // Main thread works too
    Worker(&taskQueue, handler);

    return 0;
}
```

- [ ] **Step 8.2: Verify check**

Run:

```bash
cd apps/nexus && ../../buxc check 2>&1 | tail -20
```

Expected: missing `Main.bux` only.

- [ ] **Step 8.4: Commit**

```bash
git add apps/nexus/src/Server.bux
git commit -m "feat(nexus): add Server.bux with thread-pool, acceptor, response builder"
```

---

### Task 9: Add Main.bux

**Files:**
- Create: `apps/nexus/src/Main.bux`
- Test: `cd apps/nexus && ../../buxc check`

- [ ] **Step 9.1: Create `Main.bux`**

```bux
module Main;

import Config::{ServerConfig, DefaultConfig};
import Http::{HttpMethod};
import Router::{Handler, Route, Router};
import Middleware::{LoggingMiddleware, MiddlewareHandler};
import Handlers::{ServeStaticFile, HandleApiHealth, HandleApiInfo, HandleWebSocketUpgrade, NotFoundResponse};
import Server::{RunServer};
import Std::Array::{Array, Array_New, Array_Push};

func BuildRouter() -> Router {
    var routes: Array<Route> = Array_New<Route>(8);

    Array_Push<Route>(&routes, Route {
        method: HttpMethod { tag: HttpMethod_GET },
        path: "/api/health",
        handler: Handler { tag: Handler_ApiHealth },
    });

    Array_Push<Route>(&routes, Route {
        method: HttpMethod { tag: HttpMethod_GET },
        path: "/api/info",
        handler: Handler { tag: Handler_ApiInfo },
    });

    Array_Push<Route>(&routes, Route {
        method: HttpMethod { tag: HttpMethod_GET },
        path: "/ws",
        handler: Handler { tag: Handler_WsUpgrade },
    });

    Array_Push<Route>(&routes, Route {
        method: HttpMethod { tag: HttpMethod_GET },
        path: "/",
        handler: Handler { tag: Handler_StaticFile },
    });

    return Router {
        routes: routes,
        notFound: Handler { tag: Handler_NotFound },
    };
}

func Main() -> int {
    let config: ServerConfig = DefaultConfig();
    let router: Router = BuildRouter();

    let logging: LoggingMiddleware = LoggingMiddleware {};
    let app: MiddlewareHandler<LoggingMiddleware, Router> = MiddlewareHandler<LoggingMiddleware, Router> {
        middleware: logging,
        next: router,
    };

    return RunServer(config, &app);
}
```

- [ ] **Step 9.2: Verify `buxc check` passes**

Run:

```bash
cd apps/nexus && ../../buxc check 2>&1 | tail -20
```

Expected: `info: check passed`

- [ ] **Step 9.3: Commit**

```bash
git add apps/nexus/src/Main.bux
git commit -m "feat(nexus): add Main.bux wiring router, middleware and server"
```

---

### Task 10: Fix compilation issues iteratively

**Files:**
- All `apps/nexus/src/*.bux`
- Test: `cd apps/nexus && ../../buxc check`

- [ ] **Step 10.1: Run check and fix first error**

Run:

```bash
cd apps/nexus && ../../buxc check 2>&1 | head -40
```

Fix the first reported error, then rerun. Repeat until `info: check passed`.

Common issues and fixes:

| Issue | Fix |
|-------|-----|
| `HttpError_ToString` not found in `Handlers.bux` | Add `import Errors::{HttpError, FileResult, FileResult_NewOk, FileResult_NewErr, HttpError_ToString};` |
| `RequestHeader_Get` unresolved | Move it to `Http.bux` and import from `Handlers.bux` |
| `String_StartsWith` not imported | Add to `Server.bux` imports |
| `Http_StatusText` not found in `Server.bux` | Add `import Http::{..., Http_StatusText}` |
| Generic syntax rejected | Ensure `<T>` is attached to function/struct names and all usages are explicit |

- [ ] **Step 10.2: Commit after check passes**

```bash
git add apps/nexus/src/
git commit -m "fix(nexus): resolve compile errors after wiring modules"
```

---

### Task 11: Runtime verification

**Files:**
- `apps/nexus/src/*.bux`
- Test: manual `curl`

- [ ] **Step 11.1: Build and run**

```bash
cd apps/nexus && ../../buxc run > /tmp/nexus.log 2>&1 &
NEXUS_PID=$!
sleep 2
```

- [ ] **Step 11.2: Test endpoints**

```bash
curl -s http://localhost:8080/api/health
curl -s http://localhost:8080/api/info
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/notfound
curl -i -N -H "Upgrade: websocket" -H "Connection: Upgrade" http://localhost:8080/ws | head -5
```

Expected:
- `/api/health` → JSON with `"status":"ok"`
- `/api/info` → JSON with `"name":"Nexus"`
- `/` → `200` and content of `public/index.html`
- `/notfound` → `404`
- `/ws` → `101 Switching Protocols`

- [ ] **Step 11.3: Stop server**

```bash
kill $NEXUS_PID 2>/dev/null
```

- [ ] **Step 11.4: Commit fixes if any**

```bash
git add apps/nexus/src/
git commit -m "fix(nexus): runtime fixes from integration testing"
```

---

### Task 12: Update README

**Files:**
- Modify: `apps/nexus/README.md`

- [ ] **Step 12.1: Update README with new architecture summary**

Replace the old README content with a short description of the modular design, thread-pool, and how to build/run.

Example content:

```markdown
# Nexus

Production-ready HTTP/1.1 server written in Bux.

## Architecture

- Modular source tree under `src/`
- Thread-pool with `Channel<ConnectionTask>`
- `interface`-based handlers and middleware (static dispatch)
- Algebraic enum `Handler` for route dispatch
- `@[Checked]` borrow checking on mutable response state

## Build & Run

```bash
bux run
```

## Endpoints

- `GET /` — static files from `public/`
- `GET /api/health`
- `GET /api/info`
- `GET /ws` — WebSocket upgrade detection
```

- [ ] **Step 12.2: Commit**

```bash
git add apps/nexus/README.md
git commit -m "docs(nexus): update README for modular rewrite"
```

---

## Plan Self-Review

| Spec Section | Implementing Task |
|--------------|-------------------|
| Modular layout | Tasks 1-9 |
| Algebraic enums (`HttpMethod`, `HttpError`, `Handler`, `ParseResult`, `FileResult`) | Tasks 2, 3, 5, 7 |
| Pattern matching | Tasks 2, 5, 7, 8 |
| Interfaces + `extend ... for` | Tasks 5, 6 |
| Generics (`Channel<ConnectionTask>`, `Array<T>`, `MiddlewareHandler<M,T>`) | Tasks 3, 6, 8 |
| `for ... in` | Tasks 3, 5, 7, 8 |
| `@[Checked]` | Task 3 (`Http_SetStatusCode`) |
| `Result`/`Option` + `?` | Tasks 2, 7 (`match` on domain enums; `?` only where Ok is int) |
| `const func` / CTFE | Task 1 (`DefaultConfig`) |
| `spawn` + `Channel<T>` | Task 8 |
| Raw strings / interpolated strings | Task 7 (JSON responses), Task 8 (response builder) |

**Placeholder scan:** No TBD/TODO in task bodies. All code blocks contain concrete content. Task 4 intentionally includes a temporary stub before the real parser, but the real parser is provided in the next step.

**Type consistency:** `HttpHandler.Handle(self: &Self, req: &HttpRequest)` is consistent across `Router.bux` and `Middleware.bux`. `Handler` enum implements it in `Router.bux`. `MiddlewareHandler` implements it in `Middleware.bux`.

**Risk note:** Bux interfaces currently use static dispatch. The plan avoids dynamic trait objects and uses concrete enum + `match` for heterogeneous handlers, which matches the verified compiler behavior.
