# Alert and Incident Implementation Details

This document provides precise code pointers and implementation details for the alert and incident architecture described in [ALERTS.md](./ALERTS.md).

## Core Data Structures

### Alert System

**Alert Struct Definition:**
- **Location**: `cognitod/src/alerts.rs:59`
```rust
pub struct Alert {
    pub rule: String,      // Rule name that triggered
    pub severity: Severity, // Info, Low, Medium, High  
    pub message: String,   // Human-readable description
    pub host: String,      // Host where alert occurred
}
```

**Severity Enum:**
- **Location**: `cognitod/src/alerts.rs:21-26`
```rust
#[derive(Debug, Clone, Serialize, PartialEq, PartialOrd)]
pub enum Severity {
    Info, Low, Medium, High,
}
```

**Detector Enum (Rule Types):**
- **Location**: `cognitod/src/alerts.rs:83` 
```rust
pub enum Detector {
    ForksPerSec { threshold: u64, duration: u64 },
    ForkBurst { threshold: u64, window_seconds: u64 },
    ExecRate { regex: String, rate_per_min: u64, median_lifetime: u64 },
    ShortJobFlood { threshold: u64, window_seconds: u64 },
    SubtreeCpuPct { threshold: u64, duration: u64 },
    SubtreeRssMb { threshold: u64, duration: u64 },
}
```

**RuleEngine Struct:**
- **Location**: `cognitod/src/alerts.rs:291-303`
```rust
pub struct RuleEngine {
    rules: Vec<Rule>,
    state: Mutex<RuleState>,
    tx: broadcast::Sender<Alert>,    // Alert broadcaster
    alerts_file: String,
    journald: bool,
    host: String,
    // ... timing windows and metrics
}
```

### Incident System

**Incident Struct Definition:**
- **Location**: `cognitod/src/incidents.rs:18-45`
```rust
pub struct Incident {
    pub id: Option<i64>,
    pub timestamp: i64,
    pub event_type: String,    // "circuit_breaker_cpu", "manual_kill", etc.
    
    // Trigger conditions
    pub psi_cpu: f32,
    pub psi_memory: f32,
    pub cpu_percent: f32,
    pub load_avg: String,
    
    // Action taken
    pub action: String,
    pub target_pid: Option<i32>,
    pub target_name: Option<String>,
    
    // Context and analysis
    pub system_snapshot: Option<String>,
    pub llm_analysis: Option<String>,
    pub llm_analyzed_at: Option<i64>,
    
    // Outcome tracking
    pub recovery_time_ms: Option<i64>,
    pub psi_after: Option<f32>,
}
```

**IncidentStore (SQLite Database):**
- **Location**: `cognitod/src/incidents.rs:58`
- **Database Operations**: `cognitod/src/incidents.rs:60-445`

### Enforcement System

**EnforcementAction Struct:**
- **Location**: `cognitod/src/enforcement.rs:26-40`
```rust
pub struct EnforcementAction {
    pub id: String,
    pub action: ActionType,
    pub reason: String,
    pub source: String,
    pub confidence: Option<f64>,
    pub status: ActionStatus,  // Pending, Approved, Rejected, Executed
    pub created_at: u64,
    pub expires_at: u64,
}
```

**ActionType Enum:**
- **Location**: `cognitod/src/enforcement.rs:11-13`
```rust
pub enum ActionType {
    KillProcess { pid: u32, signal: i32 },
}
```

**EnforcementQueue:**
- **Location**: `cognitod/src/enforcement.rs:42-46`
- **Safety Implementation**: `cognitod/src/enforcement/safety.rs`

## Alert Generation Flow

### Rule Engine Initialization

**Main Function Registration:**
- **Location**: `cognitod/src/main.rs:651-705`
- **CLI Path**: `cognitod/src/main.rs:658-677`
- **Config Path**: `cognitod/src/main.rs:681-705`

```rust
// Line 651: Alert broadcaster initialization
let mut alert_tx = None;

// Line 666: Get broadcaster from RuleEngine
let broadcaster = engine.broadcaster();

// Line 672: Store broadcaster for notifications
alert_tx = Some(broadcaster);
```

**RuleEngine Creation:**
- **Location**: `cognitod/src/alerts.rs:306-386`
- **Broadcaster Setup**: `cognitod/src/alerts.rs:308` 
```rust
let (tx, _) = broadcast::channel(1024);
```

**Broadcaster Method:**
- **Location**: `cognitod/src/alerts.rs:388-390`
```rust
pub fn broadcaster(&self) -> broadcast::Sender<Alert> {
    self.tx.clone()
}
```

### Event Processing

**Handler Registration:**
- **Location**: `cognitod/src/main.rs:673` and `698`
```rust
handler_list.register(engine);
```

**Event Processing (on_event):**
- **Location**: `cognitod/src/alerts.rs:444-580`
- **Detector Logic**: `cognitod/src/alerts.rs:472-578` (each detector type)

