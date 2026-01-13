# Incident Management System

This document provides comprehensive information about Linnix's incident management system, including triggering conditions, configuration options, and operational modes.

## Overview

The incident system provides persistent records of system interventions and critical events. Unlike alerts (which are ephemeral notifications), incidents are stored in a SQLite database with full context, system state, and automated analysis.

## Incident Structure

### Core Fields

```rust
pub struct Incident {
    pub id: Option<i64>,           // Auto-generated database ID
    pub timestamp: i64,            // Unix epoch timestamp
    pub event_type: String,        // Type of incident (see below)
    
    // Trigger conditions (system state at time of incident)
    pub psi_cpu: f32,             // CPU pressure (0-100%)
    pub psi_memory: f32,          // Memory pressure (0-100%) 
    pub cpu_percent: f32,         // CPU usage (0-100%)
    pub load_avg: String,         // "1min,5min,15min" load averages
    
    // Action taken
    pub action: String,           // "auto_kill", "manual_kill", "alert", etc.
    pub target_pid: Option<i32>,  // Process ID targeted (if applicable)
    pub target_name: Option<String>, // Process name targeted (if applicable)
    
    // Context and analysis
    pub system_snapshot: Option<String>, // Full SystemSnapshot as JSON
    pub llm_analysis: Option<String>,    // AI analysis of incident
    pub llm_analyzed_at: Option<i64>,    // When analysis was completed
    
    // Outcome tracking
    pub recovery_time_ms: Option<i64>,   // Time to system recovery
    pub psi_after: Option<f32>,          // PSI level after action
}
```

### Event Types

| Event Type | Source | Description | Action Required |
|------------|--------|-------------|-----------------|
| `circuit_breaker_cpu` | Circuit Breaker | CPU/PSI thresholds exceeded | Process termination |
| `circuit_breaker_memory` | Circuit Breaker | Memory pressure critical | Process termination |
| `circuit_breaker_io` | Circuit Breaker | I/O pressure critical | Process termination |
| `manual_kill` | Human Operator | Manual process termination | Process termination |
| `safety_veto` | Safety System | Action blocked by safety checks | No action taken |
| `enforcement_timeout` | Enforcement Queue | Action expired without approval | No action taken |

## Circuit Breaker Incident Triggering

### Prerequisites

**1. Circuit Breaker Must Be Enabled**
```toml
[circuit_breaker]
enabled = true  # Must be explicitly set
```

**2. Incident Store Must Be Available**
- Database path: `/var/lib/linnix/incidents.db` (default)
- Override with: `LINNIX_INCIDENT_DB` environment variable
- Parent directory must be writable

### Triggering Conditions

**CPU-based Circuit Breaker** (`circuit_breaker_cpu` incidents):

```rust
// All conditions must be true simultaneously
let trigger_conditions = 
    snapshot.cpu_percent > cpu_usage_threshold &&     // CPU usage high
    snapshot.psi_cpu_some_avg10 > cpu_psi_threshold &&  // CPU pressure high  
    sustained_duration >= grace_period_secs;             // Duration exceeded
```

**Default Thresholds**:
- `cpu_usage_threshold`: 90.0% 
- `cpu_psi_threshold`: 50.0%
- `grace_period_secs`: 15 seconds

**Example Triggering Scenario**:
1. System CPU usage rises above 90%
2. CPU pressure (tasks waiting for CPU) exceeds 50%  
3. Both conditions sustained for 15+ seconds
4. Circuit breaker identifies top CPU consumer
5. **Incident created regardless of action outcome**

### Detailed Trigger Algorithm

```rust
// Continuous monitoring loop (every check_interval_secs)
loop {
    let snapshot = get_system_snapshot();
    
    // Check if currently breaching thresholds
    let is_breaching = snapshot.cpu_percent > cpu_usage_threshold
        && snapshot.psi_cpu_some_avg10 > cpu_psi_threshold;
    
    if is_breaching {
        if breach_started_at.is_none() {
            // First detection - start grace period
            breach_started_at = Some(now);
            log!("BREACH DETECTED - grace period started");
        } else {
            // Ongoing breach - check duration
            let duration = now - breach_started_at;
            log!("BREACH SUSTAINED - {duration}s/{grace_period}s");
            
            if duration >= grace_period_secs {
                // Trigger incident creation
                create_incident_and_propose_action();
                breach_started_at = None; // Reset
            }
        }
    } else if breach_started_at.is_some() {
        // Conditions normalized - reset grace period
        log!("conditions normalized - grace period reset");
        breach_started_at = None;
    }
    
    sleep(check_interval_secs);
}
```

## Operational Modes

### Monitor Mode (Safe/Dry-Run Mode)

**Configuration**:
```toml
[circuit_breaker]
enabled = true
mode = "monitor"              # Key setting
require_human_approval = true # Additional safety
```

**Behavior**:
- ✅ **Incidents created** with full telemetry when thresholds breached
- ✅ **System state captured** (CPU, PSI, load, full snapshot)
- ✅ **Target process identified** and recorded  
- ✅ **LLM analysis triggered** asynchronously
- ❌ **No processes killed** - actions require manual approval
- 📝 **Actions logged** to enforcement queue as "pending"

