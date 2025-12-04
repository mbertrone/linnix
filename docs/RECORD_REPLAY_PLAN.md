# Record/Replay Implementation Plan

This document outlines the implementation plan for adding record/replay functionality to Linnix cognitod, starting with eBPF event recording as the first milestone.

## Phase 1: eBPF Event Recording (First Step)

### Goal
Implement basic recording of eBPF events to file, enabling offline analysis of process lifecycle events, fork storms, and process tree analysis.

### Scope
- Record ProcessEvent structs from ring buffer to NDJSON file
- Support process lifecycle analysis (fork/exec/exit events)
- Enable fork storm and process tree detection replay
- **Excludes:** System monitoring data, circuit breaker incidents, resource-based detection

---

## Phase 1 Implementation Plan

### 1. Command Line Interface (1-2 hours)

**File:** `cognitod/src/main.rs`

**Add CLI arguments:**
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
    
    // ... existing fields
}
```

**Validation logic:**
- Ensure `--record` and `--replay` are mutually exclusive
- Validate file paths and permissions
- Create parent directories if needed for recording

### 2. Recording Handler Implementation (2-3 hours)

**New File:** `cognitod/src/handler/recording.rs`

```rust
use crate::{ProcessEvent, Handler};
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tokio::fs::OpenOptions;
use tokio::io::{AsyncWriteExt, BufWriter};

#[derive(Serialize, Deserialize)]
struct RecordedProcessEvent {
    /// Timestamp when event was recorded (nanoseconds since epoch)
    timestamp: u64,
    /// The original ProcessEvent from eBPF
    event: ProcessEvent,
}

pub struct RecordingHandler {
    writer: BufWriter<tokio::fs::File>,
    events_recorded: std::sync::atomic::AtomicU64,
}

impl RecordingHandler {
    pub async fn new(file_path: PathBuf) -> Result<Self> {
        // Create parent directory if needed
        if let Some(parent) = file_path.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }
        
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(file_path)
            .await?;
            
        Ok(Self {
            writer: BufWriter::new(file),
            events_recorded: std::sync::atomic::AtomicU64::new(0),
        })
    }
    
    pub fn events_recorded(&self) -> u64 {
        self.events_recorded.load(std::sync::atomic::Ordering::Relaxed)
    }
}

#[async_trait::async_trait]
impl Handler for RecordingHandler {
    async fn on_event(&self, event: &ProcessEvent) {
        let recorded_event = RecordedProcessEvent {
            timestamp: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos() as u64,
            event: event.clone(),
        };
        
        if let Ok(line) = serde_json::to_string(&recorded_event) {
            if let Err(e) = self.writer.write_all(format!("{}\n", line).as_bytes()).await {
                log::warn!("[recording] Failed to write event: {}", e);
            } else {
                self.events_recorded.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                
                // Flush periodically for safety
                if self.events_recorded() % 100 == 0 {
                    let _ = self.writer.flush().await;
                }
            }
        }
    }

    async fn on_snapshot(&self, _snapshot: &crate::types::SystemSnapshot) {
        // Phase 1: Ignore system snapshots
    }
}
```

### 3. Handler Registration (30 minutes)

**File:** `cognitod/src/handler/mod.rs`

```rust
pub mod recording;
pub use recording::RecordingHandler;
```

**File:** `cognitod/src/main.rs` (in main function)

```rust
// Initialize recording handler if requested
if let Some(record_path) = &args.record {
    if args.replay.is_some() {
        anyhow::bail!("Cannot use --record and --replay simultaneously");
    }
    
    match RecordingHandler::new(record_path.clone()).await {
        Ok(recording_handler) => {
            info!("[cognitod] Recording eBPF events to {}", record_path.display());
            handler_list.register(recording_handler);
        }
        Err(e) => {
            anyhow::bail!("Failed to initialize recording: {}", e);
        }
    }
}
```

### 4. Replay Event Source Implementation (3-4 hours)

**New File:** `cognitod/src/runtime/replay_listener.rs`

```rust
use crate::{ProcessEvent, handler::HandlerList, context::ContextStore, metrics::Metrics};
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::{path::PathBuf, sync::Arc, time::Duration};
use tokio::{fs::File, io::{AsyncBufReadExt, BufReader}, time::sleep};

