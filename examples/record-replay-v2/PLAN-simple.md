# Record/Replay V2 - Simplified Implementation Plan

This document outlines a minimal-change approach to enhance Linnix record/replay with periodic snapshots using JSON format and simple file structure.

## Design Philosophy: Minimal Changes, Maximum Impact

### Core Approach
- **Reuse existing JSON infrastructure** (no new serialization)
- **Single file format** with different entry types
- **Optional compression** for storage efficiency
- **Backward compatible** with V1 recordings
- **Incremental implementation** - can be built in days, not weeks

## Simplified Data Format

### Unified JSON Entry Format
```json
{
  "type": "process_event",
  "timestamp": 1705939200123456789,
  "data": {
    // Existing ProcessEvent JSON structure
    "pid": 12345,
    "event_type": 0,
    "comm": "python3",
    // ... existing fields
  }
}
```

```json
{
  "type": "system_snapshot", 
  "timestamp": 1705939200123456789,
  "data": {
    "cpu_percent": 45.2,
    "mem_percent": 67.8,
    "psi_cpu_some_avg10": 23.4,
    "psi_memory_some_avg10": 12.1,
    "load_avg": [2.1, 1.8, 1.5],
    "active_processes": [
      {
        "pid": 1234,
        "comm": "python3",
        "cpu_percent": 15.2,
        "mem_percent": 8.9,
        "rss_mb": 145
      }
      // ... more processes above threshold
    ]
  }
}
```

### File Structure - Line-Delimited JSON (JSONL)
```
recording_v2.jsonl (optionally .jsonl.gz):
{"type":"process_event","timestamp":1705939200123456789,"data":{...}}
{"type":"system_snapshot","timestamp":1705939201000000000,"data":{...}}  
{"type":"process_event","timestamp":1705939201234567890,"data":{...}}
{"type":"system_snapshot","timestamp":1705939202000000000,"data":{...}}
...
```

## Implementation Strategy

### Phase 1: Extend Existing Recorder (1-2 days)
```rust
// Minimal changes to existing recorder
impl Recorder {
    // Add new entry type alongside existing process events
    pub fn record_system_snapshot(&self, snapshot: SystemSnapshot) -> Result<()> {
        let entry = json!({
            "type": "system_snapshot",
            "timestamp": precise_timestamp_ns(),
            "data": snapshot
        });
        
        // Reuse existing write infrastructure
        self.write_json_line(&entry)
    }
}
```

### Phase 2: Add Periodic Collection Task (1 day)
```rust
// Add to main.rs alongside existing tasks
async fn snapshot_recorder_task(
    ctx: Arc<ContextStore>,
    recorder: Arc<Option<Recorder>>, 
    interval_ms: u64
) {
    let mut interval = tokio::time::interval(Duration::from_millis(interval_ms));
    
    loop {
        interval.tick().await;
        
        if let Some(ref recorder) = *recorder {
            // Reuse existing SystemSnapshot + add process list
            let snapshot = enhanced_system_snapshot(&ctx).await;
            let _ = recorder.record_system_snapshot(snapshot);
        }
    }
}

// Enhanced snapshot with process stats
async fn enhanced_system_snapshot(ctx: &ContextStore) -> EnhancedSystemSnapshot {
    let base_snapshot = ctx.get_system_snapshot();
    let top_processes = get_active_processes(ctx, 50); // Top 50 processes
    
    EnhancedSystemSnapshot {
        // All existing SystemSnapshot fields
        cpu_percent: base_snapshot.cpu_percent,
        mem_percent: base_snapshot.mem_percent,
        psi_cpu_some_avg10: base_snapshot.psi_cpu_some_avg10,
        // ... all other existing fields
        
        // New field: active process list
        active_processes: top_processes,
    }
}
```

