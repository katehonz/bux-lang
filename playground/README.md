# Bux Playground

Interactive web playground for the Bux programming language. Compile and run Bux code directly in your browser.

## Architecture

```
┌─────────────┐     POST /compile      ┌──────────────┐     docker run     ┌─────────────┐
│   Browser   │ ────────────────────► │ Go Backend   │ ────────────────► │   Sandbox   │
│  (Monaco)   │ ◄─── JSON output      │   (8080)     │                   │  (Docker)   │
└─────────────┘                       └──────────────┘                   └─────────────┘
```

## Quick Start

```bash
# 1. Build both images (from project root)
make -C playground all

# 2. Start the playground
make -C playground run

# 3. Open http://localhost:8080
```

## Development Mode

```bash
# Run backend locally without Docker sandbox
# (requires buxc2 in PATH)
cd playground/backend
go run main.go
```

Then open `playground/frontend/index.html` directly in browser.

## Deployment on VPS

### 1. Build and copy to VPS

```bash
# Local machine
make selfhost                    # Build buxc2
make -C playground all           # Build Docker images
docker save bux-playground-sandbox | gzip > sandbox.tar.gz
docker save bux-playground-backend | gzip > backend.tar.gz

# Copy to VPS
scp sandbox.tar.gz backend.tar.gz user@vps:/tmp/
```

### 2. On VPS

```bash
# Load images
docker load < /tmp/sandbox.tar.gz
docker load < /tmp/backend.tar.gz

# Run with docker-compose
cd /opt/bux-playground
docker-compose up -d
```

### 3. nginx reverse proxy + SSL

```nginx
server {
    listen 80;
    server_name play.bux-lang.org;
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name play.bux-lang.org;

    ssl_certificate /etc/letsencrypt/live/play.bux-lang.org/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/play.bux-lang.org/privkey.pem;

    location / {
        proxy_pass http://localhost:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
    }
}
```

### 4. systemd service

```ini
# /etc/systemd/system/bux-playground.service
[Unit]
Description=Bux Playground
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/bux-playground
ExecStart=/usr/bin/docker-compose up -d
ExecStop=/usr/bin/docker-compose down

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable bux-playground
sudo systemctl start bux-playground
```

## Security

- **Sandbox**: Each compile runs in a fresh Docker container with:
  - No network access (`--network=none`)
  - 128MB memory limit
  - 1 CPU core limit
  - 64 process limit
  - Read-only filesystem
  - `timeout 5s` for program execution
  - Temporary files auto-deleted

- **Code limits**:
  - Max code size: 64KB
  - Max output size: 64KB
  - Compile timeout: 10s
  - Run timeout: 5s

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8080` | HTTP server port |
| `USE_DOCKER` | `1` | Use Docker sandbox (0 = local mode) |
| `SANDBOX_IMAGE` | `bux-playground-sandbox` | Docker image name |
| `BUXC2_PATH` | `buxc2` | Path to buxc2 binary (local mode) |

## API

### POST /compile

Compile and run Bux code.

**Request:** `text/plain` — Bux source code

**Response:**
```json
{
  "output": "Hello, Bux!\n",
  "isError": false
}
```

### GET /health

Health check endpoint.

**Response:**
```json
{"status": "ok"}
```