#[derive(Serialize, Deserialize)]
struct RecordedProcessEvent {
    timestamp: u64,
    event: ProcessEvent,
}

pub async fn start_replay_listener(
    replay_file: PathBuf,
    context: Arc<ContextStore>,
    metrics: Arc<Metrics>,
    handlers: Arc<HandlerList>,
    replay_speed: f32,
) -> Result<()> {
    info!("[cognitod] Starting replay from {}", replay_file.display());
    
    let file = File::open(&replay_file).await?;
    let reader = BufReader::new(file);
    let mut lines = reader.lines();
    
    let mut events_replayed = 0u64;
    let mut last_timestamp: Option<u64> = None;
    
    while let Some(line) = lines.next_line().await? {
        let recorded_event: RecordedProcessEvent = match serde_json::from_str(&line) {
            Ok(event) => event,
            Err(e) => {
                log::warn!("[replay] Failed to parse line: {} - Error: {}", line, e);
                continue;
            }
        };
        
        // Calculate delay for realistic timing
        if let Some(last_ts) = last_timestamp {
            let time_diff_ns = recorded_event.timestamp.saturating_sub(last_ts);
            let delay_ms = (time_diff_ns as f64 / 1_000_000.0 / replay_speed as f64) as u64;
            
            if delay_ms > 0 && delay_ms < 10_000 { // Cap at 10 seconds
                sleep(Duration::from_millis(delay_ms)).await;
            }
        }
        
        // Process the event through normal pipeline
        let event = recorded_event.event;
        handlers.on_event(&event).await;
        context.add(event);
        
        events_replayed += 1;
        last_timestamp = Some(recorded_event.timestamp);
        
        // Log progress periodically
        if events_replayed % 1000 == 0 {
            info!("[replay] Processed {} events", events_replayed);
        }
    }
    
    info!("[replay] Completed: {} events replayed from {}", 
          events_replayed, replay_file.display());
    
    Ok(())
}
```

### 5. Replay Integration (1 hour)

**File:** `cognitod/src/runtime/mod.rs`

```rust
pub mod replay_listener;
pub use replay_listener::start_replay_listener;
```

**File:** `cognitod/src/main.rs` (replace perf listener logic)

```rust
// Handle replay mode vs normal mode
if let Some(replay_path) = args.replay {
    if args.record.is_some() {
        anyhow::bail!("Cannot use --record and --replay simultaneously");
    }
    
    info!("[cognitod] Replay mode enabled, skipping eBPF initialization");
    
    // Start replay listener instead of perf listener
    tokio::spawn(async move {
        if let Err(e) = start_replay_listener(
            replay_path,
            Arc::clone(&context),
            Arc::clone(&metrics),
            Arc::clone(&handlers),
            args.replay_speed,
        ).await {
            error!("[replay] Failed: {}", e);
        }
    });
} else {
    // Normal eBPF initialization and perf listener
    // ... existing code ...
    
    if !perf_buffers.is_empty() {
        start_perf_listener(
            perf_buffers,
            Arc::clone(&context),
            Arc::clone(&metrics),
            Arc::clone(&handlers),
            Arc::clone(&offline_guard),
            config.runtime.events_rate_cap,
        );
    }
}
```

### 6. Testing & Validation (2 hours)

**Test Recording:**
```bash
# Record events for 30 seconds
sudo ./target/release/cognitod --record /tmp/test_events.ndjson &
PID=$!
sleep 30
kill $PID

# Check output
head -5 /tmp/test_events.ndjson
wc -l /tmp/test_events.ndjson
```

**Test Replay:**
```bash
# Replay at normal speed
sudo ./target/release/cognitod --replay /tmp/test_events.ndjson --replay-speed 1.0

