# Linnix Rules and Detection System

This document provides a comprehensive reference for all detection rules in Linnix, including both alert rules (rule-based detection) and incident conditions (circuit breaker protection).

## Rule Types Overview

Linnix has two distinct detection systems:

1. **Alert Rules** - Configurable rules that detect patterns in eBPF events and generate alerts
2. **Incident Conditions** - Built-in circuit breaker logic that creates incidents and takes protective actions

## Alert Rules (Rule-Based Detection)

Alert rules are configured via `rules.yaml` and detect specific patterns in process events. They generate alerts but do not take any enforcement actions.

### Available Alert Detectors

#### 1. ForksPerSec
- **Purpose**: Detects sustained high fork rates that may indicate fork bombs
- **Trigger Condition**: Fork rate exceeds threshold for sustained duration
- **Parameters**:
  - `threshold`: Forks per second (u64)
  - `duration`: Sustained duration in seconds (u64)
- **Implementation**: Tracks fork events over sliding window

#### 2. ForkBurst  
- **Purpose**: Detects burst fork activity within short time windows
- **Trigger Condition**: Total forks exceed threshold within time window
- **Parameters**:
  - `threshold`: Total fork count (u64)
  - `window_seconds`: Time window in seconds (u64)
- **Implementation**: Counts forks in fixed time window

#### 3. ExecRate
- **Purpose**: Detects high execution rates for specific process patterns
- **Trigger Condition**: Processes matching regex execute at high rate
- **Parameters**:
  - `regex`: Process name pattern (String)
  - `rate_per_min`: Executions per minute threshold (u64)
  - `median_lifetime`: Expected process lifetime (u64)
- **Status**: Available but not actively used (dead_code)

#### 4. ShortJobFlood
- **Purpose**: Detects floods of short-lived processes
- **Trigger Condition**: High count of short-duration processes in window
- **Parameters**:
  - `threshold`: Process count threshold (u64)
  - `window_seconds`: Time window in seconds (u64)
  - `max_exec_duration_ms`: Maximum execution time to qualify as "short" (u64)
- **Implementation**: Tracks process completion times

#### 5. RunawayTree
- **Purpose**: Detects process tree explosion (runaway fork cascades)
- **Trigger Condition**: High fork activity from single process tree
- **Parameters**:
  - `threshold`: Fork threshold from single tree (u64)
  - `window_seconds`: Time window in seconds (u64)
- **Implementation**: Groups forks by parent process

#### 6. SubtreeCpuPct
- **Purpose**: Detects high CPU usage by process subtrees
- **Trigger Condition**: CPU percentage exceeds threshold for duration
- **Parameters**:
  - `threshold`: CPU percentage threshold (f32)
  - `duration`: Sustained duration in seconds (u64)
- **Implementation**: Monitors per-process CPU usage from eBPF telemetry

#### 7. SubtreeRssMb
- **Purpose**: Detects high memory usage by process subtrees
- **Trigger Condition**: RSS memory exceeds threshold for duration
- **Parameters**:
  - `threshold`: Memory threshold in MB (u64)
  - `duration`: Sustained duration in seconds (u64)
- **Implementation**: Monitors per-process RSS from eBPF telemetry
- **Known Issue**: Currently affected by hardcoded activity threshold (20 events/sec)

#### 8. ZombieCount
- **Purpose**: Detects accumulation of zombie processes
- **Trigger Condition**: Zombie process count exceeds threshold
- **Parameters**:
  - `threshold`: Zombie count threshold (u64)
  - `duration`: Sustained duration in seconds (u64)
- **Status**: Available but not actively used (dead_code)

## Incident Conditions (Circuit Breaker Protection)

Circuit breaker conditions are built into the system and automatically trigger incidents with potential enforcement actions.

### CPU Circuit Breaker (circuit_breaker_cpu)
- **Purpose**: Protect system from CPU thrashing by killing high-CPU processes
- **Trigger Condition**: BOTH conditions sustained for grace period:
  - `cpu_usage_threshold`: System CPU usage > threshold (default: 90%)
  - `cpu_psi_threshold`: CPU pressure stall > threshold (default: 40%)
- **Grace Period**: `grace_period_secs` (default: 15 seconds)
- **Action**: Kill highest CPU consuming process
- **Configuration Location**: `[circuit_breaker]` section in config
- **Safety**: Monitor mode by default, requires explicit enable for enforcement

