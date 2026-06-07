# Boko Framework

**Async web framework for Bux — inspired by FastAPI.**

Boko is a lightweight, multi-threaded web framework that brings FastAPI-style routing to the Bux programming language. It handles HTTP parsing, path pattern matching, query parameter extraction, and response building so you can focus on your application logic.

## Quick Start

```bash
cd apps/boko-framework
../../buxc build
./boko-framework
```

Open `http://localhost:8080` — you'll see the demo landing page.

## How It Works

Boko follows a **single-dispatch-function** pattern. You define one function — `Boko_Router` — and the framework calls it for every incoming request:

```bux
import Boko::{Request, Response, Response_Json, Response_Html, Response_NotFound,
              Path_Match, Request_GetQuery, Request_GetPathParam,
              App, App_New, App_Run};

func Boko_Router(req: Request) -> Response {
    // Route: GET /
    if String_Eq(req.path, "/") {
        return Response_Html("<h1>Hello Boko!</h1>");
    }

    // Route: GET /api/health
    if String_Eq(req.path, "/api/health") {
        return Response_Json("{\"status\":\"ok\"}");
    }

    // Route: GET /users/{id} — path parameter
    if Path_Match("/users/{id}", req.path, &req) {
        let id: String = Request_GetPathParam(&req, "id");
        // Build JSON response with id
        return Response_Json(...);
    }

    // Route: GET /search?q=... — query parameter
    if String_Eq(req.path, "/search") {
        let q: String = Request_GetQuery(&req, "q");
        return Response_Json(...);
    }

    return Response_NotFound();
}

func Main() -> int {
    let app: App = App_New(8080, 4);  // port, threads
    App_Run(&app);
    return 0;
}
```

## API Reference

### Request

| Field | Type | Description |
|-------|------|-------------|
| `method` | `HttpVerb` | GET, POST, PUT, DELETE |
| `path` | `String` | Request path (without query string) |
| `body` | `String` | Request body (for POST/PUT) |
| `headerCount` | `int` | Number of headers |

| Function | Returns | Description |
|----------|---------|-------------|
| `Request_GetHeader(req, name)` | `String` | Get header value by name |
| `Request_GetQuery(req, name)` | `String` | Get query parameter by name |
| `Request_GetPathParam(req, name)` | `String` | Get extracted path parameter |

### Response

| Constructor | Content-Type | Status |
|-------------|-------------|--------|
| `Response_Html(html)` | `text/html` | 200 |
| `Response_Json(json)` | `application/json` | 200 |
| `Response_Text(text)` | `text/plain` | 200 |
| `Response_Redirect(url)` | — | 302 |
| `Response_NotFound()` | `application/json` | 404 |
| `Response_Error(code, msg)` | `application/json` | custom |
| `Response_NoContent()` | — | 204 |

### Path Matching

`Path_Match(pattern, actualPath, req)` matches a pattern with `{param}` placeholders:

```bux
// Pattern:    /users/{id}/posts/{postId}
// Actual:     /users/42/posts/7
// Extracts:   id=42, postId=7

if Path_Match("/users/{id}/posts/{postId}", req.path, &req) {
    let userId: String = Request_GetPathParam(&req, "id");      // "42"
    let postId: String = Request_GetPathParam(&req, "postId");  // "7"
}
```

The function returns `true` if the pattern matches and populates `req.pathParamKeys` / `req.pathParamValues`.

### App

```bux
let app: App = App_New(8080, 4);  // port 8080, 4 worker threads
App_Run(&app);                     // blocks, handles requests
```

## Architecture

```
Incoming connection
    │
    ▼
Net_Accept()  ───  worker thread (1 of N)
    │
    ▼
Net_Recv()  →  raw HTTP bytes
    │
    ▼
Request_Parse()  →  method, path, query, headers, body
    │
    ▼
Boko_Router(req)  ←── YOUR CODE
    │
    ▼
Response_Build()  →  HTTP/1.1 response string
    │
    ▼
Net_Send()  →  bytes to client
    │
    ▼
Net_Close()
```

## Endpoints in Demo App

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Landing page (HTML) |
| GET | `/api/health` | Health check (JSON) |
| GET | `/api/info` | Framework info (JSON) |
| GET | `/hello?name=X` | Query param demo |
| GET | `/users/{id}` | Path param demo |
| GET | `/posts/{id}/comments/{cid}` | Multi path param demo |
| GET | `/redirect` | 302 redirect to `/` |
| POST | `/api/echo` | Echo request body |

## Project Structure

```
apps/boko-framework/
├── bux.toml              # Package manifest
├── README.md             # This file
└── src/
    ├── Boko.bux          # Framework core (~500 lines)
    └── Main.bux          # Example app (~150 lines)
```

## Design Philosophy

Boko is intentionally simple. Instead of complex DSLs or code generation, it gives you:

- **One function to write** — `Boko_Router(req) -> Response`
- **Direct control** — you write plain if/else or match for routing
- **No magic** — path params, query params, headers are explicit function calls
- **Fast** — multi-threaded accept loop, zero allocations where possible

This is the same philosophy as Go's `net/http` — simple, explicit, composable.

## License

Part of the Bux project. See root [LICENSE](../../LICENSE).
