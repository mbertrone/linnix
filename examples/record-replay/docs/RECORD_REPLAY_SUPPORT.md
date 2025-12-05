# Record/Replay Support for Linnix Cognitod

This document analyzes the feasibility and implementation approach for adding record/replay functionality to Linnix cognitod, enabling offline analysis and testing of system behavior.

## Executive Summary

**Feasibility:** ✅ **Highly Feasible** with some implementation complexity

**Key Finding:** Recording only eBPF ring buffer events is **insufficient** for full replay. Cognitod relies heavily on system-wide monitoring data that exists outside the ring buffer.

**Recommendation:** Implement a **hybrid recording approach** that captures both eBPF events and periodic system snapshots.

---

## Current Architecture Analysis

### Data Flow Overview

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

### Event Processing Pipeline

**Location:** `cognitod/src/runtime/stream_listener.rs:84-218`

1. **eBPF Events** → Ring Buffer → `start_perf_listener()`
2. **Event Parsing** → `ProcessEvent` structs (with serde support)
3. **Handler Pipeline** → Rules engine, context store, analysis
4. **System Monitoring** → Periodic snapshots (every 5 seconds)

---

## Data Sources Analysis

### Ring Buffer Events (✅ eBPF - Recordable)

**Location:** `linnix-ai-ebpf-common/src/lib.rs:14-40`

```rust
pub struct ProcessEvent {
    pub pid: u32,
    pub ppid: u32,
    pub uid: u32,
    pub gid: u32,
    pub event_type: u32,  // Fork=1, Exec=0, Exit=2, etc.
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

### System Monitoring Data (❌ External - Missing from ring buffer)

**Location:** `cognitod/src/context.rs:258-317`

#### CPU/Memory System Stats
```rust
// sysinfo library reading /proc/stat, /proc/meminfo
sys.refresh_cpu_all();
sys.refresh_memory();
let cpu_percent = sys.global_cpu_usage();
let mem_percent = (sys.used_memory() as f32 / sys.total_memory() as f32) * 100.0;
```

#### PSI (Pressure Stall Information)
```rust
// cognitod/src/utils/psi.rs:48-86 reading /proc/pressure/*
let psi = PsiMetrics::read().unwrap_or_default();
// psi.cpu_some_avg10, psi.memory_full_avg10, etc.
```

#### Network & Disk Stats
```rust
// sysinfo reading /proc/net/dev and sysfs disk stats
let mut networks = Networks::new_with_refreshed_list();
let mut disks = Disks::new_with_refreshed_list();
```

#### Per-Process Stats
```rust
// sysinfo reading /proc/*/stat and /proc/*/status
for event in live.values_mut() {
    if let Some(proc) = sys.process(Pid::from_u32(event.pid)) {
        event.set_cpu_percent(Some(proc.cpu_usage()));
        event.set_mem_percent(/* calculated from proc.memory() */);
    }
}
```

---

## Incident Types & Data Dependencies

### 1. Circuit Breaker Incidents (❌ System Monitoring Required)

**Example Incident:**
```json
{
  "id": 33,
  "event_type": "circuit_breaker_cpu",
  "psi_cpu": 49.4,           // ← /proc/pressure/cpu
  "cpu_percent": 99.82548,   // ← sysinfo
  "load_avg": "7.51,5.75,4.73",  // ← /proc/loadavg
  "target_pid": 303105,      // ← eBPF
  "target_name": "coordinator"  // ← eBPF
}
```

**Detection Logic:** `main.rs:915-916`
```rust
let is_breaching = snapshot.cpu_percent > cb_cfg.cpu_usage_threshold
    && snapshot.psi_cpu_some_avg10 > cb_cfg.cpu_psi_threshold;
