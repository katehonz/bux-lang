# Nexus HTTP Server Rewrite — Design Spec

**Date:** 2026-06-14  
**Goal:** Rewrite `apps/nexus` as a production-ready, modular HTTP/1.1 server that exercises modern Bux language features.

---

## 1. Scope

Keep the same observable behavior as the current Nexus app, but restructure it for production quality:

- HTTP/1.1 request parsing
- Static file serving from `./public/`
- API endpoints: `GET /api/health`, `GET /api/info`
- WebSocket upgrade detection on `/ws`
- Multi-threaded request handling

What changes:
- Monolithic `Main.bux` → modular source tree
- Function-pointer dispatch → `interface`-based handlers and middleware
- Ad-hoc error handling → algebraic enum `Result`/`Option` patterns
- Raw pointer buffer parsing → `@[Checked]` borrow-checked parsing
- Direct worker spawn → thread-pool backed by `Channel<ConnectionTask>`

---

## 2. Module Layout

```
apps/nexus/
├── bux.toml
├── README.md
├── public/
│   ├── index.html
│   └── 404.html
└── src/
    ├── Main.bux          # Entry point: config, socket setup, spawn workers, run acceptor
    ├── Config.bux        # ServerConfig struct + CTFE defaults
    ├── Errors.bux        # HttpError enum + Result/Option helpers
    ├── Http.bux          # HttpMethod enum, Request/Response structs, status text, MIME
    ├── Parser.bux        # @[Checked] HTTP/1.1 request parser
    ├── Router.bux        # Route, Router, HttpHandler interface
    ├── Middleware.bux    # Middleware interface + LoggingMiddleware
    ├── Handlers.bux      # Static files, API, WebSocket upgrade, 404
    └── Server.bux        # ConnectionTask, Worker, acceptor loop, channel plumbing
```

---

## 3. Language Features to Exercise

| Feature | Where |
|---------|-------|
| Modules & `pub`/`private` | Every file |
| Algebraic enums | `HttpMethod`, `HttpError`, `ParseResult` |
| Pattern matching (`match`) | Error dispatch in `Main`, method parsing |
| Structs + `extend` methods | `HttpRequest`, `HttpResponse`, `Router`, `ServerConfig` |
| `interface` + `extend ... for` | `HttpHandler`, `Middleware` |
| Generics | `Channel<ConnectionTask>` |
| `for ... in` loops | Header iteration, route dispatch (over `Array<HeaderEntry>` and `Array<Route>`) |
| `Array<T>` generic container | Header storage, route table |
| `@[Checked]` + `&` / `&mut` | `Parser.bux` string buffer access |
| `Result` + `?` operator | Parser fallible operations |
| `const func` / CTFE | Default config values |
| `spawn` + `Channel<T>` | Thread-pool in `Server.bux` |
| Raw multi-line / interpolated strings | Response templates, logs |

---

## 4. Core Types

### 4.1 HTTP Types (`Http.bux`)

```bux
pub enum HttpMethod {
    GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS, UNKNOWN,
}

pub enum HttpError {
    BadRequest,
    NotFound,
    MethodNotAllowed,
    InternalError(String),
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
```

### 4.2 Result Types (`Errors.bux`)

Bux's `Std::Result` only carries `int` in `Ok`, so Nexus defines domain-specific enums:

```bux
pub enum ParseResult {
    Ok(HttpRequest),
    Err(HttpError),
}

pub enum FileResult {
    Ok(String),
    Err(HttpError),
}
```

Helpers:
- `ParseResult_IsOk`, `ParseResult_UnwrapOr`
- `FileResult_IsOk`, `FileResult_UnwrapOr`

If the bootstrap `?` operator only recognizes `Result`/`Option` with exact variant names, parser code will fall back to explicit `match`.

### 4.3 Handler & Middleware Interfaces

```bux
// Router.bux
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

extend Handler for HttpHandler {
    func Handle(self: &Handler, req: &HttpRequest) -> HttpResponse {
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

pub struct Route {
    method: HttpMethod;
    path: String;
    handler: Handler;
}

pub struct Router {
    routes: Array<Route>;
    notFound: Handler;
}

// Middleware.bux
pub interface Middleware {
    func Process(self: &Self, req: &HttpRequest, next: &HttpHandler) -> HttpResponse;
}
```

Bux interfaces currently support static dispatch through generics, not dynamic `*Handler` pointers. The route table stores the concrete `Handler` enum and dispatches via `match` (showcasing algebraic enums + pattern matching). Middleware uses the interface with generic bounds (`T: HttpHandler`) for static composition.

---

## 5. Data Flow

1. `Main` reads `ServerConfig` and creates a listening socket.
2. `Main` spawns `workerCount - 1` worker threads; the main thread becomes the last worker.
3. `Main` spawns one dedicated acceptor thread that loops on `Net_Accept` and pushes `ConnectionTask { fd }` into `Channel<ConnectionTask>`.
4. Each worker loops:
   ```
   task = Channel_Recv(&taskQueue)
   HandleConnection(task.fd, &appHandler)
   Net_Close(task.fd)
   ```
5. `HandleConnection`:
   - `Net_Recv` raw request
   - `ParseRequest(raw)` → `ParseResult` (matched explicitly; `?` is used only for `Result`/int payloads)
   - On success, `Router.Dispatch(&req)` or middleware chain
   - `Http_BuildResponse(resp)` + `Net_Send`

---