### Phase 3: Isolated Replay Engine (1-2 days)
```rust
pub struct SimpleReplayEngine {
    entries: Vec<ReplayEntry>,
    current_index: usize,
    replay_mode: bool, // Critical: prevents any live system access
}

#[derive(Deserialize)]
struct ReplayEntry {
    #[serde(rename = "type")]
    entry_type: String,
    timestamp: u64,
    data: serde_json::Value, // Keep as raw JSON for flexibility
}

impl SimpleReplayEngine {
    pub fn load_recording(path: &str) -> Result<Self> {
        let file = File::open(path)?;
        let reader = BufReader::new(file);
        
        let mut entries = Vec::new();
        for line in reader.lines() {
            let entry: ReplayEntry = serde_json::from_str(&line?)?;
            entries.push(entry);
        }
        
        // Sort by timestamp (should already be sorted)
        entries.sort_by_key(|e| e.timestamp);
        
        Ok(Self { 
            entries, 
            current_index: 0,
            replay_mode: true  // CRITICAL: Mark as replay-only mode
        })
    }
    
    pub fn seek_to_time(&mut self, target_timestamp: u64) -> Option<&ReplayEntry> {
        // REPLAY ONLY: Use binary search on recorded data
        self.current_index = self.entries
            .binary_search_by_key(&target_timestamp, |e| e.timestamp)
            .unwrap_or_else(|i| i);
            
        self.entries.get(self.current_index)
    }
    
    pub fn get_system_state_at(&self, timestamp: u64) -> Option<serde_json::Value> {
        // REPLAY ONLY: Find nearest recorded system_snapshot before timestamp
        for entry in self.entries[..=self.current_index].iter().rev() {
            if entry.entry_type == "system_snapshot" && entry.timestamp <= timestamp {
                return Some(entry.data.clone());
            }
        }
        None
    }
    
    pub fn get_process_events_in_range(&self, start_ts: u64, end_ts: u64) -> Vec<&ReplayEntry> {
        // REPLAY ONLY: Filter recorded process events by timestamp range
        self.entries.iter()
            .filter(|entry| {
                entry.entry_type == "process_event" &&
                entry.timestamp >= start_ts && 
                entry.timestamp <= end_ts
            })
            .collect()
    }
}
```

## Configuration (Minimal Addition)

### Simple Config Addition
```toml
[recording]
# Existing V1 settings remain unchanged
enabled = true
file_path = "linnix_recording.jsonl"

# New V2 settings (all optional)
snapshots_enabled = true           # Default: false
snapshot_interval_ms = 5000        # Default: 5000 (5 seconds)
compress_output = false            # Default: false (.jsonl vs .jsonl.gz)
process_snapshot_limit = 50        # Default: 50 (top N processes)
process_cpu_threshold = 1.0        # Default: 1.0% (only record active processes)
```

### RSS Tracking Integration
```rust
// Fix existing RSS tracking issue with simple config
// In main.rs:936, replace hardcoded threshold:

// OLD:
let is_active = eps >= 20;

// NEW: 
let is_active = eps >= self.config.recording.activity_threshold.unwrap_or(20);
```

## Storage Analysis

### Format Efficiency
- **JSON**: Human readable, debugging friendly, existing infrastructure
- **Compression**: Optional gzip reduces size by ~70%
- **Line-delimited**: Streamable, seekable, appendable

### Size Estimates (per hour)
- **Process Events**: ~1MB (existing, unchanged)  
- **System Snapshots**: ~200KB (5s intervals, 50 processes each)
- **Total Uncompressed**: ~1.2MB/hour
- **Total Compressed**: ~360KB/hour

## Isolated Replay Capabilities

### Critical Design Principle: File-Only Data Access

**🚨 REPLAY ENGINE ISOLATION REQUIREMENTS:**
- **NO eBPF probe instantiation** - replay works from recorded data only
- **NO /proc filesystem access** - all process data from recording
- **NO /sys filesystem access** - all system metrics from recording  
- **NO live system calls** - complete isolation from running system
- **READ-ONLY file access** - only reads the recording file

