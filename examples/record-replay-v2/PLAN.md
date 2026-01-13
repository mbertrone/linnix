# Record/Replay V2 Implementation Plan

This document outlines the comprehensive plan for implementing enhanced record/replay capabilities in Linnix that address the limitations of the current eBPF-only approach.

## Current Implementation Analysis

### What Exists (V1)
- **eBPF Event Recording**: Captures process lifecycle events (exec, fork, exit)
- **Event-Driven Architecture**: Records only when eBPF events occur
- **Limited Scope**: Process events only, no system state snapshots

### Key Limitations Identified
1. **No Periodic Data Collection**: Missing RSS/memory tracking, PSI metrics, system snapshots
2. **Activity Threshold Dependency**: RSS updates gated by hardcoded 20 events/sec threshold (`cognitod/src/main.rs:936`)
3. **Incomplete System State**: No /proc data, network stats, disk I/O at recording time
4. **Replay Gaps**: Cannot reproduce system conditions that led to incidents

## Enhanced Record/Replay V2 Architecture

### Core Design Principles
1. **Hybrid Recording**: Event-driven + periodic snapshots
2. **Complete System State**: Include all telemetry available during live operation
3. **Configurable Granularity**: Adjustable snapshot intervals
4. **Backward Compatibility**: Extend existing format, don't break V1
5. **Storage Efficiency**: Compress periodic data, delta encoding

### Recording Architecture

#### 1. Event Stream (Existing + Enhanced)
```rust
// Extend existing ProcessEvent with enhanced context
pub struct ProcessEventV2 {
    // Existing fields...
    pub event: ProcessEvent,
    
    // New contextual data
    pub system_snapshot_id: Option<u64>,    // Link to nearest snapshot
    pub memory_stats: Option<ProcessMemoryStats>,
    pub cpu_stats: Option<ProcessCpuStats>,
    pub timestamp_ns: u64,                  // High precision timestamp
}

pub struct ProcessMemoryStats {
    pub rss_bytes: u64,
    pub vms_bytes: u64,
    pub shared_bytes: u64,
    pub pss_bytes: Option<u64>,    // Proportional Set Size if available
}

pub struct ProcessCpuStats {
    pub cpu_percent: f32,
    pub cpu_time_user: u64,
    pub cpu_time_system: u64,
}
```

#### 2. Periodic System Snapshots (New)
```rust
pub struct SystemSnapshotV2 {
    pub id: u64,                           // Unique snapshot ID
    pub timestamp_ns: u64,                 // High precision timestamp
    
    // System-wide metrics (existing SystemSnapshot + enhanced)
    pub cpu: CpuSnapshot,
    pub memory: MemorySnapshot,
    pub psi: PsiSnapshot,
    pub network: NetworkSnapshot,
    pub disk: DiskSnapshot,
    pub load: LoadSnapshot,
    
    // Process table snapshot
    pub processes: Vec<ProcessSnapshotEntry>,
    
    // Additional context
    pub active_alerts: Vec<String>,        // Active alert rules
    pub enforcement_queue_size: usize,     // Pending actions
}

pub struct ProcessSnapshotEntry {
    pub pid: u32,
    pub ppid: u32,
    pub comm: String,
    pub state: char,                       // R, S, D, Z, etc.
    pub cpu_percent: f32,
    pub memory_rss: u64,
    pub memory_vms: u64,
    pub fd_count: Option<u32>,
    pub threads: Option<u32>,
    pub start_time: Option<u64>,
}
```

#### 3. Recording Configuration
```rust
pub struct RecordingConfigV2 {
    // Event recording (existing)
    pub events_enabled: bool,
    
    // Snapshot recording (new)
    pub snapshots_enabled: bool,
    pub snapshot_interval_ms: u64,         // Default: 1000ms
    pub snapshot_process_threshold: usize, // Only snapshot if > N processes
    
    // Storage optimization
    pub compression_enabled: bool,          // Compress snapshots
    pub delta_encoding: bool,              // Store deltas between snapshots
    pub max_recording_duration_sec: u64,   // Automatic rotation
    
    // Filtering
    pub process_filter: Option<ProcessFilter>,
    pub exclude_kernel_threads: bool,
    pub min_cpu_threshold: f32,            // Only record processes above threshold
    pub min_memory_threshold_mb: u64,
}
```

