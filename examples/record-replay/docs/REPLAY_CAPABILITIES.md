# Record/Replay Capabilities Analysis

This document analyzes what types of incidents and detections can be simulated using the record/replay functionality in Phase 1, which captures only eBPF ProcessEvent data from the ring buffer.

## Overview

The Phase 1 implementation records **process lifecycle events** (fork/exec/exit) with basic metadata. This enables behavioral anomaly detection but does not capture system-wide resource metrics needed for resource exhaustion incidents.

## What Gets Recorded

Each ProcessEvent in the NDJSON recording contains:

```json
{
  "timestamp": 1764861931088485903,
  "event": {
    "base": {
      "pid": 370030,
      "ppid": 370023,
      "uid": 0,
      "gid": 0,
      "event_type": 2,
      "ts_ns": 101679013688836,
      "seq": 0,
      "comm": [116,111,107,105,111,45,114,117,110,116,105,109,101,45,119,0],
      "exit_time_ns": 101679013688836,
      "cpu_pct_milli": 65535,
      "mem_pct_milli": 65535,
      "data": 0,
      "data2": 0,
      "aux": 0,
      "aux2": 0
    }
  }
}
```

### Field Descriptions

| Field | Description | Replay Utility |
|-------|-------------|----------------|
| `timestamp` | Recording wall-clock time (nanoseconds since Unix epoch) | ✅ Used for replay timing |
| `pid` | Process ID | ✅ Process identification |
| `ppid` | Parent process ID | ✅ Process tree analysis |
| `uid` | User ID | ✅ Privilege detection |
| `gid` | Group ID | ✅ Privilege detection |
| `event_type` | 0=Exec, 1=Fork, 2=Exit | ✅ Lifecycle tracking |
| `ts_ns` | eBPF kernel timestamp (nanoseconds since boot) | ✅ Original timing |
| `comm` | Command name (16 bytes, null-terminated) | ✅ Command pattern detection |
| `exit_time_ns` | Process exit timestamp | ✅ Lifetime calculation |
| `cpu_pct_milli` | CPU usage in milli-percent | ❌ Always 65535 (unknown) |
| `mem_pct_milli` | Memory usage in milli-percent | ❌ Always 65535 (unknown) |

**Note**: `PERCENT_MILLI_UNKNOWN = 65535` indicates unavailable data. The `cpu_percent()` and `mem_percent()` methods return `None` when these fields are 65535.

## ✅ Supported Incident Types

These incidents can be fully simulated and detected during replay:

### 1. Fork Storm Detection

**Rule Detectors**: `ForksPerSec`, `ForkBurst`

**What it detects**:
- Rapid process creation (fork bombs)
- Sustained high fork rates
- Sudden bursts of fork activity

**Example configuration** (`configs/rules.yaml`):
```yaml
- name: fork_storm
  detector:
    forks_per_sec:
      threshold: 50
      duration: 10
```

**Test scenario**:
```bash
# Generate fork storm
(for i in {1..100}; do sleep 0.1 & done) &
STORM_PID=$!

# Record it
sudo ./target/release/cognitod --record /tmp/fork-storm.ndjson &
RECORD_PID=$!
sleep 10
sudo kill $RECORD_PID $STORM_PID

# Replay and verify detection
sudo ./target/release/cognitod --replay /tmp/fork-storm.ndjson \
  --replay-speed 5.0 \
  --handler rules:configs/rules.yaml
```

**Data used**:
- `event_type == 1` (Fork events)
- `timestamp` for rate calculation
- `ppid` for tracking parent processes

---

### 2. Runaway Process Tree

**Rule Detector**: `RunawayTree`

**What it detects**:
- Single parent process spawning excessive children
- Recursive fork patterns
- Process tree explosions

**Example configuration**:
```yaml
- name: runaway_parent
  detector:
    runaway_tree:
      threshold: 20
      window_seconds: 10
```