### Memory Circuit Breaker (circuit_breaker_memory)
- **Purpose**: Protect system from memory exhaustion
- **Trigger Condition**: Memory pressure stall exceeds threshold
- **Parameters**:
  - `memory_psi_full_threshold`: Memory PSI full percentage (default: 80%)
- **Status**: Framework exists, implementation pending
- **Action**: Kill highest memory consuming process

### I/O Circuit Breaker (circuit_breaker_io)  
- **Purpose**: Detect I/O pressure issues
- **Trigger Condition**: I/O pressure stall exceeds threshold
- **Parameters**:
  - `io_psi_full_threshold`: I/O PSI full percentage (default: 50%)
- **Status**: Detection only, no enforcement action planned
- **Action**: Alert/incident creation only

## Rule Configuration Examples

### Alert Rules Configuration (rules.yaml)

```yaml
# Fork bomb detection
- name: fork_storm_demo
  detector: forks_per_sec
  threshold: 10      # forks per second
  duration: 2        # sustained for 2 seconds
  severity: high
  cooldown: 30

# Burst fork activity
- name: fork_burst_demo
  detector: fork_burst
  threshold: 30      # total forks
  window_seconds: 5  # within 5 second window
  severity: medium
  cooldown: 30

# Memory usage monitoring (note: affected by activity threshold bug)
- name: memory_leak_demo
  detector: subtree_rss_mb
  threshold: 50      # MB total RSS
  duration: 2        # sustained for 2 seconds
  severity: high
  cooldown: 30

# CPU usage monitoring
- name: cpu_spike_demo
  detector: subtree_cpu_pct
  threshold: 50      # percent CPU
  duration: 5        # sustained for 5 seconds
  severity: medium
  cooldown: 30

# Short-lived process flood
- name: process_flood_demo
  detector: short_job_flood
  threshold: 20           # process count
  window_seconds: 10      # within 10 seconds
  max_exec_duration_ms: 1000  # processes lasting < 1 second
  severity: high
  cooldown: 60

# Runaway process tree
- name: runaway_tree_demo
  detector: runaway_tree
  threshold: 15       # forks from single tree
  window_seconds: 5   # within 5 seconds
  severity: high
  cooldown: 45
```

### Circuit Breaker Configuration (linnix.toml)

```toml
[circuit_breaker]
# Enable circuit breaker (required)
enabled = true

# Operation mode: "monitor" (safe) or "enforce" (active protection)
mode = "monitor"

# CPU protection thresholds
cpu_usage_threshold = 90.0    # System CPU usage percentage
cpu_psi_threshold = 40.0      # CPU pressure stall percentage

# Memory protection thresholds (future use)
memory_psi_full_threshold = 80.0  # Memory pressure full stall

# I/O monitoring thresholds (detection only)
io_psi_full_threshold = 50.0     # I/O pressure full stall

# Timing configuration
grace_period_secs = 15        # Conditions must be sustained for this long
check_interval_secs = 5       # How often to check conditions

# Safety controls
require_human_approval = true # Force manual approval even in enforce mode
```

## Rule Examples by Use Case

### Production Safety Configuration
```toml
# Conservative thresholds with manual approval
[circuit_breaker]
enabled = true
mode = "monitor"              # Safe observation only
cpu_usage_threshold = 95.0    # Very high threshold
cpu_psi_threshold = 60.0      # Very high threshold
grace_period_secs = 30        # Long grace period
require_human_approval = true
```

```yaml
# Conservative alert rules
- name: severe_fork_storm
  detector: forks_per_sec
  threshold: 25             # Higher threshold
  duration: 5               # Longer duration
  severity: high
  cooldown: 60

- name: critical_memory_leak  
  detector: subtree_rss_mb
  threshold: 1000           # 1GB threshold
  duration: 10              # 10 second confirmation
  severity: high
  cooldown: 120
```

### Development/Testing Configuration
```toml
# Aggressive thresholds for testing
[circuit_breaker]
enabled = true
mode = "monitor"              # Still safe for dev
cpu_usage_threshold = 50.0    # Lower threshold for testing
cpu_psi_threshold = 10.0      # Lower threshold for testing
grace_period_secs = 5         # Short grace period
require_human_approval = true
```

