# Running Linnix - Experimental Setup

This guide documents experimental setup and running Linnix in various environments.

## Architecture Support

**Important**: Linnix currently does not support ARM64 architecture and will fail to build with bpf-linker LLVM errors. ARM64 support is planned for release v0.2.0.

## Running on Ubuntu 22.04 EC2 (x86)

### eBPF Setup Issues

When running on EC2 instances, you may encounter eBPF compatibility issues:

- **Problem**: Pre-built binaries incompatible with kernel 6.8.0-aws
- **Solution**: Requires rebuilding from source for your specific kernel

### Degraded Mode

If the eBPF probe is not present, Linnix will run in userspace-only mode without kernel instrumentation, providing limited monitoring until eBPF is rebuilt.

### Temporary eBPF Fix

To temporarily relax restrictions (until next reboot) and allow eBPF to run:

```bash
sudo sysctl -w kernel.perf_event_paranoid=1
```

## Quick Start Setup

1. Build the cognitod dependency:
   ```bash
   docker build -t linnix-cognitod .
   ```

2. Run the quickstart script:
   ```bash
   ./quickstart.sh
   ```

## LLM Model Setup

If you encounter missing LLM model errors:

```bash
cd models
wget https://huggingface.co/parth21shah/linnix-3b-distilled/resolve/main/linnix-3b-distilled-q5_k_m.gguf
docker restart linnix-llm
```

## Web UI Configuration

### Public IP Exposure

When exposing the WebUI via public IP, you may need to fix hardcoded URLs pointing to `127.0.0.1`. 

**Fix**: See [this PR](https://github.com/mbertrone/linnix/pull/1) for the necessary changes.

### AI Insight Function

The AI Insight function in the UI may work intermittently. The docker compose network configuration fix in the PR above partially addresses this issue.

## Known Issues

- Health checks may show as unhealthy even when the system is functional
- AI Insight function reliability issues (partially fixed with network configuration)
- eBPF compatibility requires kernel-specific builds