**Alert Emission:**
- **Location**: `cognitod/src/alerts.rs:411-442`
```rust
// Line 429: Create alert
let alert = Alert { rule: name.clone(), severity, message, host: self.host.clone() };

// Line 441: Broadcast alert  
let _ = self.tx.send(alert);
```

## Alert Broadcasting and Notifications

### Notification Subscribers

**Slack Notifications:**
- **Location**: `cognitod/src/main.rs:825-859`
- **Implementation**: `cognitod/src/notifications/slack.rs`

```rust
// Line 837: Subscribe to alerts
let notifier_alerts = SlackNotifier::new(slack_cfg.clone(), tx.subscribe());

// Line 838: Spawn notification task
tokio::spawn(async move { notifier_alerts.run().await; });
```

**Apprise Notifications:**
- **Location**: `cognitod/src/main.rs:777-799`
- **Implementation**: `cognitod/src/notifications/apprise.rs`

**Incident Context Logging:**
- **Location**: `cognitod/src/main.rs:707-775`
```rust
// Line 708: Subscribe to alert stream for incident context
if let Some(sender) = alert_tx.clone() {
    let mut rx = sender.subscribe();
    
    // Line 740: Write to incident context file
    let line = alert.incident_context_line();
}
```

**API Event Streaming:**
- **Location**: `cognitod/src/api/mod.rs:1605` (AppState)
- **Stream Endpoint**: `cognitod/src/api/mod.rs:694-785`

### API Integration

**AppState Structure:**
- **Location**: `cognitod/src/api/mod.rs:1602-1618`
```rust
pub struct AppState {
    pub alerts: Option<broadcast::Sender<Alert>>,  // Line 1605
    pub incident_store: Option<Arc<IncidentStore>>, // Line 1615
    pub enforcement: Option<Arc<EnforcementQueue>>, // Line 1614
    // ...
}
```

## Incident Creation Flow

### Circuit Breaker Implementation

**Main Circuit Breaker Loop:**
- **Location**: `cognitod/src/main.rs:946-1114`
- **Configuration**: `cognitod/src/config.rs:328-390`

**Key Implementation Points:**

1. **Threshold Monitoring** (`cognitod/src/main.rs:978-980`):
```rust
let is_breaching = snapshot.cpu_percent > cb_cfg.cpu_usage_threshold
    && snapshot.psi_cpu_some_avg10 > cb_cfg.cpu_psi_threshold;
```

2. **Grace Period Tracking** (`cognitod/src/main.rs:982-1001`):
```rust
if breach_started_at.is_none() {
    breach_started_at = Some(std::time::Instant::now());
    info!("[circuit_breaker] BREACH DETECTED - CPU={:.1}% PSI={:.1}% - grace period started", ...);
}
```

3. **Enforcement Action Creation** (`cognitod/src/main.rs:1016-1031`):
```rust
queue_clone.propose_auto(
    enforcement::ActionType::KillProcess { pid: proc.pid, signal: 9 },
    reason.clone(),
    "circuit_breaker".to_string(),
    None,
    !cb_cfg.require_human_approval  // Auto-approve flag
).await
```

4. **Incident Record Creation** (`cognitod/src/main.rs:1040-1062`):
```rust
let incident = cognitod::Incident {
    id: None,
    timestamp: chrono::Utc::now().timestamp(),
    event_type: "circuit_breaker_cpu".to_string(),  // Line 1043
    psi_cpu: snapshot.psi_cpu_some_avg10,
    // ... full system state
};
```

5. **Incident Storage** (`cognitod/src/main.rs:1067-1093`):
```rust
if let Ok(id) = store_clone.insert(&incident).await {
    info!("[circuit_breaker] Incident #{} recorded", id);
    
    // Trigger LLM analysis
    if let Some(analyzer) = analyzer_clone {
        match analyzer.analyze(&incident).await {
            Ok(analysis) => store_clone.add_llm_analysis(id, analysis).await,
        }
    }
}
```

### Enforcement Execution

**Enforcement Queue Processing:**
- **Location**: `cognitod/src/main.rs:1149-1170`

**Action Execution:**
- **Location**: `cognitod/src/main.rs:1156-1164`
```rust
for action in queue_clone.get_all().await {
    if action.status == ActionStatus::Approved {
        match action.action {
            ActionType::KillProcess { pid, signal } => {
                info!("[enforcement] EXECUTING KILL pid={} signal={}", pid, signal);
                unsafe { libc::kill(pid as i32, signal); }  // Line 1160
                let _ = queue_clone.complete(&action.id).await;
            }
        }
    }
}
```

## Database Schema and Storage

### Incident Database

**Initialization:**
- **Location**: `cognitod/src/main.rs:553-610`
- **Default Path**: `/var/lib/linnix/incidents.db` (Line 555)
- **Environment Override**: `LINNIX_INCIDENT_DB`

**SQLite Schema:**
- **Location**: `cognitod/src/incidents.rs:102-135`
```sql
CREATE TABLE IF NOT EXISTS incidents (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL,
    event_type TEXT NOT NULL,
    psi_cpu REAL NOT NULL,
    -- ... full schema
)
```

