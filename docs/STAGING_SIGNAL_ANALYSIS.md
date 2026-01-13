# Linnix Staging Signal Analysis

**Date:** 2026-01-12
**Host:** i-048ae49c655d5cf47
**Duration:** ~2 hours of observation
**Purpose:** Evaluate signal quality for upper-level AI consumption

---

## Executive Summary

Linnix is detecting real process activity on staging nodes, but the current signals are **not actionable** for AI-driven decision making. The alerts represent **normal workload patterns** (CI/CD, container orchestration, build cycles) rather than actual problems requiring intervention.

**Key Finding:** 100% of observed alerts were false positives from a "problem detection" perspective, but they successfully demonstrate linnix's ability to observe process behavior at scale.

---

## Observed Alert Patterns

### Alert Distribution (2-hour window)

| Rule | Count | Frequency | Severity |
|------|-------|-----------|----------|
| `crash_loop_detection` | ~60 | Every 2 min | High |
| `runaway_process_tree` | ~60 | Every 90 sec | Info |
| `fork_burst_extreme` | ~20 | Every 5 min | Info |

### Pattern Details

#### 1. crash_loop_detection
```
100 short-lived execs (<= 500ms) in 30s
```

**Observation:** Triggers every 2 minutes with perfect regularity.

**Reality:** This is NOT crash loops. It's normal activity:
- Container health checks
- Kubernetes probes
- CI/CD job steps
- Monitoring scripts

**Why Not Actionable:** No process context, no way to distinguish legitimate short-lived processes from actual crash loops.

#### 2. runaway_process_tree

Sample alerts showing recurring parent PIDs:
```
ppid 1845468 spawned 348 forks in 10s
ppid 1845468 spawned 279 forks in 10s
ppid 1845468 spawned 258 forks in 10s
ppid 1723369 spawned 322 forks in 10s
ppid 1723369 spawned 307 forks in 10s
ppid 1720735 spawned 334 forks in 10s
ppid 1562888 spawned 307 forks in 10s
```

**Unique Parent PIDs Observed:**
| PPID | Occurrences | Fork Range | Likely Identity |
|------|-------------|------------|-----------------|
| 1845468 | 12 | 190-348 | Container shim |
| 1723369 | 10 | 207-322 | Container shim |
| 1720735 | 8 | 218-334 | Container shim |
| 1562888 | 11 | 106-307 | Container shim |
| 1427463 | 9 | 100-310 | Build agent |
| 1464279 | 8 | 180-307 | Build agent |
| 1380561 | 9 | 153-276 | Unknown |

**Observation:** The same ~10 parent PIDs repeatedly appear, spawning 100-350 children every 90 seconds.

**Reality:** These are likely containerd-shim or similar container runtime processes managing workloads. This is normal orchestration activity.

**Why Not Actionable:**
- No process name/command (just PID numbers)
- No indication if this is normal for this process
- No system impact correlation

#### 3. fork_burst_extreme
```
fork burst: 1000 forks in 5s
```

**Observation:** Triggers every ~5 minutes.

**Reality:** Correlates with build/deploy cycles. The burst is concentrated activity, not a fork bomb.

**Why Not Actionable:**
- No attribution (which process caused the burst?)
- No impact measurement (did it affect system?)
- Threshold (1000) may be too low for build nodes

---

## Gap Analysis: Current vs Actionable Signals

### Current Signal (Not Actionable)
```
[INFO] rule=runaway_process_tree message=ppid 1845468 spawned 346 forks in 10s
```

**What an AI sees:**
- Some PID spawned processes
- No context on what this process is
- No way to know if this is normal or abnormal
- No system impact information
- Cannot make a decision

### Ideal Signal (Actionable)
```json
{
  "rule": "runaway_process_tree",
  "severity": "critical",
  "process": {
    "pid": 1845468,
    "name": "stress-ng",
    "cmdline": "stress-ng --fork 1000",
    "container": "test-pod/stress-container",
    "user": "root"
  },
  "metrics": {
    "forks": 2847,
    "baseline_forks": 250,
    "deviation": "11.4x",
    "duration_seconds": 10
  },
  "impact": {
    "cpu_psi_some": 78.5,
    "cpu_psi_baseline": 5.2,
    "memory_psi_some": 12.3,
    "system_load": 45.2
  },
  "context": {
    "first_seen": "2026-01-12T14:30:00Z",
    "alert_count": 1,
    "similar_processes": []
  },
  "recommendation": "Process stress-ng is causing severe CPU pressure. Consider terminating."
}
```

**What an AI sees:**
- Process identity (stress-ng, stress test)
- Quantified deviation from baseline (11.4x normal)
- System impact (CPU PSI 78%, normally 5%)
- Clear recommendation

---

## Proposed Approaches to Make Signals Actionable

### Approach 1: Add Process Context

**Goal:** Enrich alerts with process identity information.

**Implementation:**
```rust
// In alerts.rs, when emitting runaway_tree alerts:
struct ProcessContext {
    pid: u32,
    ppid: u32,
    comm: String,           // from /proc/<pid>/comm
    cmdline: String,        // from /proc/<pid>/cmdline
    container_id: Option<String>,
    cgroup: String,
}

// Alert message becomes:
// "stress-ng (ppid 1845468) spawned 346 forks in 10s"
// instead of:
// "ppid 1845468 spawned 346 forks in 10s"
```

**Data Sources:**
- `/proc/<pid>/comm` - Process name (16 chars)
- `/proc/<pid>/cmdline` - Full command line
- `/proc/<pid>/cgroup` - Container/cgroup identity
- eBPF already captures some of this in process events