# Replay at 10x speed
sudo ./target/release/cognitod --replay /tmp/test_events.ndjson --replay-speed 10.0
```

**Test Fork Storm Detection:**
```bash
# Generate fork storm during recording
while true; do ( sleep 0.1 & ); done &
STORM_PID=$!

# Record for 10 seconds
sudo ./target/release/cognitod --record /tmp/fork_storm.ndjson &
RECORD_PID=$!
sleep 10
kill $RECORD_PID $STORM_PID

# Verify fork storm is detected during replay
sudo ./target/release/cognitod --replay /tmp/fork_storm.ndjson --handler rules:configs/rules.yaml
```

---

## File Format Specification (Phase 1)

### NDJSON Structure
Each line contains one JSON object:
```json
{"timestamp":1764844721000000000,"event":{"pid":12345,"ppid":1234,"uid":1000,"gid":1000,"event_type":1,"ts_ns":1764844721000000000,"comm":[99,111,109,109,97,110,100,0,0,0,0,0,0,0,0,0],"exit_time_ns":0,"cpu_pct_milli":65535,"mem_pct_milli":65535,"data":0,"data2":0,"aux":0,"aux2":0}}
```

### Size Estimates
- **ProcessEvent:** ~200 bytes per event
- **JSON overhead:** ~50 bytes per event  
- **Total:** ~250 bytes per event
- **Storage rate:** 1000 events/sec = 250KB/sec = ~21GB/day (high activity)

### File Rotation (Future Enhancement)
Consider implementing file rotation for long-running recordings:
```
events-20250101-120000.ndjson
events-20250101-130000.ndjson
```

---

## Success Criteria for Phase 1

### Functional Requirements
- ✅ Record eBPF events with `--record filename.ndjson`
- ✅ Replay eBPF events with `--replay filename.ndjson`  
- ✅ Support replay speed control with `--replay-speed N.N`
- ✅ Maintain normal event processing during recording
- ✅ Process replayed events through existing handler pipeline

### Quality Requirements
- ✅ Graceful error handling for file I/O issues
- ✅ Progress logging during replay
- ✅ Minimal performance impact during recording (<1% CPU overhead)
- ✅ Proper cleanup on shutdown

### Validation Requirements
- ✅ Fork storm detection works on replayed events
- ✅ Process tree analysis works on replayed events
- ✅ Rules engine fires same alerts during replay
- ✅ File format is human-readable and parseable

---

## Phase 1 Limitations

### What Works
- ✅ Process lifecycle events (fork/exec/exit)
- ✅ Fork storm detection
- ✅ Process tree analysis  
- ✅ Command execution patterns
- ✅ Basic rules engine alerts

### What Doesn't Work (Future Phases)
- ❌ Circuit breaker incidents (needs system snapshots)
- ❌ CPU/memory threshold detection (needs sysinfo data)
- ❌ PSI-based analysis (needs /proc/pressure/* data)
- ❌ Real-time resource consumption alerts

### Workarounds
- Use existing rules focused on process events
- Create test scenarios that trigger process-based detection
- Focus on fork storms and process tree anomalies

---

## Next Steps After Phase 1

1. **Phase 2:** Add system snapshot recording (enables circuit breaker replay)
2. **Phase 3:** Add file rotation and compression 
3. **Phase 4:** Add filtering and analysis tools
4. **Phase 5:** Add distributed recording across multiple hosts

---

## Estimated Timeline

**Total Phase 1 Duration:** 8-12 hours development + 2 hours testing

**Breakdown:**
- CLI interface: 1-2 hours
- Recording handler: 2-3 hours  
- Replay listener: 3-4 hours
- Integration: 1 hour
- Testing: 2 hours

**Dependencies:**
- None (uses existing ProcessEvent serialization)
- Requires existing handler and context infrastructure

**Risk Mitigation:**
- Start with simple file I/O before optimizing
- Test with small datasets first
- Implement error handling from the beginning