**Database Operations:**
- **Insert**: `cognitod/src/incidents.rs:137-174`
- **Query**: `cognitod/src/incidents.rs:176-258`
- **LLM Analysis**: `cognitod/src/incidents.rs:281-318`

## Configuration Integration

### Alert Rules Configuration

**Rules File Loading:**
- **Location**: `cognitod/src/alerts.rs:306-340`
- **YAML Parsing**: `cognitod/src/alerts.rs:153-250`

**Configuration Structure:**
```yaml
# Example: cognitod-staging-pod.yaml:76-102
- name: memory_leak_demo
  detector: subtree_rss_mb
  threshold: 50
  duration: 2
  severity: high
  cooldown: 30
```

### Circuit Breaker Configuration

**Config Struct:**
- **Location**: `cognitod/src/config.rs:325-344`
```rust
pub struct CircuitBreakerConfig {
    pub enabled: bool,                    // Line 328
    pub mode: String,                     // Line 330
    pub cpu_usage_threshold: f32,         // Line 332
    pub cpu_psi_threshold: f32,           // Line 335
    pub grace_period_secs: u64,           // Line 340
    pub require_human_approval: bool,     // Line 342
}
```

**Default Values:**
- **Location**: `cognitod/src/config.rs:383-414`

### Notification Configuration

**Slack Config:**
- **Location**: `cognitod/src/config.rs:43-51`

**Apprise Config:**
- **Location**: `cognitod/src/config.rs:36-41`

## LLM Analysis Integration

### Incident Analysis

**Analyzer Struct:**
- **Location**: `cognitod/src/incidents/analyzer.rs:34`

**Analysis Trigger:**
- **Location**: `cognitod/src/main.rs:1074-1091`
```rust
if let Some(analyzer) = analyzer_clone {
    tokio::spawn(async move {
        match analyzer.analyze(&incident).await {
            Ok(analysis) => {
                let _ = store_clone.add_llm_analysis(id, analysis).await;
            }
        }
    });
}
```

**Analysis Storage:**
- **Location**: `cognitod/src/incidents.rs:281-318`

## System Monitoring Integration

### PSI Data Collection

**PSI Reading:**
- **Location**: `cognitod/src/utils/psi.rs` (referenced in logs)
- **Usage in Circuit Breaker**: `cognitod/src/main.rs:978-1010`

### System Snapshots

**Snapshot Structure:**
- **Location**: `cognitod/src/types.rs:17-31`

**Snapshot Updates:**
- **Location**: `cognitod/src/main.rs:905-925` (periodic task)
- **Update Method**: `cognitod/src/context.rs:update_system_snapshot` method

### Process Statistics

**RSS Tracking Issue Location:**
- **Periodic Updates**: `cognitod/src/main.rs:928-943`
- **Activity Threshold Gate**: `cognitod/src/main.rs:936` 
```rust
let is_active = eps >= 20; // Hardcoded default (YAGNI cleanup)
```
- **Update Implementation**: `cognitod/src/context.rs:update_process_stats` method

## API Endpoints

### Alert Endpoints

**Alert History:**
- **Structure**: `cognitod/src/api/mod.rs:201-230`
- **Storage**: `cognitod/src/main.rs:1177-1188`

### Incident Endpoints

**Query Endpoint:**
- **Location**: `cognitod/src/api/mod.rs:1759-1885`
- **Implementation**: Uses `IncidentStore.query_incidents()` method

**Stats Endpoint:**
- **Location**: `cognitod/src/api/mod.rs:1887-1903`

### Enforcement Endpoints

**Queue Status:**
- **Location**: `cognitod/src/api/mod.rs:enforcement` endpoints
- **Implementation**: Access `EnforcementQueue` methods

## Key Interaction Points

### Handler System Integration

**Handler Registration:**
- **Location**: `cognitod/src/main.rs:673` and `698`
- **Interface**: `cognitod/src/handler/mod.rs:Handler` trait

**Event Flow:**
1. **eBPF Events** → **HandlerList.on_event()** → **RuleEngine.on_event()** → **Alert Broadcast**
2. **System Snapshots** → **HandlerList.on_snapshot()** → **RuleEngine.on_snapshot()** → **Alert Broadcast**

### Broadcasting Architecture

**ProcessEvent Broadcasting:**
- **Source**: `cognitod/src/context.rs:25` (broadcaster field)
- **Emission**: `cognitod/src/context.rs:117`
- **API Stream**: `cognitod/src/api/mod.rs:698`

**Alert Broadcasting:**  
- **Source**: `cognitod/src/alerts.rs:294` (tx field)
- **Emission**: `cognitod/src/alerts.rs:441`
- **Subscribers**: Slack, Apprise, Incident Context, API

This implementation provides a complete separation of concerns between detection (alerts), persistence (incidents), and action (enforcement), with comprehensive audit trails and configurable safety mechanisms.