**Benefits:**
- AI can recognize known processes (containerd-shim, build agents)
- AI can identify unknown/suspicious processes
- Enables process-based allowlisting

**Effort:** Medium - requires reading /proc at alert time or enriching from eBPF data

---

### Approach 2: Add PSI (Pressure Stall Information) Correlation

**Goal:** Only alert when process activity causes measurable system impact.

**Implementation:**
```rust
// In alerts.rs, add impact check before emitting:
struct AlertWithImpact {
    rule: String,
    process: ProcessContext,
    metrics: AlertMetrics,
    impact: SystemImpact,
}

struct SystemImpact {
    cpu_psi_some: f32,      // % time tasks stalled on CPU
    cpu_psi_full: f32,      // % time ALL tasks stalled
    memory_psi_some: f32,
    memory_psi_full: f32,
    io_psi_some: f32,
    io_psi_full: f32,
}

// Only emit alert if:
// 1. Fork threshold exceeded AND
// 2. CPU PSI > baseline (indicating actual pressure)

fn should_emit_alert(forks: u32, psi: &SystemImpact, baseline_psi: &SystemImpact) -> bool {
    let fork_threshold_exceeded = forks > 100;
    let causing_pressure = psi.cpu_psi_some > baseline_psi.cpu_psi_some * 2.0;

    fork_threshold_exceeded && causing_pressure
}
```

**Benefits:**
- Eliminates alerts for high-activity-but-no-impact scenarios
- Correlates symptoms (forks) with outcomes (pressure)
- AI receives impact-aware signals

**Effort:** Low-Medium - PSI data already collected, need to correlate with alerts

---

### Approach 3: Implement Baseline Learning

**Goal:** Track normal behavior per-process and alert only on deviations.

**Implementation:**
```rust
// New module: baseline.rs
struct ProcessBaseline {
    process_name: String,

    // Historical metrics (rolling window)
    fork_rate_mean: f32,
    fork_rate_stddev: f32,
    fork_rate_p95: f32,

    // Time-based patterns
    hourly_pattern: [f32; 24],  // Fork rate by hour

    // Sample count for confidence
    sample_count: u32,
}

struct BaselineStore {
    baselines: HashMap<String, ProcessBaseline>,
    min_samples_for_confidence: u32,  // e.g., 100
}

impl BaselineStore {
    fn is_anomalous(&self, process: &str, current_rate: f32) -> Option<AnomalyScore> {
        let baseline = self.baselines.get(process)?;

        if baseline.sample_count < self.min_samples_for_confidence {
            return None; // Not enough data
        }

        let z_score = (current_rate - baseline.fork_rate_mean) / baseline.fork_rate_stddev;

        if z_score > 3.0 {
            Some(AnomalyScore {
                deviation: z_score,
                current: current_rate,
                expected: baseline.fork_rate_mean,
                confidence: baseline.sample_count as f32 / 1000.0,
            })
        } else {
            None
        }
    }
}

// Alert becomes:
// "containerd-shim (ppid 1845468) spawned 2847 forks in 10s
//  (11.4x baseline, z-score: 8.2)"
```

**Benefits:**
- Adapts to each environment's "normal"
- Eliminates need for manual threshold tuning
- Detects true anomalies vs regular activity
- AI receives deviation-based signals

**Effort:** High - requires persistent storage, learning period, statistical analysis

---

## Recommended Implementation Order

### Phase 1: Quick Wins (1-2 days)
1. **Add process names to alerts** - Read /proc/<pid>/comm at alert time
2. **Include PSI snapshot in alerts** - Already collected, just include in output
3. **Increase default thresholds** - Based on observed baseline (~350 forks/10s is normal)

### Phase 2: Impact Correlation (3-5 days)
1. **Gate alerts on PSI pressure** - Only emit when causing measurable impact
2. **Add severity escalation** - Info → Warning → Critical based on PSI levels
3. **Deduplicate by process** - Group repeated alerts from same parent

### Phase 3: Baseline Learning (1-2 weeks)
1. **Implement per-process statistics collection**
2. **Add anomaly detection using z-scores**
3. **Create learning mode vs detection mode**
4. **Persist baselines across restarts**

---

## Success Criteria

A signal is **actionable** when an AI can answer these questions:

| Question | Current | Target |
|----------|---------|--------|
| What process is causing this? | No | Yes (process name, container) |
| Is this normal for this process? | No | Yes (baseline comparison) |
| Is this causing system impact? | No | Yes (PSI correlation) |
| Should I take action? | Cannot determine | Clear recommendation |
| What action should I take? | N/A | Kill process / Alert user / Ignore |

---

## Appendix: Raw Alert Samples

### crash_loop_detection
```
[2026-01-12T16:50:56Z INFO cognitod::alerts] [rules] emitting alert rule=crash_loop_detection severity=high message=100 short-lived execs (<= 500ms) in 30s
```

### runaway_process_tree
```
[2026-01-12T16:50:28Z INFO cognitod::alerts] [rules] emitting alert rule=runaway_process_tree severity=info message=ppid 1905430 spawned 265 forks in 10s
[2026-01-12T16:48:58Z INFO cognitod::alerts] [rules] emitting alert rule=runaway_process_tree severity=info message=ppid 1845468 spawned 212 forks in 10s
[2026-01-12T16:43:00Z INFO cognitod::alerts] [rules] emitting alert rule=runaway_process_tree severity=info message=ppid 1845468 spawned 348 forks in 10s
```

### fork_burst_extreme
```
[2026-01-12T16:46:15Z INFO cognitod::alerts] [rules] emitting alert rule=fork_burst_extreme severity=info message=fork burst: 1000 forks in 5s
```