**Test scenario**:
```bash
# Create runaway script
cat > /tmp/runaway.sh << 'EOF'
#!/bin/bash
for i in {1..30}; do
  sleep 1 &
done
wait
EOF
chmod +x /tmp/runaway.sh

# Record
sudo ./target/release/cognitod --record /tmp/runaway.ndjson &
RECORD_PID=$!
/tmp/runaway.sh
sudo kill $RECORD_PID

# Replay
sudo ./target/release/cognitod --replay /tmp/runaway.ndjson \
  --handler rules:configs/rules.yaml
```

**Data used**:
- `ppid` to track which parent is spawning children
- Fork events grouped by parent PID
- Time window tracking

---

### 3. High Exec Rate with Short Lifetimes

**Rule Detector**: `ExecRate`

**What it detects**:
- Many processes executing and completing quickly
- Potential build storms or script loops
- Rapid command execution patterns

**Example configuration**:
```yaml
- name: exec_flood
  detector:
    exec_rate:
      rate_per_min: 60
      median_lifetime: 5
```

**Test scenario**:
```bash
# Generate rapid short-lived processes
sudo ./target/release/cognitod --record /tmp/exec-flood.ndjson &
RECORD_PID=$!

for i in {1..100}; do
  echo "test" > /dev/null &
  sleep 0.1
done

sudo kill $RECORD_PID

# Replay
sudo ./target/release/cognitod --replay /tmp/exec-flood.ndjson \
  --handler rules:configs/rules.yaml
```

**Data used**:
- `event_type == 0` (Exec events)
- `event_type == 2` (Exit events)
- Lifetime = Exit timestamp - Exec timestamp
- Rate calculation over 60-second window

---

### 4. Short-Lived Job Floods

**Rule Detector**: `ShortJobFlood`

**What it detects**:
- Many processes with very short execution times (< 100ms)
- Rapid spawning of ephemeral processes
- Shell script thrashing

**Example configuration**:
```yaml
- name: short_jobs
  detector:
    short_job_flood:
      threshold: 50
      window_seconds: 30
      max_exec_duration_ms: 100
```

**Test scenario**:
```bash
# Generate many short-lived processes
sudo ./target/release/cognitod --record /tmp/short-jobs.ndjson &
RECORD_PID=$!

for i in {1..80}; do
  /bin/true &
done
wait

sudo kill $RECORD_PID

# Replay
sudo ./target/release/cognitod --replay /tmp/short-jobs.ndjson \
  --handler rules:configs/rules.yaml
```

**Data used**:
- Process lifetime (Exec → Exit duration)
- Count of processes with lifetime ≤ threshold
- Time window for counting

---

### 5. Process Tree Structure Anomalies

**What it detects**:
- Unusual parent-child relationships
- Orphaned processes
- Suspicious process lineage
- Reparenting patterns

**Test scenario**:
```bash
# Record normal activity
sudo ./target/release/cognitod --record /tmp/process-tree.ndjson &
RECORD_PID=$!

# Generate various parent-child patterns
bash -c 'bash -c "bash -c \"sleep 5\""'  # Deep nesting
ssh localhost 'sleep 2'  # Remote execution

sudo kill $RECORD_PID

# Replay and analyze tree structure
sudo ./target/release/cognitod --replay /tmp/process-tree.ndjson
```

**Data used**:
- `pid` and `ppid` for tree construction
- Fork and Exec events to build lineage
- Exit events to track process lifecycle

---

### 6. Suspicious Command Execution Patterns

**What it detects**:
- Known malicious command names
- Suspicious binary execution
- Crypto miner patterns
- Reverse shell commands

**Test scenario**:
```bash
# Record commands
sudo ./target/release/cognitod --record /tmp/commands.ndjson &
RECORD_PID=$!

# Execute various commands
nc -l 4444 &
NC_PID=$!
bash -c "echo test"
python3 -c "print('hello')"
kill $NC_PID

sudo kill $RECORD_PID

# Analyze command names
jq -r '.event.base.comm' /tmp/commands.ndjson | \
  python3 -c "import sys, json; \
  [print(bytes(json.loads(line)).decode('utf-8', errors='ignore').rstrip('\x00')) \
  for line in sys.stdin]" | sort | uniq
```

