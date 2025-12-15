# Building Cognitod

This guide covers building Cognitod Docker images from source, including custom tagging strategies for development and CI/CD workflows.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Build](#quick-build)
- [Building with Branch Tags](#building-with-branch-tags)
- [Understanding the Multi-Stage Build](#understanding-the-multi-stage-build)
- [Building from Source (Without Docker)](#building-from-source-without-docker)
- [Using Custom Images](#using-custom-images)
- [CI/CD Integration](#cicd-integration)
- [Troubleshooting](#troubleshooting)
- [Platform Notes](#platform-notes)

---

## Prerequisites

### System Requirements
- **Docker**: Version 20.10 or later with BuildKit support
- **Docker Compose**: Version 2.0 or later (optional, for testing)
- **Platform**: Linux x86_64 (recommended) or macOS with Docker Desktop
- **Memory**: At least 4GB RAM available for Docker
- **Disk Space**: ~10GB for build cache and layers

### For Source Builds (Without Docker)
- **Rust**: Version 1.90 or later
- **Rust Nightly**: 2024-12-10 (for eBPF)
- **LLVM/Clang**: Version 11 or later
- **bpf-linker**: Version 0.9.13
- **Linux Headers**: Matching your kernel version
- **libelf-dev**: For eBPF compilation

---

## Quick Build

Build the cognitod image with default settings:

```bash
docker build -t cognitod:latest .
```

This creates a production-ready image with:
- eBPF programs compiled for `bpfel-unknown-none` target
- Release-optimized cognitod binary
- Minimal Debian Bookworm runtime (~150MB compressed)

**Build time**: 15-30 minutes on first build (uses layer caching for subsequent builds)

---

## Building with Branch Tags

### Using Current Git Branch

Tag the image with your current branch name for development:

```bash
# Automatic branch detection
BRANCH=$(git branch --show-current)
docker build -t cognitod:${BRANCH} .

# Example output: cognitod:mbertrone/feat-capture-replay
```

### Using Full Registry Path

For pushing to container registries like GitHub Container Registry (GHCR):

```bash
BRANCH=$(git branch --show-current)
REGISTRY="ghcr.io/linnix-os"
docker build -t ${REGISTRY}/cognitod:${BRANCH} .

# Example: ghcr.io/linnix-os/cognitod:mbertrone/feat-capture-replay
```

### Multiple Tags

Tag with both branch name and commit SHA for traceability:

```bash
BRANCH=$(git branch --show-current)
COMMIT=$(git rev-parse --short HEAD)

docker build \
  -t cognitod:${BRANCH} \
  -t cognitod:${COMMIT} \
  -t cognitod:latest \
  .
```

### Build Arguments

Pass version metadata into the build:

```bash
docker build \
  --build-arg VERSION=${BRANCH} \
  --build-arg COMMIT=$(git rev-parse HEAD) \
  --build-arg BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
  -t cognitod:${BRANCH} \
  .
```

---

## Understanding the Multi-Stage Build

The `Dockerfile` uses a 3-stage build process for optimal image size and security.

### Stage 1: eBPF Builder (`ebpf-builder`)

**Purpose**: Compile eBPF programs that run in the Linux kernel.

```dockerfile
FROM rust:1.90-bookworm AS ebpf-builder
```

**Key Steps**:
1. Installs LLVM, Clang, and kernel headers
2. Sets up Rust nightly toolchain (2024-12-10)
3. Installs `bpf-linker` for linking eBPF object files
4. Compiles eBPF programs to `bpfel-unknown-none` target

**Output**: `/build/target/bpfel-unknown-none/release/linnix-ai-ebpf-ebpf`

### Stage 2: Rust Builder (`rust-builder`)

**Purpose**: Compile the cognitod userspace daemon.

```dockerfile
FROM rust:1.90-bookworm AS rust-builder
```

**Key Steps**:
1. Copies Cargo dependency manifests for caching
2. Builds cognitod in release mode with optimizations
3. Produces a static binary with minimal dependencies

**Output**: `/build/target/release/cognitod`

### Stage 3: Runtime Image

**Purpose**: Minimal production runtime with only required dependencies.

```dockerfile
FROM debian:bookworm-slim
```

**Key Features**:
- **Base**: Debian Bookworm Slim (~80MB)
- **Runtime Dependencies**: ca-certificates, curl, libssl3
- **Security**: Non-root user `linnix`, read-only filesystem, minimal capabilities
- **Size**: ~150MB compressed (vs ~2GB if built in single stage)

**Installed**:
- `/usr/local/bin/cognitod` - Main daemon binary
- `/usr/local/share/linnix/linnix-ai-ebpf-ebpf` - eBPF programs
- `/etc/linnix/linnix.toml.example` - Default configuration
- `/etc/linnix/rules.yaml` - Detection rules

---

## Building from Source (Without Docker)

For development or platforms without Docker support.

### Step 1: Install Dependencies

**Ubuntu/Debian**:
```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential \
  llvm \
  clang \
  libelf-dev \
  linux-headers-$(uname -r) \
  pkg-config \
  curl
```

**macOS** (limited support):
```bash
brew install llvm
# Note: eBPF won't function on macOS kernel
```

### Step 2: Install Rust Toolchains

```bash
# Install Rust stable
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Install nightly for eBPF
rustup install nightly-2024-12-10
rustup component add rust-src --toolchain nightly-2024-12-10

# Install bpf-linker
cargo install bpf-linker --version 0.9.13 --locked
```

### Step 3: Build eBPF Programs

```bash
cd linnix-ai-ebpf/linnix-ai-ebpf-ebpf
cargo build --release --target=bpfel-unknown-none
cd ../..
```

### Step 4: Build Cognitod

```bash
cargo build --release -p cognitod
```

**Output**: `./target/release/cognitod`

### Step 5: Run Locally

```bash
# Set eBPF path
export LINNIX_BPF_PATH=./target/bpfel-unknown-none/release/linnix-ai-ebpf-ebpf

# Run with sudo (requires CAP_BPF + CAP_PERFMON)
sudo -E ./target/release/cognitod \
  --config configs/linnix.toml \
  --handler rules:configs/rules.yaml
```

---

## Using Custom Images

### With Docker Compose

Override the default image in `docker-compose.yml`:

```bash
# Set environment variable
export COGNITOD_IMAGE=cognitod:mbertrone/feat-capture-replay

# Start services
docker compose up -d
```

Or inline:

```bash
COGNITOD_IMAGE=cognitod:my-branch docker compose up -d
```

### With Kubernetes

Update your DaemonSet manifest:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: linnix-agent
spec:
  template:
    spec:
      containers:
      - name: cognitod
        image: ghcr.io/linnix-os/cognitod:mbertrone/feat-capture-replay
        # ... rest of spec
```

Or use `kubectl set image`:

```bash
kubectl set image daemonset/linnix-agent \
  cognitod=ghcr.io/linnix-os/cognitod:my-branch
```

---

## CI/CD Integration

### GitHub Actions (Included)

The project includes `.github/workflows/docker.yml` which automatically:

**On Push to Main**:
- Builds and pushes `ghcr.io/linnix-os/cognitod:main`
- Tags as `latest`

**On Pull Request**:
- Builds and pushes `ghcr.io/linnix-os/cognitod:pr-123`

**On Git Tag** (e.g., `v1.2.3`):
- Builds and pushes semantic versions:
  - `ghcr.io/linnix-os/cognitod:1.2.3`
  - `ghcr.io/linnix-os/cognitod:1.2`
  - `ghcr.io/linnix-os/cognitod:1`

**On Any Branch**:
- Builds and pushes `ghcr.io/linnix-os/cognitod:<branch-name>`
- Also tags with commit SHA

### Custom CI/CD

Example GitLab CI pipeline:

```yaml
build:
  stage: build
  image: docker:latest
  services:
    - docker:dind
  script:
    - docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $CI_REGISTRY
    - docker build -t $CI_REGISTRY_IMAGE:$CI_COMMIT_REF_SLUG .
    - docker push $CI_REGISTRY_IMAGE:$CI_COMMIT_REF_SLUG
```

### BuildKit Features

Enable advanced caching:

```bash
# Use GitHub Actions cache
docker buildx create --use
docker buildx build \
  --cache-from type=gha \
  --cache-to type=gha,mode=max \
  -t cognitod:latest \
  --load \
  .
```

---

## Troubleshooting

### Build Fails: "bpf-linker not found"

**Symptom**:
```
error: linker `bpf-linker` not found
```

**Solution**:
```bash
cargo install bpf-linker --version 0.9.13 --locked
```

### Build Fails: "LLVM not found"

**Symptom**:
```
could not find native static library `LLVM`
```

**Solution** (Ubuntu/Debian):
```bash
sudo apt-get install llvm clang libclang-dev
```

### Out of Memory During Build

**Symptom**: Docker build crashes or hangs

**Solution**:
```bash
# Increase Docker memory limit
# Docker Desktop: Settings -> Resources -> Memory (set to 4GB+)

# Or build with limited parallelism
docker build --build-arg CARGO_BUILD_JOBS=2 -t cognitod:latest .
```

### eBPF Programs Won't Load

**Symptom**:
```
Error: Failed to load eBPF program: Permission denied
```

**Solution**:
```bash
# Ensure kernel supports BPF
uname -r  # Must be 5.4+

# Check capabilities
docker run --rm --cap-add BPF --cap-add PERFMON cognitod:latest

# Or run privileged (development only)
docker run --privileged cognitod:latest
```

### ARM64 Build Issues

**Known Issue**: `bpf-linker` has LLVM compatibility issues in QEMU emulation.

**Status**: ARM64 support tracked in upstream issue: https://github.com/aya-rs/bpf-linker/issues

**Workaround**: Build on x86_64 and use Docker's multi-arch manifest:
```bash
# Build on x86_64 CI runner
docker buildx build --platform linux/amd64 -t cognitod:latest .
```

---

## Platform Notes

### Linux (x86_64) - Recommended

- **Full eBPF support**: Monitors all host processes
- **Kernel Requirements**: 5.4+ (5.8+ for unprivileged BPF)
- **Performance**: Optimal (<1% overhead)

### macOS - Limited Support

- **eBPF Scope**: Only monitors Docker VM processes (via bridge network)
- **Limitations**: Cannot monitor macOS native processes
- **Build**: Requires Docker Desktop with Linux VM

### ARM64 / Apple Silicon

- **Status**: Experimental via Rosetta 2 emulation
- **Performance**: Slower builds (~2x longer)
- **Recommendation**: Build on x86_64 CI, pull pre-built images

### Windows - Not Supported

eBPF requires Linux kernel. Use WSL2 with Docker Desktop instead:

```powershell
# WSL2 + Docker Desktop
wsl --install
# Then follow Linux build instructions inside WSL2
```

---

## Quick Reference

```bash
# Basic build
docker build -t cognitod:latest .

# Build with branch tag
docker build -t cognitod:$(git branch --show-current) .

# Build and push to registry
REGISTRY=ghcr.io/linnix-os
BRANCH=$(git branch --show-current)
docker build -t ${REGISTRY}/cognitod:${BRANCH} .
docker push ${REGISTRY}/cognitod:${BRANCH}

# Use custom image with Docker Compose
COGNITOD_IMAGE=cognitod:my-branch docker compose up -d

# Build from source
cargo build --release -p cognitod
sudo -E ./target/release/cognitod --config configs/linnix.toml

# Check image size
docker images cognitod:latest

# Inspect build layers
docker history cognitod:latest
```

---

## Additional Resources

- [Getting Started Guide](wiki/Getting-Started.md)
- [Configuration Guide](wiki/Configuration-Guide.md)
- [Dockerfile](../Dockerfile)
- [GitHub Actions Workflow](../.github/workflows/docker.yml)
- [Docker Compose Configuration](../docker-compose.yml)
- [Security Model](../SECURITY.md)

---

## Questions or Issues?

- **Build Issues**: Open an issue at https://github.com/linnix-os/linnix/issues
- **Security Concerns**: See [SECURITY.md](../SECURITY.md)
- **Contributing**: See [CONTRIBUTING.md](../CONTRIBUTING.md)
