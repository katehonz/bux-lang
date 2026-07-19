# Nexus

**High-performance, multi-threaded HTTP/1.1, HTTP/2 & WebSocket server — built with the [Bux](https://github.com/bux-lang/bux) programming language.**

Nexus is a from-scratch web server that demonstrates Bux's systems-programming capabilities: raw TCP sockets, pthread-based concurrency, manual memory management, and zero-dependency C ABI interop — all from a clean, modern syntax.

---

## Features

| Area | What's Implemented |
|------|-------------------|
| **HTTP/1.1** | Full request parsing (method, path, headers, body), response building with status codes, content negotiation |
| **Multi-threaded** | Configurable worker pool using the multi-accept pattern — each worker calls `accept()` directly on the shared listen socket |
| **HTTP/2** | Connection preface detection (`PRI * HTTP/2.0`), upgrade-aware routing |
| **WebSocket** | RFC 6455 upgrade handshake detection, `Sec-WebSocket-Key` extraction |
| **Static files** | Serves from `public/` with MIME-type detection for 20+ file types, directory-traversal protection |
| **JSON API** | Built-in `/api/health` and `/api/info` endpoints |
| **Logging** | Per-request structured logging (method, path, status code) |

## Quick Start

```bash
# From the project root
cd apps/nexus

# Build with the bootstrap compiler (Nim)
../../buxc build

# Or with the self-hosted compiler
../../buxc_lir build

# Run
./nexus

# Optional env (also used by `make bench-nexus`)
# NEXUS_PORT=18080 NEXUS_BIND=127.0.0.1 NEXUS_WORKERS=4 ./build/nexus
```

Server starts on `http://0.0.0.0:8080` (override with `NEXUS_PORT` / `NEXUS_BIND`):

```
╔══════════════════════════════════════════════╗
║  Nexus HTTP Server v0.1.0                    ║
║  High-performance multi-threaded HTTP/1.1    ║
║  HTTP/2 & WebSocket detection included       ║
║  Built with Bux                              ║
╚══════════════════════════════════════════════╝

✓ Server listening on http://0.0.0.0:8080
✓ Worker threads: 4
✓ Static files: ./public/

  Endpoints:
    GET  /              — Static files (public/)
    GET  /api/health    — Health check (JSON)
    GET  /api/info      — Server info (JSON)
    GET  /ws            — WebSocket upgrade
    ANY  /*             — Static file serving
```

## Testing It

```bash
# Home page (HTML)
curl http://localhost:8080/

# Health check
curl http://localhost:8080/api/health
# → {"status":"ok","server":"Nexus","version":"0.1.0"}

# Server info
curl http://localhost:8080/api/info
# → {"name":"Nexus","language":"Bux","features":[...]}

# Static file (404 page)
curl http://localhost:8080/404.html

# Nonexistent file
curl http://localhost:8080/nope
# → 404 Not Found

# WebSocket upgrade attempt
curl -H "Upgrade: websocket" \
     -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
     http://localhost:8080/ws
# → 101 Switching Protocols
```

## Architecture

### Thread Model — Multi-Accept

Nexus uses the **multi-accept** pattern rather than a traditional thread pool with a work queue:

```
Main Thread                  Worker 1       Worker 2       Worker 3
    │                           │              │              │
    ├─ socket()/bind()/listen() │              │              │
    ├─ spawn Worker() ──────────►              │              │
    ├─ spawn Worker() ─────────────────────────►              │
    ├─ spawn Worker() ────────────────────────────────────────►
    │                           │              │              │
    ▼ Worker()                  ▼ accept()     ▼ accept()     ▼ accept()
      accept() loop                │              │              │
```

Each worker thread calls `accept()` on the **same** listening socket. The Linux kernel distributes incoming connections across the blocked accept calls — the same mechanism used by nginx and Apache prefork. No mutex, no queue, no context switching between a dispatcher and workers.

### Request Lifecycle

```
Client connects
    │
    ▼
Net_Accept() → client fd
    │
    ▼
Net_Recv(fd, 8192) → raw bytes
    │
    ▼
ParseRequest()
    ├─ Split headers on \r\n\r\n
    ├─ Parse request line → method, path, version
    └─ Parse header lines → key-value array
    │
    ▼
Router_Dispatch()
    ├─ /api/*   → JSON handlers
    ├─ /ws      → WebSocket upgrade
    ├─ Upgrade header → HTTP/2 or WS detection
    └─ /*       → Static file serving
    │
    ▼
BuildResponse() → HTTP/1.1 status line + headers + body
    │
    ▼
Net_Send(fd, response) → bytes to client
    │
    ▼
Net_Close(fd)
```

### Design Decisions

- **No keep-alive by default.** Each connection is closed after one response. This avoids blocking worker threads on idle clients (Bux doesn't yet expose `SO_RCVTIMEO`).
- **Linear header array instead of hash map.** HTTP requests typically carry 5–15 headers. A linear scan over a key-value array is faster than hashing for this N, and avoids the complexity of iterating over Bux's generic `StringMap`.
- **Raw extern calls for the string builder.** The stdlib `StringBuilder` wrapper adds a struct indirection. Calling `bux_sb_new` / `bux_sb_append` / `bux_sb_build` directly is simpler and equally safe.
- **WebSocket accept key is a placeholder.** A full implementation needs SHA-1 hashing and Base64 encoding. These aren't in Bux's stdlib yet; they can be added as extern C functions when needed.

## Project Structure

```
apps/nexus/
├── bux.toml              # Package manifest
├── README.md             # This file
├── src/
│   └── Main.bux          # The entire server (~640 lines)
└── public/
    ├── index.html         # Landing page
    └── 404.html           # Error page
```

Everything lives in one file (`src/Main.bux`) by design — it keeps the module graph flat and the build fast. As the server grows, the HTTP parser, router, and handlers can be split into separate modules.

## Configuration

Edit the constants at the top of `src/Main.bux`:

```bux
const SERVER_PORT: int = 8080;      // Listen port
const THREAD_COUNT: int = 4;        // Number of worker threads
const RECV_BUF_SIZE: int = 8192;    // Receive buffer per request
const SERVER_NAME: String = "Nexus/0.1.0 (Bux)";
const PUBLIC_DIR: String = "public"; // Static files directory
```

## Roadmap

- [ ] Keep-alive with configurable socket timeout
- [ ] Full WebSocket frame read/write (requires SHA-1 + Base64)
- [ ] HTTP/2 binary framing layer (HPACK, stream multiplexing)
- [ ] SSL/TLS via OpenSSL extern bindings
- [ ] Middleware / filter chain
- [ ] Request body parsing (JSON, form-encoded, multipart)
- [ ] Virtual hosts
- [ ] Access logging to file
- [ ] Rate limiting

## License

Nexus is part of the Bux project. See the root [LICENSE](../../LICENSE) for terms.