```yaml
# Sensitive detection for testing
- name: dev_fork_test
  detector: forks_per_sec
  threshold: 5              # Low threshold
  duration: 2               # Quick trigger
  severity: medium
  cooldown: 10              # Short cooldown

- name: dev_cpu_test
  detector: subtree_cpu_pct
  threshold: 25             # 25% CPU threshold
  duration: 3
  severity: medium
  cooldown: 15
```

### High-Load Environment Configuration
```toml
# Tolerant thresholds for high-load systems
[circuit_breaker]
enabled = true
mode = "enforce"              # Active protection
cpu_usage_threshold = 98.0    # Very high tolerance
cpu_psi_threshold = 80.0      # High pressure tolerance
grace_period_secs = 60        # Long grace period
require_human_approval = false # Auto-execute when needed
```

## Complete Rule Reference Table

| Rule Name | Type | Condition Summary | Default Threshold | Action |
|-----------|------|-------------------|------------------|---------|
| **Alert Rules (Configurable)** | | | | |
| forks_per_sec | Alert | Fork rate exceeds threshold for duration | 10 forks/sec for 2s | Alert notification |
| fork_burst | Alert | Total forks exceed threshold in window | 30 forks in 5s | Alert notification |
| exec_rate | Alert | Process execution rate exceeds threshold | N/A (unused) | Alert notification |
| short_job_flood | Alert | Short-lived processes exceed threshold | 20 processes in 10s | Alert notification |
| runaway_tree | Alert | Fork tree explosion detected | 15 forks from tree in 5s | Alert notification |
| subtree_cpu_pct | Alert | Process CPU usage exceeds threshold | 50% for 5s | Alert notification |
| subtree_rss_mb | Alert | Process memory usage exceeds threshold | 50MB for 2s | Alert notification |
| zombie_count | Alert | Zombie process accumulation | N/A (unused) | Alert notification |
| **Incident Conditions (Built-in)** | | | | |
| circuit_breaker_cpu | Incident | CPU usage + pressure sustained | CPU>90% + PSI>40% for 15s | Kill top CPU process |
| circuit_breaker_memory | Incident | Memory pressure critical | PSI>80% (future) | Kill top memory process |
| circuit_breaker_io | Incident | I/O pressure critical | PSI>50% (future) | Incident only (no kill) |
| manual_kill | Incident | Human operator action | Manual trigger | Kill specified process |
| safety_veto | Incident | Action blocked by safety | Auto-triggered | No action taken |
| enforcement_timeout | Incident | Action expired | Timeout reached | No action taken |

## Key Differences: Alerts vs Incidents

| Aspect | Alerts | Incidents |
|--------|--------|-----------|
| **Trigger Source** | Configurable rules in YAML | Built-in circuit breaker logic |
| **Purpose** | Detection and notification | Protection and enforcement |
| **Storage** | Ephemeral (broadcast only) | Persistent (SQLite database) |
| **Actions** | None (notification only) | Process termination possible |
| **Configuration** | `rules.yaml` | `[circuit_breaker]` in config |
| **Safety Mode** | Always safe | Monitor vs enforce modes |
| **System State** | Limited context | Full system snapshot |
| **Analysis** | None | Optional LLM analysis |

## Configuration File Locations

- **Alert Rules**: `/etc/linnix/rules.yaml` (mounted from ConfigMap in K8s)
- **Circuit Breaker**: `/etc/linnix/linnix.toml` (mounted from ConfigMap in K8s)
- **Incident Database**: `/var/lib/linnix/incidents.db` (persistent storage)

## Implementation Notes

### Alert Rule Processing
- Location: `cognitod/src/alerts.rs:564-580`
- Event-driven processing of eBPF events
- Sliding window and burst detection algorithms
- Configurable cooldown periods prevent spam

### Circuit Breaker Processing  
- Location: `cognitod/src/main.rs:946-1114`
- System snapshot-based monitoring every 5 seconds
- Dual-threshold protection (usage + pressure)
- Grace period prevents transient spike reactions

### Known Issues
1. **RSS Tracking**: `subtree_rss_mb` rules affected by hardcoded 20 events/sec activity threshold
2. **Memory Circuit Breaker**: Framework exists but implementation incomplete
3. **I/O Circuit Breaker**: Detection only, no enforcement planned

This rules system provides comprehensive process monitoring with both reactive detection (alerts) and proactive protection (incidents), with configurable thresholds for different operational environments.