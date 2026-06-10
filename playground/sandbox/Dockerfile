# Bux Playground Sandbox
# Minimal container with Bux compiler + C toolchain
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    clang \
    libc6-dev \
    libssl-dev \
    make \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create sandbox user (no root)
RUN useradd -m -s /bin/bash sandbox

# Copy Bux compiler binary
COPY buxc2 /usr/local/bin/buxc2
RUN chmod +x /usr/local/bin/buxc2

# Copy stdlib and runtime
COPY lib /usr/local/share/bux/lib
COPY rt /usr/local/share/bux/rt

# Set up working directory
WORKDIR /tmp/bux-run
RUN chown sandbox:sandbox /tmp/bux-run

# Security: drop privileges, limit resources
USER sandbox

# Default command (backend will override)
CMD ["/bin/bash"]