### What This Simple Approach Enables

✅ **Incident Reproduction** (File-Only):
```bash
# Find RECORDED system state when incident occurred
cognitod replay --file incident.jsonl --time "2024-01-15T14:30:00Z" --show-system --offline
```

✅ **Process Timeline Analysis** (File-Only):
```bash  
# Show RECORDED process activity leading to incident
cognitod replay --file incident.jsonl --pid 12345 --before 300s --offline
```

✅ **Alert Rule Validation** (File-Only):
```bash
# Test rules against RECORDED data only (no live system access)
cognitod replay --file incident.jsonl --test-rules rules.yaml --offline-mode
```

✅ **Memory Growth Tracking** (File-Only):
```bash
# Show RECORDED memory usage over time
cognitod replay --file incident.jsonl --show-memory --process python3 --offline
```

### File-Only Analysis Examples
```bash
# Extract all RECORDED system snapshots (no live system access)
grep '"type":"system_snapshot"' recording.jsonl > snapshots.jsonl

# Get RECORDED CPU usage over time (from snapshots only)
grep '"type":"system_snapshot"' recording.jsonl | jq '.data.cpu_percent'

# Find RECORDED memory spikes (from snapshots only)  
grep '"type":"system_snapshot"' recording.jsonl | jq 'select(.data.mem_percent > 80)'

# RECORDED process creation timeline (from process events only)
grep '"type":"process_event"' recording.jsonl | jq 'select(.data.event_type == 0)'

# Verify offline-only operation - no system calls
strace -e trace=file,process cognitod replay --file recording.jsonl --offline 2>&1 | \
  grep -v recording.jsonl  # Should show no other file/system access
```

## Implementation Advantages

### Minimal Risk
- **No new dependencies**: Uses existing JSON infrastructure
- **No breaking changes**: V1 recordings still work
- **Gradual rollout**: Can enable snapshots independently
- **Simple debugging**: Human-readable JSON format
- **Complete isolation**: Replay never touches live system

### Fast Development
- **Reuse existing code**: SystemSnapshot, JSON serialization, file I/O
- **No complex indexing**: Simple linear search sufficient for small files
- **No binary formats**: Avoid serialization complexity
- **Standard tools**: jq, grep work for analysis
- **File-only operation**: No eBPF, /proc, /sys integration complexity

### Storage Flexibility  
- **Optional compression**: Enable when needed
- **Configurable detail**: Adjust process count and thresholds
- **Standard format**: Any JSON tool can process
- **Stream processing**: Can process while recording
- **Portable**: Recording files work on any system with replay tool

## Implementation Steps

### Day 1: Recording Enhancement
1. Add `EnhancedSystemSnapshot` struct with process list
2. Add `record_system_snapshot()` method to existing Recorder
3. Add periodic snapshot task to main.rs
4. Add config options for snapshot control

### Day 2: Isolated Replay Engine
1. Create `SimpleReplayEngine` with **read-only** JSON loading
2. Implement `seek_to_time()` and `get_system_state_at()` using **only recorded data**
3. Add **replay mode flag** to prevent any live system access
4. Implement **file-only data access** - no eBPF probes, no /proc, no /sys
5. Test with sample recordings in **complete isolation**

### Day 3: File-Only Analysis Tools
1. Add filtering and search capabilities **using recorded data only**
2. Create common analysis patterns (memory growth, CPU spikes) **from snapshots**
3. **Offline alert rule validation** - test rules against recorded events/snapshots
4. **Complete isolation verification** - ensure no live system access
5. Documentation and examples for **offline-mode operation**

## Sufficiency Analysis

### Is This Sufficient for Consistent Replay?

✅ **System State Reproduction**: Yes
- Full SystemSnapshot every 5 seconds provides system-wide context
- Process snapshots show active processes and resource usage
- PSI data shows pressure conditions at snapshot time