**Data used**:
- `comm` field (16-byte command name)
- Pattern matching against known malicious commands
- Command name frequency analysis

---

### 7. Privilege Escalation Detection

**What it detects**:
- UID/GID changes indicating privilege changes
- Processes starting as one user, running as another
- Sudo/setuid execution patterns

**Test scenario**:
```bash
# Record privileged operations
sudo ./target/release/cognitod --record /tmp/privesc.ndjson &
RECORD_PID=$!

# Normal user operations
id
whoami

# Privileged operations
sudo ls /root
sudo id

sudo kill $RECORD_PID

# Analyze UID changes
jq '.event.base | {pid, uid, gid, comm}' /tmp/privesc.ndjson | \
  grep -v '"uid": 0' -A 1 | head -20
```

**Data used**:
- `uid` and `gid` fields
- Tracking UID changes within process lineage
- Correlating with command names

---

## ❌ Unsupported Incident Types

These incidents **cannot** be detected with Phase 1 replay because they require system-wide resource metrics not captured in ProcessEvent data:

### 1. Circuit Breaker Incidents

**Why not supported**:
- Requires real-time PSI (Pressure Stall Information) metrics from `/proc/pressure/cpu`, `/proc/pressure/memory`, `/proc/pressure/io`
- Needs system-wide CPU percentage
- Requires load average data

**Missing data**:
```rust
pub struct SystemSnapshot {
    timestamp: u64,
    cpu_percent: f32,              // ❌ Not in ProcessEvent
    mem_percent: f32,              // ❌ Not in ProcessEvent
    load_avg: [f32; 3],            // ❌ Not in ProcessEvent
    psi_cpu_some_avg10: f32,       // ❌ Not in ProcessEvent
    psi_memory_some_avg10: f32,    // ❌ Not in ProcessEvent
    psi_memory_full_avg10: f32,    // ❌ Not in ProcessEvent
    psi_io_some_avg10: f32,        // ❌ Not in ProcessEvent
    psi_io_full_avg10: f32,        // ❌ Not in ProcessEvent
    // ...
}
```

**When available**: Phase 2 (see `RECORD_REPLAY_PLAN.md`)

---

### 2. CPU Threshold Breaches