```

**Data Sources:**
- ❌ `cpu_percent` (99.8%) - System monitoring
- ❌ `psi_cpu_some_avg10` (49.4%) - `/proc/pressure/cpu`
- ✅ `target_pid` & `target_name` - eBPF events

### 2. Rules Engine Incidents (Mixed Dependencies)

**Location:** `cognitod/src/alerts.rs:83-125`

#### Process Lifecycle Based (✅ eBPF Sufficient)
- **Fork Storm** (`ForksPerSec`, `ForkBurst`)
- **Process Tree Explosion** (`RunawayTree`) 
- **Command Execution** (`ExecRate` - partial)

#### Resource Consumption Based (❌ System Monitoring Required)
- **CPU Pressure** (`SubtreeCpuPct`) - Uses sysinfo per-process stats
- **Memory Pressure** (`SubtreeRssMb`) - Uses sysinfo per-process stats

#### Timing-Based (❌ System Time Required)
- **Short Job Floods** (`ShortJobFlood`) - Needs accurate timestamps
- **Rate Calculations** - All require system time correlation

### 3. PSI Attribution (❌ System Monitoring Only)

**Location:** `cognitod/src/collectors/psi.rs:114-200`
- Detects stall contributors when PSI > 100ms threshold
- Requires `/proc/pressure/*` files and top process identification

---

## Implementation Strategy

### Option 1: Enhanced Recording (Recommended)

Record both eBPF events and system snapshots in a unified format:

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
    PsiMetrics {
        timestamp: u64,
        metrics: PsiMetrics,
    },
}
```

**Implementation Points:**
- **Recording Mode:** Add `--record <file>` flag to cognitod
- **System Snapshots:** Capture every 5 seconds (circuit breaker frequency)
- **Event Correlation:** Timestamp alignment for proper replay
- **File Format:** NDJSON for streaming and size efficiency

### Option 2: Hybrid Replay (Simpler but Less Accurate)

- Replay eBPF events from file
- Continue reading live system metrics during replay
- Suitable for testing process-only detection logic

### Option 3: Ring Buffer Only (Limited Scope)

- Record/replay only eBPF events
- Supports fork storm, process tree analysis
- **Cannot reproduce circuit breaker incidents or resource-based detection**

---

## Code Changes Required

### 1. Recording Implementation

**New Handler:** `cognitod/src/handler/recording.rs`
```rust
pub struct RecordingHandler {
    writer: BufWriter<File>,
}

impl Handler for RecordingHandler {
    async fn on_event(&self, event: &ProcessEvent) {
        let recorded = RecordedEvent::ProcessEvent {
            timestamp: SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() as u64,
            event: event.clone(),
        };
        // Serialize and write
    }
    
    async fn on_snapshot(&self, snapshot: &SystemSnapshot) {
        let recorded = RecordedEvent::SystemSnapshot {
            timestamp: SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() as u64,
            snapshot: snapshot.clone(),
        };
        // Serialize and write
    }
}
```

### 2. Replay Implementation

**New Event Source:** Replace `start_perf_listener()` with file reader
```rust
pub async fn start_replay_listener(
    replay_file: PathBuf,
    context: Arc<ContextStore>,
    handlers: Arc<HandlerList>,
    // ... other params
) {
    let reader = BufReader::new(File::open(replay_file)?);
    for line in reader.lines() {
        let event: RecordedEvent = serde_json::from_str(&line?)?;
        match event {
            RecordedEvent::ProcessEvent { event, .. } => {
                handlers.on_event(&event).await;
                context.add(event);
            },
            RecordedEvent::SystemSnapshot { snapshot, .. } => {
                context.set_system_snapshot(snapshot);
            },
            // ...
        }
    }
}
```

### 3. CLI Integration

**New Flags:** `cognitod/src/main.rs:137`
```rust
#[derive(Parser, Debug)]
struct Args {
    /// Record events to file
    #[arg(long)]
    record: Option<PathBuf>,
    
    /// Replay events from file
    #[arg(long)]
    replay: Option<PathBuf>,
    
    /// Replay speed multiplier (1.0 = real-time)
    #[arg(long, default_value = "1.0")]
    replay_speed: f32,
    
    // ... existing fields
}
```

---

## File Format Specification

### NDJSON Structure
```json
{"timestamp": 1764844721000000000, "type": "process_event", "data": {"pid": 303105, "event_type": 1, ...}}
{"timestamp": 1764844721000000000, "type": "system_snapshot", "data": {"cpu_percent": 99.8, "psi_cpu_some_avg10": 49.4, ...}}
{"timestamp": 1764844726000000000, "type": "process_event", "data": {"pid": 303105, "event_type": 2, ...}}
```

### Size Considerations
- **ProcessEvent:** ~200 bytes
- **SystemSnapshot:** ~150 bytes  
- **Recording Rate:** ~1000 events/sec + 0.2 snapshots/sec
- **Storage:** ~200KB/sec = ~17GB/day (high-activity system)

---

## Use Cases Enabled

### Development & Testing
1. **Regression Testing:** Capture production incidents, replay for testing detection logic
2. **Rule Development:** Test new detection rules against historical data
3. **Performance Analysis:** Offline analysis without impacting live systems

### Production Support
1. **Incident Reproduction:** Replay exact conditions that triggered alerts
2. **False Positive Analysis:** Debug why alerts fired incorrectly
3. **Threshold Tuning:** Test different thresholds against real workloads

### Security Analysis
1. **Attack Pattern Analysis:** Record and analyze malicious behavior
2. **Baseline Creation:** Establish normal behavior patterns for comparison

---

## Limitations & Considerations

### Current Limitations
1. **External Dependencies:** Cannot replay interactions with Kubernetes API, Slack webhooks, etc.
2. **Time Sensitivity:** Some detection depends on real-time intervals
3. **State Dependencies:** Process state outside of eBPF events may be lost

### Security Considerations
1. **Data Sensitivity:** Recorded files contain process names, PIDs, command lines
2. **Storage Security:** Recorded files should be encrypted at rest
3. **Access Control:** Limit access to recorded data

### Performance Impact
1. **Recording Overhead:** Minimal (~1% CPU) due to async I/O
2. **Disk Usage:** Significant for long-term recording
3. **Replay Performance:** Can run faster than real-time for analysis

---

## Conclusion

Record/replay functionality is **highly feasible** but requires recording both eBPF events and system monitoring data. The hybrid approach provides the most accurate reproduction of incidents while maintaining reasonable complexity.

**Key Benefits:**
- Enables offline analysis and testing
- Supports debugging of complex incidents
- Facilitates rule development and threshold tuning

**Implementation Priority:**
1. Basic eBPF event recording/replay (supports process analysis)
2. System snapshot integration (enables circuit breaker replay)
3. Advanced features (replay speed control, filtering, etc.)

The existing architecture's clean separation between event sources and analysis logic makes this implementation straightforward and minimally invasive.