✅ **Incident Analysis**: Yes  
- Can reproduce conditions leading to circuit breaker triggers
- Shows process hierarchy and resource consumption patterns
- Timestamps allow correlation between events and system state

✅ **Rule Validation**: Yes
- Process events + snapshots provide all data needed for rule evaluation
- Can replay rules against historical data to test thresholds
- Sufficient granularity to detect pattern-based rules

⚠️ **High-Frequency Events**: Partial
- 5-second snapshots might miss very short-lived processes
- Fork bombs might create events between snapshots
- **Mitigation**: Reduce interval to 1-2 seconds for high-activity periods

✅ **Memory Tracking**: Yes  
- Solves RSS tracking gap with periodic snapshots
- Independent of eBPF event frequency
- Shows memory growth trends over time

### Comparison to Full V2 Plan

| Capability | Simple Plan | Full V2 Plan |
|------------|-------------|--------------|
| **Implementation Time** | 3 days | 5 weeks |
| **Storage Overhead** | 360KB/hour | 2-5MB/hour |
| **Development Risk** | Low | Medium |
| **Debugging Ease** | High (JSON) | Medium (Binary) |
| **Performance Impact** | <1% | <2% |
| **Analysis Power** | Good | Excellent |
| **Storage Efficiency** | Good | Excellent |

## Isolated Replay Architecture

### Critical Isolation Guarantees

```rust
// Example: Replay mode configuration
pub struct ReplayConfig {
    pub offline_mode: bool,          // MUST be true for replay
    pub recording_file: PathBuf,     // ONLY data source
    pub disable_probes: bool,        // MUST be true - no eBPF
    pub disable_proc_access: bool,   // MUST be true - no /proc
    pub disable_sys_access: bool,    // MUST be true - no /sys
}

// Example: Safe replay context that prevents live system access
pub struct ReplayContextStore {
    // NO live system access - all data from file
    recorded_entries: Vec<ReplayEntry>,
    current_timestamp: u64,
    replay_mode: bool,  // Always true
}

impl ReplayContextStore {
    // ONLY method to get process data - from recording
    pub fn get_process_data_at(&self, timestamp: u64, pid: u32) -> Option<ProcessData> {
        // Search ONLY in recorded entries - never touch /proc
        self.find_recorded_process_data(timestamp, pid)
    }
    
    // ONLY method to get system metrics - from recording  
    pub fn get_system_metrics_at(&self, timestamp: u64) -> Option<SystemMetrics> {
        // Search ONLY in recorded snapshots - never touch /sys
        self.find_recorded_system_snapshot(timestamp)
    }
    
    // BLOCKED: No live system access allowed
    fn update_from_live_system(&self) -> ! {
        panic!("REPLAY MODE: Live system access is forbidden")
    }
}
```

## Recommendation

**Start with Simple Plan** for these reasons:

1. **Fast Value**: Working solution in days vs weeks
2. **Low Risk**: Minimal code changes, proven format
3. **Complete Isolation**: Zero live system dependencies during replay
4. **Sufficient Coverage**: Addresses 90% of V1 limitations  
5. **Upgrade Path**: Can evolve to full V2 later if needed
6. **Safe Testing**: Can replay on any system without affecting it

The simple JSON-based approach provides sufficient **isolated** replay consistency for:
- Incident reproduction and analysis **from recorded data only**
- Alert rule validation against **historical recorded data**  
- Memory and CPU usage pattern analysis **from snapshots only**
- Process lifecycle investigation **from recorded events only**

**Key Isolation Benefits:**
- **Portable**: Replay recordings on development machines safely
- **Debuggable**: No live system interference during analysis  
- **Reproducible**: Same results every time from same recording
- **Safe**: Cannot accidentally affect running systems during replay

This approach focuses on **practical value delivery with complete safety** over **architectural perfection**, making it ideal for rapid implementation and safe validation.