**Use Cases**:
- Production safety (observe without action)
- Threshold tuning and validation
- System behavior analysis
- Testing and development

### Enforce Mode (Active Protection)

**Configuration**:
```toml
[circuit_breaker]
enabled = true
mode = "enforce"                    # Active mode
require_human_approval = false     # Auto-execute (optional)
```

**Behavior**:
- ✅ **Incidents created** with full telemetry
- ✅ **Processes automatically killed** when thresholds breached
- ✅ **Safety checks applied** before execution
- ⚠️ **Safety vetoes possible** (critical process protection)
- 📊 **Recovery metrics tracked** (PSI after action, recovery time)

**Additional Safety**: Set `require_human_approval = true` to force manual approval even in enforce mode.

## Incident Creation Flow

### 1. Threshold Breach Detection
```rust
// main.rs:978-1001
let is_breaching = snapshot.cpu_percent > cb_cfg.cpu_usage_threshold
    && snapshot.psi_cpu_some_avg10 > cb_cfg.cpu_psi_threshold;

if duration >= cb_cfg.grace_period_secs {
    metrics_clone.inc_circuit_breaker_cpu_trip();
    // Proceed to action proposal and incident creation
}
```

### 2. Target Process Identification  
```rust
// main.rs:1005-1015
let mut top_cpu_procs = ctx_clone.top_cpu_processes(1);
if top_cpu_procs.is_empty() {
    top_cpu_procs = ctx_clone.top_cpu_processes_systemwide(1);
}

if let Some(proc) = top_cpu_procs.first() {
    let reason = format!(
        "CPU thrashing sustained {}s: CPU={:.1}% PSI={:.1}%",
        duration, snapshot.cpu_percent, snapshot.psi_cpu_some_avg10
    );
}
```

### 3. Enforcement Action Proposal
```rust
// main.rs:1016-1031
match queue_clone.propose_auto(
    ActionType::KillProcess { pid: proc.pid, signal: 9 },
    reason.clone(),
    "circuit_breaker".to_string(),
    None,
    auto_approve_flag  // Depends on mode and approval settings
).await {
    Ok(_) => {
        // Action successfully proposed/executed
        create_incident_record();
    }
    Err(e) => {
        // Safety veto or other failure
        metrics_clone.inc_circuit_breaker_safety_veto();
        warn!("[circuit_breaker] safety veto: {}", e);
    }
}
```

### 4. Incident Record Creation
```rust
// main.rs:1040-1062 - ALWAYS executed regardless of action outcome
let incident = cognitod::Incident {
    id: None,
    timestamp: chrono::Utc::now().timestamp(),
    event_type: "circuit_breaker_cpu".to_string(),
    
    // System state at trigger time
    psi_cpu: snapshot.psi_cpu_some_avg10,
    psi_memory: snapshot.psi_memory_full_avg10, 
    cpu_percent: snapshot.cpu_percent,
    load_avg: format!("{:.2},{:.2},{:.2}", 
        snapshot.load_avg[0], snapshot.load_avg[1], snapshot.load_avg[2]),
    
    // Action details
    action: "auto_kill".to_string(),
    target_pid: Some(proc.pid as i32),
    target_name: Some(proc.comm.clone()),
    
    // Full context
    system_snapshot: serde_json::to_string(&snapshot).ok(),
    
    // Analysis placeholders (filled asynchronously)
    llm_analysis: None,
    llm_analyzed_at: None,
    recovery_time_ms: None,
    psi_after: None,
};
```

### 5. Database Storage and Analysis
```rust
// main.rs:1067-1093
if let Ok(id) = store_clone.insert(&incident).await {
    info!("[circuit_breaker] Incident #{} recorded", id);
    
    // Trigger asynchronous LLM analysis
    if let Some(analyzer) = analyzer_clone {
        tokio::spawn(async move {
            match analyzer.analyze(&incident).await {
                Ok(analysis) => {
                    let _ = store_clone.add_llm_analysis(id, analysis).await;
                }
                Err(e) => warn!("[incident_analyzer] Failed: {}", e),
            }
        });
    }
}
```

## Database Storage

### Storage Location
- **Default Path**: `/var/lib/linnix/incidents.db`
- **Environment Override**: `LINNIX_INCIDENT_DB`
- **Format**: SQLite database for reliability and queryability

### Schema
```sql
CREATE TABLE IF NOT EXISTS incidents (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL,
    event_type TEXT NOT NULL,
    psi_cpu REAL NOT NULL,
    psi_memory REAL NOT NULL, 
    cpu_percent REAL NOT NULL,
    load_avg TEXT NOT NULL,
    action TEXT NOT NULL,
    target_pid INTEGER,
    target_name TEXT,
    system_snapshot TEXT,
    llm_analysis TEXT,
    llm_analyzed_at INTEGER,
    recovery_time_ms INTEGER,
    psi_after REAL
);
```