**Rule Detector**: `SubtreeCpuPct` (exists but doesn't fire)

**Why not supported**:
- Requires `cpu_pct_milli != 65535` (PERCENT_MILLI_UNKNOWN)
- Current eBPF implementation doesn't populate CPU percentage in ring buffer events
- `cpu_percent()` method returns `None` for all recorded events

**Example configuration that won't work**:
```yaml
- name: high_cpu
  detector:
    subtree_cpu_pct:
      threshold: 80.0
      duration: 30
```

**Code check**:
```rust
// From alerts.rs:801
if let Some(cpu) = event.cpu_percent() {
    // This block NEVER executes during replay
    // because cpu_percent() returns None when cpu_pct_milli == 65535
}
```

**Evidence from recordings**:
```bash
jq '.event.base.cpu_pct_milli' examples/record-replay/sample-events.ndjson | \
  sort | uniq
# Output: 65535 (all events have unknown CPU)
```

---

### 3. Memory Exhaustion

**Rule Detector**: `SubtreeRssMb` (exists but doesn't fire)

**Why not supported**:
- Requires valid `mem_pct_milli` values
- Most events have `mem_pct_milli: 65535` (unknown)
- `mem_percent()` method returns `None`

**Example configuration that won't work**:
```yaml
- name: memory_hog
  detector:
    subtree_rss_mb:
      threshold: 1024
      duration: 30
```

**Evidence from recordings**:
```bash
jq '.event.base.mem_pct_milli' examples/record-replay/sample-events.ndjson | \
  sort | uniq -c
# Output shows mostly 65535 (unknown)
```

---

### 4. I/O Pressure Incidents

**Why not supported**:
- Requires PSI I/O metrics (`psi_io_some_avg10`, `psi_io_full_avg10`)
- No disk I/O statistics in ProcessEvent
- No network I/O statistics in ProcessEvent

**Missing data**:
- `psi_io_some_avg10` - I/O pressure (some processes waiting)
- `psi_io_full_avg10` - I/O pressure (all processes stalled)
- `disk_read_bytes`, `disk_write_bytes` - System-wide disk activity
- `net_rx_bytes`, `net_tx_bytes` - System-wide network activity

---

### 5. Load Average Spikes

**Why not supported**:
- Requires system-wide load average from `/proc/loadavg`
- ProcessEvent only contains per-process data
- No aggregated system metrics

**Missing data**:
```rust
load_avg: [f32; 3]  // 1-min, 5-min, 15-min load averages
```

---

### 6. Disk Space Exhaustion

**Why not supported**:
- Requires filesystem statistics
- No disk usage tracking in ProcessEvent
- Needs system-wide monitoring

---

### 7. Network Saturation

**Why not supported**:
- Requires network interface statistics
- No bandwidth metrics in ProcessEvent
- Needs system-wide monitoring

---

## Data Verification Commands

### Check Event Type Distribution

```bash
jq '.event.base.event_type' examples/record-replay/sample-events.ndjson | \
  sort | uniq -c
```

Expected output:
```
  150 0  # Exec events
  100 1  # Fork events
   77 2  # Exit events
```

### Verify CPU/Memory Values

```bash
jq '.event.base | {cpu: .cpu_pct_milli, mem: .mem_pct_milli}' \
  examples/record-replay/sample-events.ndjson | \
  sort | uniq -c | head
```

Expected output:
```
  225 {"cpu":65535,"mem":65535}  # All unknown
    2 {"cpu":65535,"mem":0}      # Exit events
```

### Extract Command Names

```bash
jq -r '.event.base.comm | @json' examples/record-replay/sample-events.ndjson | \
  python3 -c "import sys, json; \
  [print(bytes(json.loads(line)).decode('utf-8', errors='ignore').rstrip('\x00')) \
  for line in sys.stdin]" | \
  sort | uniq
```

### Analyze Process Relationships

```bash
jq '.event.base | {pid, ppid, type: .event_type}' \
  examples/record-replay/sample-events.ndjson | \
  head -20
```

---

## Capability Matrix

| Detection Type | Phase 1 Replay | Data Source | Notes |
|----------------|----------------|-------------|-------|
| **Process Lifecycle** |
| Fork storm | ✅ Full | ProcessEvent | Uses fork events + timing |
| Exec flooding | ✅ Full | ProcessEvent | Uses exec events + lifetimes |
| Short-lived jobs | ✅ Full | ProcessEvent | Uses exec→exit duration |
| Runaway tree | ✅ Full | ProcessEvent | Tracks ppid fork patterns |
| Process tree analysis | ✅ Full | ProcessEvent | Uses pid/ppid relationships |
| **Behavioral** |
| Command patterns | ✅ Full | ProcessEvent.comm | 16-byte command name |
| Privilege escalation | ✅ Full | ProcessEvent.uid/gid | UID/GID tracking |
| Suspicious lineage | ✅ Full | ProcessEvent | Parent-child analysis |
| **Resource-Based** |
| Circuit breaker | ❌ None | SystemSnapshot | Needs PSI metrics |
| CPU thresholds | ❌ None | SystemSnapshot | cpu_pct_milli always 65535 |
| Memory thresholds | ❌ None | SystemSnapshot | mem_pct_milli always 65535 |
| I/O pressure | ❌ None | SystemSnapshot | No I/O metrics |
| Load average | ❌ None | SystemSnapshot | No system-wide data |
| Disk exhaustion | ❌ None | SystemSnapshot | No filesystem metrics |
| Network saturation | ❌ None | SystemSnapshot | No network metrics |

---

## Implementation Architecture

### Recording Flow

```
eBPF Probes → Ring Buffer → ProcessEvent
                               ↓
                    RecordingHandler
                               ↓
                     NDJSON File (disk)
```

### Replay Flow

```
NDJSON File → ReplayListener → ProcessEvent
                                    ↓
                              HandlerList
                                    ↓
                         [Rules, Context, etc.]
```

### Key Code Locations

- **ProcessEvent definition**: `linnix-ai-ebpf/linnix-ai-ebpf-common/src/lib.rs:14-39`
- **cpu_percent() method**: `linnix-ai-ebpf/linnix-ai-ebpf-common/src/lib.rs:214-220`
- **mem_percent() method**: `linnix-ai-ebpf/linnix-ai-ebpf-common/src/lib.rs:236-242`
- **Rule detectors**: `cognitod/src/alerts.rs:617-796`
- **Incident storage**: `cognitod/src/incidents.rs:17-30`
- **Recording handler**: `cognitod/src/handler/recording.rs`
- **Replay listener**: `cognitod/src/runtime/replay_listener.rs`

---

## Future Enhancements (Phase 2+)

To support resource-based incident detection, Phase 2 will add:

1. **SystemSnapshot Recording**
   - Periodic snapshots of PSI metrics
   - CPU/memory percentages
   - Load averages
   - Disk/network statistics

2. **Extended NDJSON Format**
   ```json
   {"type": "process_event", "timestamp": ..., "event": {...}}
   {"type": "system_snapshot", "timestamp": ..., "snapshot": {...}}
   ```

3. **Replay Synchronization**
   - Interleave process events with system snapshots
   - Maintain timing relationships
   - Trigger circuit breaker logic during replay

4. **Enhanced Detectors**
   - Circuit breaker replay with recorded thresholds
   - PSI-based attribution during replay
   - Resource trend analysis

See `RECORD_REPLAY_PLAN.md` for Phase 2 implementation details.

---

## Testing Recommendations

### Comprehensive Test Suite

```bash
# 1. Fork storm
(for i in {1..100}; do sleep 0.1 & done) &
STORM=$!
sudo cognitod --record /tmp/test-fork.ndjson &
R=$!
sleep 10
kill $STORM $R

# 2. Exec flood
sudo cognitod --record /tmp/test-exec.ndjson &
R=$!
for i in {1..200}; do /bin/true & done
wait
kill $R

# 3. Deep process tree
sudo cognitod --record /tmp/test-tree.ndjson &
R=$!
bash -c 'bash -c "bash -c \"sleep 5\""'
kill $R

# 4. Privilege escalation
sudo cognitod --record /tmp/test-priv.ndjson &
R=$!
id
sudo id
kill $R

# Replay all tests
for f in /tmp/test-*.ndjson; do
  echo "Testing $f"
  sudo cognitod --replay "$f" --replay-speed 10.0 \
    --handler rules:configs/rules.yaml
done
```

---

## Summary

**Phase 1 Replay Strengths**:
- ✅ Excellent for **behavioral anomaly detection**
- ✅ Full process lifecycle tracking
- ✅ Process tree analysis
- ✅ Command execution patterns
- ✅ Fork bombs and runaway processes
- ✅ Fast, lightweight recording (~250 bytes/event)

**Phase 1 Replay Limitations**:
- ❌ No resource exhaustion incidents
- ❌ No CPU/memory threshold detection
- ❌ No PSI-based circuit breaker incidents
- ❌ No system-wide metrics

**Best Use Cases for Phase 1**:
- Testing fork storm detection rules
- Validating process tree analysis logic
- Debugging behavioral anomaly detectors
- Sharing reproducible test cases
- CI/CD integration testing
- Offline analysis of process patterns

**When to Wait for Phase 2**:
- Circuit breaker testing
- PSI-based attribution
- Resource threshold tuning
- System-wide incident reproduction