## 6. Parser Design (`Parser.bux`)

Parser functions take the raw request by value (`String` is already a C-string reference) and build an `HttpRequest`:

```bux
pub func ParseRequest(raw: String) -> ParseResult {
    match FindToken(raw, " ") {
        ParseResult::Ok(end) => {
            let methodStr: String = Slice(raw, 0, end);
            let method: HttpMethod = ParseMethod(methodStr);
            // ... path, version, headers, body
            return ParseResult_NewOk(req);
        }
        ParseResult::Err(e) => return ParseResult_NewErr(e),
    }
}
```

`@[Checked]` is used where mutable borrows make sense (e.g. `SetResponseCode(resp: &mut HttpResponse, code: int)`), not on raw string parsing.

Headers are stored in a dynamically grown `Array<HeaderEntry>`.

---

## 7. Router & Middleware

### 7.1 Router Dispatch

```bux
extend Router {
    pub func Dispatch(self: *Router, req: &HttpRequest) -> HttpResponse {
        for route in self.routes {
            if route.method == req.method && String_Eq(route.path, req.path) {
                return route.handler.Handle(req);  // Handler enum implements HttpHandler
            }
        }
        return self.notFound.Handle(req);
    }
}
```

### 7.2 Middleware Chain

`LoggingMiddleware` logs method/path and delegates to `next`:

```bux
pub struct LoggingMiddleware {}

extend LoggingMiddleware for Middleware {
    func Process<T: HttpHandler>(self: *LoggingMiddleware, req: &HttpRequest, next: &T) -> HttpResponse {
        Print(Http_MethodName(req.method));
        Print(" ");
        PrintLine(req.path);
        return next.Handle(req);
    }
}
```

Chaining is achieved with a generic `MiddlewareHandler<M: Middleware, T: HttpHandler>` struct that implements `HttpHandler` and holds `(middleware, next)`. This uses Bux's static-dispatch interfaces (no vtable pointers).

---

## 8. Handlers (`Handlers.bux`)

| Handler | Purpose |
|---------|---------|
| `StaticFileHandler` | Serve files from `public/` with MIME sniffing and path-traversal guard |
| `HealthHandler` | `GET /api/health` → JSON status |
| `InfoHandler` | `GET /api/info` → JSON server info |
| `WsUpgradeHandler` | `GET /ws` or `Upgrade: websocket` → 101 response with placeholder accept key |
| `NotFoundHandler` | 404 JSON/text fallback |

All implement `HttpHandler`.

---

## 9. Server & Thread Pool (`Server.bux`)

```bux
pub struct ConnectionTask {
    fd: int;
}

pub struct Server {
    config: ServerConfig;
    taskQueue: Channel<ConnectionTask>;
    handler: *HttpHandler;
}
```

Flow:
1. `Server_Run(&server)` creates socket, binds, listens.
2. Spawns workers; each calls `Worker_Run(&server)`.
3. `Acceptor_Run(&server)` loops:
   ```bux
   let fd: int = Net_Accept(serverFd);
   if fd >= 0 {
       let task: ConnectionTask = ConnectionTask { fd: fd };
       Channel_Send<ConnectionTask>(&server.taskQueue, task);
   }
   ```
4. `Worker_Run` pops tasks and calls `HandleConnection(task.fd, server.handler)`.

Socket fd ownership is always with the worker that received the task; it is closed before the worker loops again.

---

## 10. Config (`Config.bux`)

```bux
pub struct ServerConfig {
    bindAddr: String;
    port: int;
    workerCount: int;
    publicDir: String;
    backlog: int;
}

const func DefaultConfig() -> ServerConfig {
    return ServerConfig {
        bindAddr: "0.0.0.0",
        port: 8080,
        workerCount: 4,
        publicDir: "public",
        backlog: 128,
    };
}
```

---

## 11. Testing & Verification

- `buxc check` must pass on the whole package.
- `buxc run` starts the server; verify with:
  - `curl http://localhost:8080/`
  - `curl http://localhost:8080/api/health`
  - `curl http://localhost:8080/api/info`
  - `curl -i -N -H "Upgrade: websocket" -H "Connection: Upgrade" http://localhost:8080/ws`
- Existing integration test surface (`buxc check` on `apps/nexus`) remains the gate.

---

## 12. Out of Scope

- Real HTTP/2 frame parsing or WebSocket frame parsing (keep detection/upgrade only, same as current).
- TLS/HTTPS.
- Full SHA-1/Base64 WebSocket accept key (keep placeholder).
- Generic `Result<T, E>` (Bux `Std::Result` is `Ok(int)` only; use domain enums instead).

---

## 13. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| `interface` vtables with generic structs | Avoid generic interfaces; use concrete `*HttpHandler` pointers. |
| `Channel<T>` with non-trivial `T` | `ConnectionTask` contains only `int`; safe to copy. |
| `?` operator on custom enums | Fall back to explicit `match` if needed. |
| `@[Checked]` borrow checker on raw `String` | Use `&String` for read-only parsing; avoid `&mut` unless mutation is required. |

---

## 14. Success Criteria

1. `buxc check apps/nexus` passes with zero errors.
2. `buxc run` in `apps/nexus` serves static files and API endpoints correctly.
3. The new code uses at minimum: modules, algebraic enums, pattern matching, interfaces, `extend`, generics, `for ... in`, `Channel<T>`, `spawn`, `Result`/`Option`, `@[Checked]`.