### Database Operations
- **Insert**: New incidents stored with auto-incrementing ID
- **Query**: Time-range and event-type filtering
- **Update**: LLM analysis added asynchronously
- **Statistics**: Incident counts and effectiveness metrics

## LLM Analysis Integration

### Automatic Analysis
When incidents are created, an optional LLM analyzer provides:
- **Root cause analysis** based on system state
- **Impact assessment** of the incident
- **Recommendations** for prevention
- **Pattern recognition** across multiple incidents

### Configuration
```toml
[reasoner]
enabled = true                    # Enable LLM analysis
endpoint = "http://llm-service:8080"  # LLM service URL
timeout_ms = 30000               # Analysis timeout
```

### Analysis Storage
- Analysis results stored in `llm_analysis` field
- Timestamp recorded in `llm_analyzed_at`
- Failed analysis attempts logged but don't block incident creation

## Configuration Reference

### Circuit Breaker Configuration

```toml
[circuit_breaker]
# Enable/disable circuit breaker (required)
enabled = true

# Operation mode: "monitor" (safe) or "enforce" (active)
mode = "monitor"

# CPU usage threshold (0-100%)
cpu_usage_threshold = 90.0

# CPU pressure threshold (0-100%) 
cpu_psi_threshold = 40.0

# Memory pressure threshold (0-100%) - future use
memory_psi_full_threshold = 80.0

# I/O pressure threshold (0-100%) - future use  
io_psi_full_threshold = 50.0

# Grace period - conditions must be sustained (seconds)
grace_period_secs = 15

# Check interval (seconds)
check_interval_secs = 5  

# Require manual approval even in enforce mode
require_human_approval = true
```

### Incident Database Configuration

```bash
# Environment variable override
export LINNIX_INCIDENT_DB="/custom/path/incidents.db"

# Default path
/var/lib/linnix/incidents.db
```

## Operational Examples

### Example 1: Monitor Mode Testing
**Configuration**:
```toml
[circuit_breaker]
enabled = true
mode = "monitor"
cpu_usage_threshold = 50.0    # Lower for testing
cpu_psi_threshold = 10.0      # Lower for testing 
grace_period_secs = 5         # Shorter for testing
```

**Expected Behavior**:
1. Generate CPU load above 50% with pressure above 10%
2. Sustain for 5+ seconds
3. Incident created with `event_type: "circuit_breaker_cpu"`
4. No processes killed (monitor mode)
5. Check database: `sqlite3 /var/lib/linnix/incidents.db "SELECT * FROM incidents;"`

### Example 2: Production Enforce Mode
**Configuration**:
```toml
[circuit_breaker]
enabled = true
mode = "enforce"
cpu_usage_threshold = 90.0
cpu_psi_threshold = 50.0
grace_period_secs = 15
require_human_approval = false  # Auto-execute
```

**Expected Behavior**:
1. System under severe load (CPU > 90%, PSI > 50%)
2. Conditions sustained for 15+ seconds
3. Top CPU process automatically killed
4. Incident recorded with full context
5. System recovery tracked

## Monitoring and Alerting

### Metrics
- `circuit_breaker_cpu_trips`: Count of CPU circuit breaker triggers
- `circuit_breaker_safety_vetoes`: Count of safety system blocks
- `incidents_created_total`: Total incidents across all types

### Log Messages
```
[circuit_breaker] BREACH DETECTED - CPU=92.5% PSI=65.2% - grace period started
[circuit_breaker] BREACH SUSTAINED - CPU=93.1% PSI=67.8% - 10s/15s  
[circuit_breaker] AUTO-KILLED python3(12345): CPU thrashing sustained 15s: CPU=93.1% PSI=67.8%
[circuit_breaker] Incident #42 recorded
[circuit_breaker] safety veto: Cannot kill critical system process
```

### API Endpoints
- `GET /api/incidents` - Query incidents with filters
- `GET /api/incidents/stats` - Incident statistics and effectiveness
- `GET /api/enforcement/queue` - Current enforcement actions

## Safety Considerations

### Built-in Protections
1. **Grace Period**: Prevents action on transient spikes
2. **Safety Checks**: Critical process protection
3. **Monitor Mode**: Safe observation without action
4. **Manual Approval**: Human oversight option
5. **Rate Limiting**: Prevents kill storms

### Best Practices
- Start with **monitor mode** in production
- Use **lower thresholds** for testing
- Monitor **safety veto metrics** for tuning
- Review **incident patterns** for system optimization
- Enable **LLM analysis** for insights

### Recovery Tracking
Future incidents will include:
- Time to PSI normalization after action
- System stability post-incident
- Action effectiveness metrics

This incident system provides comprehensive protection with full auditability and safety controls for production environments.

## Integration with Alerts

See [ALERTS.md](./ALERTS.md) for the relationship between:
- **Alerts**: Rule-based notifications for detection
- **Incidents**: Action-based records for intervention
- **Circuit Breaker**: System protection independent of alert rules

The systems work together to provide both awareness (alerts) and protection (incidents) with complete traceability.