### Storage Format V2

#### 1. File Structure
```
recording_v2.bin:
├── Header (magic, version, config)
├── Event Stream (chronologically ordered)
│   ├── ProcessEventV2 entries
│   └── SystemSnapshotV2 entries
├── Index (for efficient seeking)
│   ├── Snapshot timestamps -> file offsets
│   └── Process PID -> event ranges
└── Footer (checksum, stats)
```

#### 2. Serialization Format
```rust
// Use efficient binary format with optional compression
pub enum RecordingEntry {
    ProcessEvent {
        timestamp_ns: u64,
        event: ProcessEventV2,
    },
    SystemSnapshot {
        timestamp_ns: u64,
        snapshot: SystemSnapshotV2,
    },
    Delta {
        timestamp_ns: u64,
        base_snapshot_id: u64,
        delta: SystemSnapshotDelta,
    },
}
```

### Implementation Plan

#### Phase 1: Core Infrastructure (Week 1-2)
1. **Data Structures**:
   - Implement `ProcessEventV2` and `SystemSnapshotV2`
   - Create `RecordingConfigV2` with backward compatibility
   - Location: `cognitod/src/recording/types_v2.rs`

2. **Storage Engine**:
   - Binary serialization with serde + bincode
   - Optional zstd compression
   - Index generation for efficient seeking
   - Location: `cognitod/src/recording/storage_v2.rs`

3. **Configuration Integration**:
   - Extend existing config with V2 options
   - Maintain backward compatibility with V1
   - Location: `cognitod/src/config.rs`

#### Phase 2: Recording Implementation (Week 2-3)
1. **Periodic Snapshot Collection**:
   ```rust
   // New background task in main.rs
   async fn periodic_snapshot_collector(
       ctx: Arc<ContextStore>,
       recorder: Arc<RecorderV2>,
       config: RecordingConfigV2,
   ) {
       let mut interval = tokio::time::interval(
           Duration::from_millis(config.snapshot_interval_ms)
       );
       
       loop {
           interval.tick().await;
           
           if recorder.is_recording() {
               let snapshot = collect_system_snapshot_v2(&ctx).await;
               recorder.record_snapshot(snapshot).await;
           }
       }
   }
   ```
   - Location: `cognitod/src/main.rs:1200+`

2. **Enhanced Event Recording**:
   ```rust
   // Enhance existing event handler
   impl Handler for RecorderV2 {
       async fn on_event(&self, event: &ProcessEvent) {
           if !self.config.events_enabled {
               return;
           }
           
           let enhanced_event = ProcessEventV2 {
               event: event.clone(),
               system_snapshot_id: self.get_nearest_snapshot_id(),
               memory_stats: self.collect_process_memory(event.pid).await,
               cpu_stats: self.collect_process_cpu(event.pid).await,
               timestamp_ns: precise_timestamp(),
           };
           
           self.record_event(enhanced_event).await;
       }
   }
   ```
   - Location: `cognitod/src/recording/recorder_v2.rs`

3. **Integration with Existing Systems**:
   - Hook into `ContextStore::update_process_stats()` 
   - Remove/configure hardcoded activity threshold at `cognitod/src/main.rs:936`
   - Location: `cognitod/src/context.rs:324+`

#### Phase 3: Replay Engine (Week 3-4)
1. **Replay Infrastructure**:
   ```rust
   pub struct ReplayEngineV2 {
       recording: RecordingV2,
       current_time: u64,
       event_index: usize,
       snapshot_index: usize,
       replay_speed: f64,  // 1.0 = real-time, 2.0 = 2x speed
   }
   
   impl ReplayEngineV2 {
       pub async fn step_to_time(&mut self, target_time: u64) -> ReplayState {
           // Efficiently seek to target time using index
           // Replay events and snapshots chronologically
       }
       
       pub fn get_system_state_at(&self, timestamp: u64) -> SystemSnapshotV2 {
           // Interpolate or return nearest snapshot
       }
       
       pub fn get_process_tree_at(&self, timestamp: u64) -> ProcessTree {
           // Reconstruct process hierarchy at given time
       }
   }
   ```
   - Location: `cognitod/src/replay/engine_v2.rs`

