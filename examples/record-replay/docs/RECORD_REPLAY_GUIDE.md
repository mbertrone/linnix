# Record/Replay Implementation Guide

This document provides a comprehensive guide to the record/replay functionality in Linnix cognitod, including architectural background, implementation details, and usage instructions.

## Table of Contents
- [Overview](#overview)
- [Background & Architecture](#background--architecture)
- [Phase 1 Implementation](#phase-1-implementation)
- [Quick Start Guide](#quick-start-guide)
- [Capabilities & Limitations](#capabilities--limitations)
- [Use Cases](#use-cases)
- [Future Phases](#future-phases)

---

## Overview

### What is Record/Replay?

Record/replay functionality allows you to:
- **Record** live eBPF process events to an NDJSON file
- **Replay** those events later for testing, debugging, or analysis
- Test detection rules and handlers without needing live workloads
- Share reproducible test cases with your team

### Current Status: Phase 1 Complete ✅

**Phase 1** implements basic recording of eBPF process events:
- ✅ Record ProcessEvent structs from ring buffer to NDJSON file
- ✅ Support process lifecycle analysis (fork/exec/exit events)
- ✅ Enable fork storm and process tree detection replay
- ✅ Replay speed control for faster testing

**Scope:**
- Process lifecycle events (fork/exec/exit)
- Fork storm detection
- Process tree analysis
- Command execution patterns

**Excluded from Phase 1:**
- System monitoring data (CPU, memory, PSI metrics)
- Circuit breaker incidents
- Resource-based detection

---

## Background & Architecture

### Why Hybrid Recording is Needed

Cognitod's architecture relies on two distinct data sources:

```
┌─────────────┐   eBPF Events    ┌──────────────┐   Mixed Data    ┌─────────────┐
│   Kernel    │ ──────────────▶  │   cognitod   │ ──────────────▶ │  Analysis   │
│ Ring Buffer │   Process        │  (main.rs)   │  Incidents     │ & Actions   │
└─────────────┘   Lifecycle      └──────────────┘                └─────────────┘
                                         ▲
                                         │
                                 ┌───────────────┐
                                 │ System        │
                                 │ Monitoring    │
                                 │ (/proc, etc.) │
                                 └───────────────┘
```

### Data Sources Analysis

#### 1. Ring Buffer Events (✅ Recorded in Phase 1)

**Source:** `linnix-ai-ebpf-common/src/lib.rs:14-40`

```rust
pub struct ProcessEvent {
    pub pid: u32,
    pub ppid: u32,
    pub uid: u32,
    pub gid: u32,
    pub event_type: u32,  // Fork=1, Exec=0, Exit=2
    pub ts_ns: u64,
    pub comm: [u8; 16],
    pub cpu_pct_milli: u16,
    pub mem_pct_milli: u16,
    // ... additional fields
}
```

**Capabilities:**
- ✅ Full serde serialization/deserialization
- ✅ Process lifecycle tracking
- ✅ Parent-child relationships
- ✅ Basic CPU/memory percentages (if BTF available)

#### 2. System Monitoring Data (❌ Not in Phase 1)

**Source:** `cognitod/src/context.rs:258-317`

**CPU/Memory System Stats:**
```rust
// sysinfo library reading /proc/stat, /proc/meminfo
sys.refresh_cpu_all();
sys.refresh_memory();
let cpu_percent = sys.global_cpu_usage();
let mem_percent = (sys.used_memory() as f32 / sys.total_memory() as f32) * 100.0;
```

**PSI (Pressure Stall Information):**
```rust
// cognitod/src/utils/psi.rs:48-86 reading /proc/pressure/*
let psi = PsiMetrics::read().unwrap_or_default();
// psi.cpu_some_avg10, psi.memory_full_avg10, etc.
```

**Per-Process Stats:**
```rust
// sysinfo reading /proc/*/stat and /proc/*/status
for event in live.values_mut() {
    if let Some(proc) = sys.process(Pid::from_u32(event.pid)) {
        event.set_cpu_percent(Some(proc.cpu_usage()));
        event.set_mem_percent(/* calculated from proc.memory() */);
    }
}
```

### Incident Types & Data Dependencies

#### Process Lifecycle Based (✅ Phase 1 Supports)
- **Fork Storm** (`ForksPerSec`, `ForkBurst`) - High rate of process creation
- **Process Tree Explosion** (`RunawayTree`) - Single parent spawning many children
- **Command Execution** (`ExecRate`) - Command execution patterns

#### Resource Consumption Based (❌ Requires Phase 2)
- **Circuit Breaker Incidents** - Needs system-wide CPU/memory/PSI data
- **CPU Pressure** (`SubtreeCpuPct`) - Uses sysinfo per-process stats
- **Memory Pressure** (`SubtreeRssMb`) - Uses sysinfo per-process stats
- **PSI Attribution** - Requires `/proc/pressure/*` files

### Implementation Strategy Rationale

**Phase 1 Approach:**
Recording only eBPF ring buffer events provides:
- ✅ Simple implementation
- ✅ Minimal storage overhead (~250 bytes/event)
- ✅ Support for process-based detection
- ✅ Immediate value for testing fork storm and process tree rules

**Phase 2 Will Add:**
System snapshot recording to enable circuit breaker and resource-based detection:

```rust
#[derive(Serialize, Deserialize)]
enum RecordedEvent {
    ProcessEvent {
        timestamp: u64,
        event: ProcessEvent,
    },
    SystemSnapshot {
        timestamp: u64,
        snapshot: SystemSnapshot,
    },
}
```

---

## Phase 1 Implementation

### Architecture

**Recording Flow:**
1. eBPF events arrive in ring buffer
2. `RecordingHandler` intercepts events via Handler trait
3. Events serialized to NDJSON with timestamp
4. Written to file with periodic flushing

**Replay Flow:**
1. `replay_listener` reads NDJSON file line-by-line
2. Calculates delays based on timestamps and replay speed
3. Injects events into handler pipeline
4. All registered handlers process events normally

### File Structure

**cognitod/src/handler/recording.rs** - Recording handler implementation
**cognitod/src/runtime/replay_listener.rs** - Replay event source
**cognitod/src/main.rs** - CLI integration and mode selection

### CLI Interface

```rust
#[derive(Parser, Debug)]
struct Args {
    /// Record eBPF events to file
    #[arg(long, value_name = "FILE")]
    record: Option<PathBuf>,

    /// Replay eBPF events from file
    #[arg(long, value_name = "FILE")]
    replay: Option<PathBuf>,

    /// Replay speed multiplier (default: 1.0 = real-time)
    #[arg(long, default_value = "1.0")]
    replay_speed: f32,
}
```

**Validation:**
- `--record` and `--replay` are mutually exclusive
- File paths validated and parent directories created automatically
- eBPF initialization skipped in replay mode

### File Format Specification

#### NDJSON Structure

Each line contains one JSON object:
```json
{"timestamp":1764844721000000000,"event":{"pid":12345,"ppid":1234,"uid":1000,"gid":1000,"event_type":1,"ts_ns":1764844721000000000,"comm":[99,111,109,109,97,110,100,0,0,0,0,0,0,0,0,0],"exit_time_ns":0,"cpu_pct_milli":65535,"mem_pct_milli":65535,"data":0,"data2":0,"aux":0,"aux2":0}}
```

**Field Descriptions:**

| Field | Description |
|-------|-------------|
| `timestamp` | Recording timestamp (nanoseconds since Unix epoch) |
| `pid` | Process ID |
| `ppid` | Parent process ID |
| `uid` | User ID |
| `gid` | Group ID |
| `event_type` | Event type: 0=Exec, 1=Fork, 2=Exit |
| `ts_ns` | eBPF kernel timestamp (nanoseconds since boot) |
| `comm` | Command name as byte array (16 bytes, null-terminated) |
| `cpu_pct_milli` | CPU usage in milli-percent (65535 = unknown) |
| `mem_pct_milli` | Memory usage in milli-percent (65535 = unknown) |

#### Size Estimates

- **ProcessEvent:** ~200 bytes per event
- **JSON overhead:** ~50 bytes per event
- **Total:** ~250 bytes per event
- **Storage rate:** 1000 events/sec = 250KB/sec = ~21GB/day (high activity)
- **Typical SSH session:** ~50-100 KB (200-400 events)

---

## Quick Start Guide

### Prerequisites

Before running cognitod with record/replay, build both the userspace binary and eBPF programs:

```bash
# 1. Build userspace binary
cargo build --release

# 2. Install eBPF build dependencies (one-time setup)
rustup component add rust-src --toolchain nightly-2024-12-10-x86_64-unknown-linux-gnu
cargo install bpf-linker

# 3. Build eBPF programs
cargo xtask build-ebpf --release

# 4. Verify eBPF binaries exist
ls -lh target/bpfel-unknown-none/release/linnix-ai-ebpf-ebpf
```

### Basic Recording

```bash
# Start recording (runs in foreground, Ctrl+C to stop)
sudo ./target/release/cognitod --record /tmp/events.ndjson
```

In another terminal, generate some activity:
```bash
ls -la
ps aux
echo "test"
# ... any commands you want to capture
```

Press Ctrl+C to stop recording, then inspect the output:
```bash
# View first few events (requires jq)
head -5 /tmp/events.ndjson | jq .

# Count total events recorded
wc -l /tmp/events.ndjson

# Check file size
ls -lh /tmp/events.ndjson
```

### Basic Replay

```bash
# Replay at normal speed (respects original timing)
sudo ./target/release/cognitod --replay /tmp/events.ndjson

# Replay at 10x speed (faster testing)
sudo ./target/release/cognitod --replay /tmp/events.ndjson --replay-speed 10.0

# Replay at 0.5x speed (slower than real-time)
sudo ./target/release/cognitod --replay /tmp/events.ndjson --replay-speed 0.5
```

### Testing with Rules

Rules configured via `--handler` will trigger during replay:

```bash
# Record while running a workload
sudo ./target/release/cognitod --record /tmp/workload.ndjson &
RECORD_PID=$!

# Run your workload
./my-test-workload.sh

# Stop recording
sudo kill $RECORD_PID

# Replay with rules engine active
sudo ./target/release/cognitod --replay /tmp/workload.ndjson \
  --handler rules:configs/rules.yaml
```

### Analyzing Recordings

**Count events by type:**
```bash
jq '.event.base.event_type' sample-events.ndjson | sort | uniq -c
```

**Extract unique commands:**
```bash
jq -r '.event.base.comm | @json' sample-events.ndjson | \
  python3 -c "import sys, json; [print(bytes(json.loads(line)).decode('utf-8', errors='ignore').rstrip('\x00')) for line in sys.stdin]" | \
  sort | uniq
```

**Find events for specific PID:**
```bash
jq 'select(.event.base.pid == 370104)' sample-events.ndjson
```

### Troubleshooting

**Error: "BPF object not found"**
- Run: `cargo xtask build-ebpf --release`
- Verify: `ls target/bpfel-unknown-none/release/linnix-ai-ebpf-ebpf`

**Error: "Cannot use --record and --replay simultaneously"**
- These flags are mutually exclusive - use one or the other

**Error: "linker `bpf-linker` not found"**
- Run: `cargo install bpf-linker`

**No events recorded:**
- Ensure cognitod has CAP_BPF and CAP_PERFMON capabilities
- Check that the eBPF programs are loaded (no errors at startup)
- Try generating some activity in another terminal

**Replay timing seems off:**
- The replay speed is based on the **time between events**, not wall clock time
- Use `--replay-speed` to adjust (higher = faster, lower = slower)

**Git authentication errors during eBPF build:**
```bash
git config --global url."https://github.com/".insteadOf git@github.com:
mkdir -p ~/.cargo && echo -e "[net]\ngit-fetch-with-cli = true" >> ~/.cargo/config.toml
```

---

## Capabilities & Limitations

### What Works in Phase 1 ✅

**Process Lifecycle Analysis:**
- ✅ Process lifecycle events (fork/exec/exit)
- ✅ Parent-child relationships
- ✅ Process tree reconstruction
- ✅ Command execution tracking

**Detection Capabilities:**
- ✅ Fork storm detection (`ForksPerSec`, `ForkBurst`)
- ✅ Process tree explosion (`RunawayTree`)
- ✅ Command execution patterns (`ExecRate`)
- ✅ Short-lived job floods (`ShortJobFlood`)
- ✅ Process tree anomalies

**Testing & Analysis:**
- ✅ Replay at any speed (1x, 10x, 0.1x)
- ✅ Rules engine fires during replay
- ✅ Human-readable NDJSON format
- ✅ Easy filtering and analysis with jq

### What Doesn't Work Yet ❌

**Requires Phase 2 (System Snapshot Recording):**
- ❌ Circuit breaker incidents
- ❌ CPU threshold detection (system-wide)
- ❌ Memory threshold detection (system-wide)
- ❌ PSI-based analysis (`/proc/pressure/*`)
- ❌ Real-time resource consumption alerts
- ❌ Per-process CPU/memory from sysinfo
- ❌ Network and disk statistics

**Why These Don't Work:**
These detections rely on system-wide monitoring data that exists outside the eBPF ring buffer:
- CPU/memory usage from `/proc/stat` and `/proc/meminfo`
- PSI metrics from `/proc/pressure/*`
- Per-process stats from `/proc/*/stat`

### Workarounds for Phase 1

- Focus on process-based detection rules
- Use fork storm and process tree rules for testing
- Create test scenarios that trigger process lifecycle anomalies
- Combine replay with live system monitoring for hybrid testing

### Success Criteria (Phase 1 Complete ✅)

**Functional Requirements:**
- ✅ Record eBPF events with `--record filename.ndjson`
- ✅ Replay eBPF events with `--replay filename.ndjson`
- ✅ Support replay speed control with `--replay-speed N.N`
- ✅ Maintain normal event processing during recording
- ✅ Process replayed events through existing handler pipeline

**Quality Requirements:**
- ✅ Graceful error handling for file I/O issues
- ✅ Progress logging during replay
- ✅ Minimal performance impact during recording (<1% CPU overhead)
- ✅ Proper cleanup on shutdown

**Validation Requirements:**
- ✅ Fork storm detection works on replayed events
- ✅ Process tree analysis works on replayed events
- ✅ Rules engine fires same alerts during replay
- ✅ File format is human-readable and parseable

---

## Use Cases

### Development & Testing

**1. Regression Testing**
```bash
# Capture a production incident
sudo cognitod --record /data/incidents/fork-storm-2025-01-15.ndjson

# Test new rule changes against the incident
sudo cognitod --replay /data/incidents/fork-storm-2025-01-15.ndjson \
  --handler rules:configs/new-rules.yaml \
  --replay-speed 10.0
```

**2. Rule Development**
```bash
# Record normal workload baseline
sudo cognitod --record /data/baselines/web-server-normal.ndjson

# Test detection rules to verify no false positives
sudo cognitod --replay /data/baselines/web-server-normal.ndjson \
  --handler rules:configs/experimental-rules.yaml
```

**3. Performance Analysis**
```bash
# Record high-activity period
sudo cognitod --record /data/analysis/peak-load.ndjson

# Analyze offline without impacting production
jq '.event.base' /data/analysis/peak-load.ndjson | \
  analyze-fork-patterns.py
```

### Production Support

**1. Incident Reproduction**
```bash
# Replay exact conditions that triggered alerts
sudo cognitod --replay /var/log/linnix/incident-2025-01-15.ndjson \
  --replay-speed 1.0  # Real-time replay
```

**2. False Positive Analysis**
```bash
# Debug why alerts fired incorrectly
sudo cognitod --replay /data/false-positives/alert-123.ndjson \
  --handler rules:configs/rules-debug.yaml
```

**3. Threshold Tuning**
```bash
# Test different thresholds against real workloads
for threshold in 10 20 50 100; do
  echo "Testing threshold: $threshold"
  sed "s/threshold: .*/threshold: $threshold/" rules.yaml > test-rules.yaml
  sudo cognitod --replay workload.ndjson --handler rules:test-rules.yaml
done
```

### Security Analysis

**1. Attack Pattern Analysis**
```bash
# Record and analyze malicious behavior
sudo cognitod --record /security/incidents/attack-2025-01-15.ndjson

# Offline analysis for attack patterns
jq 'select(.event.base.event_type == 1)' /security/incidents/attack-2025-01-15.ndjson | \
  grep -i suspicious
```

**2. Baseline Creation**
```bash
# Establish normal behavior patterns
sudo cognitod --record /baselines/app-server-normal-7days.ndjson

# Compare against suspicious activity
diff <(jq -c '.event.base' baseline.ndjson | sort) \
     <(jq -c '.event.base' suspicious.ndjson | sort)
```

---

## Future Phases

### Phase 2: System Snapshot Recording

**Goal:** Enable circuit breaker and resource-based detection replay

**Implementation:**
```rust
#[derive(Serialize, Deserialize)]
enum RecordedEvent {
    ProcessEvent {
        timestamp: u64,
        event: ProcessEvent,
    },
    SystemSnapshot {
        timestamp: u64,
        cpu_percent: f32,
        mem_percent: f32,
        psi_cpu_some_avg10: f32,
        psi_memory_full_avg10: f32,
        load_avg: [f32; 3],
        // ... additional system-wide metrics
    },
}
```

**Enables:**
- ✅ Circuit breaker incident replay
- ✅ CPU/memory threshold detection
- ✅ PSI-based analysis
- ✅ Resource consumption alerts

**Storage Impact:**
- SystemSnapshot: ~150 bytes
- Frequency: Every 5 seconds (0.2/sec)
- Additional storage: ~30 KB/sec = ~2.5 GB/day

### Phase 3: File Rotation and Compression

**Features:**
- Automatic file rotation by size or time
- GZIP compression for archived recordings
- Retention policies

**Example:**
```
events-20250101-120000.ndjson.gz
events-20250101-130000.ndjson.gz
```

### Phase 4: Filtering and Analysis Tools

**Features:**
- CLI tools for analyzing recordings
- Filter by event type, PID, UID, time range
- Summary statistics and reports
- Export to various formats

### Phase 5: Distributed Recording

**Features:**
- Record across multiple hosts simultaneously
- Synchronized timestamps
- Distributed replay
- Cluster-wide incident analysis

---

## Security Considerations

### Data Sensitivity

Recorded files contain:
- Process names, PIDs, UIDs, GIDs
- Command names (16-byte truncated)
- Parent-child relationships
- Timing information

**Recommendations:**
- Encrypt recordings at rest
- Limit access to recording files
- Implement retention policies
- Sanitize recordings before sharing

### Storage Security

```bash
# Secure recording directory
sudo mkdir -p /var/log/linnix/recordings
sudo chmod 700 /var/log/linnix/recordings
sudo chown root:root /var/log/linnix/recordings

# Record to secure location
sudo cognitod --record /var/log/linnix/recordings/session.ndjson
```

### Access Control

- Require root/CAP_SYS_ADMIN for recording
- Audit access to recorded files
- Log all replay operations
- Implement role-based access for recordings

---

## Implementation Timeline

**Phase 1 Actual Duration:** ~10 hours development + 3 hours testing

**Breakdown:**
- CLI interface: 1.5 hours
- Recording handler: 2.5 hours
- Replay listener: 3.5 hours
- Integration: 1 hour
- Testing: 1.5 hours
- Documentation: 3 hours

**Dependencies Met:**
- ✅ ProcessEvent serialization (serde support)
- ✅ Handler and context infrastructure
- ✅ Async I/O with Tokio

**Risk Mitigation Applied:**
- ✅ Started with simple file I/O
- ✅ Tested with small datasets first
- ✅ Implemented error handling from the beginning
- ✅ Created comprehensive test scenarios

---

## Contributing

To add new examples:
1. Record interesting workloads or scenarios
2. Compress large files: `gzip sample-events.ndjson`
3. Document what the recording contains
4. Submit a PR with the recording and updated README

## See Also

- [Testing Guide](../README.md) - User-facing documentation
- [Fork Storm Testing](../TESTING_FORK_STORM_DETECTION.md) - Comprehensive testing guide
- [Replay Capabilities Analysis](REPLAY_CAPABILITIES.md) - Detailed capability matrix
- [Build Instructions](../../../README.md) - Repository build guide
