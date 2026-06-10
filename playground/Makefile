# Bux Playground — Makefile
# Run from project root: make -C playground <target>

.PHONY: all build-sandbox build-backend run stop clean

SANDBOX_IMAGE = bux-playground-sandbox
BACKEND_IMAGE = bux-playground-backend
PORT = 8080

all: build-sandbox build-backend

# Build the sandbox Docker image (needs buxc2 + lib + rt)
build-sandbox:
	@echo "Building sandbox image..."
	@docker build \
		-f sandbox/Dockerfile \
		-t $(SANDBOX_IMAGE) \
		..

# Build the backend Go server
build-backend:
	@echo "Building backend image..."
	@docker build \
		-f backend/Dockerfile \
		-t $(BACKEND_IMAGE) \
		.

# Run everything with docker-compose
run:
	@echo "Starting Bux Playground on http://localhost:$(PORT)"
	@docker-compose up

# Run in background
run-detached:
	@echo "Starting Bux Playground in background on http://localhost:$(PORT)"
	@docker-compose up -d

# Stop
stop:
	@docker-compose down

# Clean images and containers
clean:
	@docker-compose down --rmi all -v
	@docker rmi $(SANDBOX_IMAGE) $(BACKEND_IMAGE) 2>/dev/null || true

# Development mode (local backend, no Docker sandbox)
dev:
	@echo "Starting backend in dev mode..."
	cd backend && go run main.go

# Quick test
test:
	@echo "Testing /health endpoint..."
	@curl -s http://localhost:$(PORT)/health | jq .