2. **Analysis Tools**:
   ```rust
   pub struct ReplayAnalyzer {
       engine: ReplayEngineV2,
   }
   
   impl ReplayAnalyzer {
       pub fn find_memory_spikes(&self, threshold_mb: u64) -> Vec<MemorySpike> {
           // Analyze recording for memory usage patterns
       }
       
       pub fn trace_incident_buildup(&self, incident_time: u64) -> IncidentTrace {
           // Show system state evolution leading to incident
       }
       
       pub fn validate_alert_rules(&self, rules: &[RuleConfig]) -> RuleValidation {
           // Test rules against historical data
       }
   }
   ```
   - Location: `cognitod/src/replay/analysis.rs`

#### Phase 4: API and CLI Integration (Week 4-5)
1. **Recording API**:
   ```rust
   // New API endpoints
   POST /api/recording/v2/start    - Start enhanced recording
   POST /api/recording/v2/stop     - Stop and finalize recording
   GET  /api/recording/v2/status   - Get recording status and stats
   GET  /api/recording/v2/list     - List available recordings
   ```

2. **Replay API**:
   ```rust
   // New API endpoints
   POST /api/replay/v2/load        - Load recording for replay
   POST /api/replay/v2/seek        - Seek to specific timestamp
   GET  /api/replay/v2/state       - Get current replay state
   GET  /api/replay/v2/analyze     - Run analysis on recording
   ```

3. **CLI Tools**:
   ```bash
   # Enhanced recording control
   cognitod record --v2 --interval 5s --duration 1h --output incident_2024_001.bin
   
   # Replay and analysis
   cognitod replay --file incident_2024_001.bin --analyze
   cognitod replay --file incident_2024_001.bin --time "2024-01-15T14:30:00Z"
   ```

### Integration with Existing Systems

#### 1. RSS Tracking Fix Integration
- **Problem**: Current RSS updates blocked by hardcoded 20 events/sec threshold
- **Solution**: Make activity threshold configurable in V2
- **Location**: `cognitod/src/main.rs:936`
```rust
// Instead of hardcoded threshold
let is_active = eps >= config.recording.activity_threshold; // Configurable
```

#### 2. Incident System Integration
- **Enhancement**: Link incidents to recording segments
- **Benefit**: Automatic replay of conditions leading to incidents
```rust
pub struct IncidentV2 {
    // Existing fields...
    pub recording_segment: Option<RecordingSegment>,
    pub replay_url: Option<String>,  // API endpoint to replay incident
}
```

#### 3. Alert Rule Validation
- **Use Case**: Test new rules against historical recordings
- **Implementation**: Replay engine validates rules without live system impact

### Configuration Examples

#### Production Recording
```toml
[recording_v2]
events_enabled = true
snapshots_enabled = true
snapshot_interval_ms = 5000        # 5 second intervals
compression_enabled = true
delta_encoding = true
max_recording_duration_sec = 3600  # 1 hour auto-rotation

[recording_v2.filter]
exclude_kernel_threads = true
min_cpu_threshold = 1.0            # Only record processes using >1% CPU
min_memory_threshold_mb = 10       # Only record processes using >10MB
```

#### Development/Testing Recording
```toml
[recording_v2]
events_enabled = true
snapshots_enabled = true
snapshot_interval_ms = 1000        # 1 second intervals
compression_enabled = false        # Disable for easier debugging
delta_encoding = false
max_recording_duration_sec = 600   # 10 minute sessions

[recording_v2.filter]
exclude_kernel_threads = false     # Include all for testing
min_cpu_threshold = 0.1
min_memory_threshold_mb = 1
```

### Storage Considerations

#### 1. Storage Requirements
- **Event Stream**: ~1MB/hour for typical workload
- **System Snapshots**: ~500KB per snapshot (1MB/hour at 5s intervals)
- **Compression**: 60-80% reduction with zstd
- **Total**: ~2-5MB/hour compressed for production workload

#### 2. Retention Policies
```rust
pub struct RetentionPolicy {
    pub max_recordings: usize,          // Keep N most recent
    pub max_age_days: u32,             // Delete older than N days
    pub max_size_gb: u64,              // Delete oldest when exceeding size
    pub compress_after_hours: u64,     // Compress recordings after N hours
}
```

### Performance Impact

#### 1. Recording Overhead
- **CPU**: <2% additional overhead for snapshot collection
- **Memory**: ~50MB for recording buffers and index
- **I/O**: Async writes to avoid blocking main threads

#### 2. Optimization Strategies
- **Adaptive Intervals**: Increase snapshot frequency during high activity
- **Smart Filtering**: Automatically exclude idle processes
- **Background Processing**: All recording I/O in separate tasks

### Testing Plan

#### 1. Unit Tests
- Serialization/deserialization of all V2 data structures
- Index generation and seeking accuracy
- Delta encoding correctness
- Compression/decompression integrity

#### 2. Integration Tests
- End-to-end recording and replay
- Backward compatibility with V1 recordings
- Performance benchmarks vs V1
- Memory leak detection during long recordings

#### 3. Validation Scenarios
- **Fork Bomb Recording**: Capture and replay high-frequency process creation
- **Memory Leak Replay**: Reproduce RSS growth patterns
- **CPU Thrashing Analysis**: Validate circuit breaker conditions in replay
- **Incident Reproduction**: Record incident, replay, verify same conditions

### Migration Strategy

#### 1. Backward Compatibility
- V1 recordings remain fully supported
- V2 features opt-in via configuration
- Gradual migration path for existing deployments

#### 2. Feature Flags
```toml
[feature_flags]
recording_v2_enabled = true           # Enable V2 features
recording_v1_deprecated = false      # Still support V1
recording_auto_upgrade = false       # Auto-convert V1 to V2
```

### Success Metrics

#### 1. Functional Metrics
- **Coverage**: 100% of system state captured during recording
- **Accuracy**: Replay reproduces incidents with >95% fidelity
- **Performance**: <5% overhead during recording
- **Storage**: <10MB/hour for typical production workload

#### 2. Operational Metrics
- **Investigation Speed**: 50% reduction in incident analysis time
- **Rule Validation**: 100% of new alert rules tested against historical data
- **System Understanding**: Complete visibility into pre-incident conditions

### Future Enhancements

#### 1. Machine Learning Integration
- **Pattern Recognition**: Automatically detect anomalies in recordings
- **Predictive Analysis**: Identify conditions leading to incidents
- **Rule Generation**: Suggest alert rules based on recorded patterns

#### 2. Distributed Recording
- **Multi-Node Capture**: Synchronized recording across cluster nodes
- **Correlation Analysis**: Cross-node incident correlation
- **Global Replay**: Cluster-wide state reproduction

## Implementation Timeline

| Week | Focus | Deliverables |
|------|-------|-------------|
| 1 | Core Infrastructure | Data structures, storage engine, configuration |
| 2 | Recording System | Periodic snapshots, enhanced events, integration |
| 3 | Replay Engine | Playback infrastructure, analysis tools |
| 4 | API Integration | REST endpoints, real-time streaming |
| 5 | CLI and Testing | Command-line tools, comprehensive testing |

## Risk Mitigation

### Technical Risks
1. **Storage Growth**: Implement aggressive compression and retention policies
2. **Performance Impact**: Extensive benchmarking and optimization
3. **Backward Compatibility**: Comprehensive migration testing

### Operational Risks
1. **Complex Configuration**: Provide sensible defaults and validation
2. **Learning Curve**: Create comprehensive documentation and examples
3. **Production Impact**: Gradual rollout with feature flags

This enhanced record/replay system will provide complete visibility into system behavior, enabling precise incident reproduction, thorough alert rule validation, and comprehensive system analysis capabilities that were missing from the original eBPF-only implementation.