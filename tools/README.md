# Linnix Tools

Helper utilities and CLI tools for operating and debugging Linnix.

## Overview

This directory contains 16 user-facing utilities that complement the main `linnix-cli` application. These tools provide convenient wrappers, analysis utilities, and operational helpers for working with Linnix.

## Quick Reference

| Tool | Category | Description |
|------|----------|-------------|
| `api_explorer.sh` | Exploration | Interactive API explorer with 26 endpoints |
| `view_incidents.sh` | Incidents | Multi-mode incident viewer (list/detail/watch/json) |
| `system_monitor.sh` | Monitoring | Real-time system dashboard with PSI metrics |
| `psi_tracker.sh` | Analysis | Track PSI trends over time with sparklines |
| `process_tree.sh` | Processes | Interactive process tree explorer |
| `top_offenders.sh` | Analysis | Find resource hogs and noisy neighbors |
| `process_watcher.sh` | Monitoring | Stream live process events (fork/exec/exit) |
| `incident_report.sh` | Reports | Generate formatted incident reports |
| `incident_timeline.sh` | Analysis | Visualize incident history and patterns |
| `psi_incident_correlation.sh` | Analysis | Correlate PSI with incident patterns |
| `action_manager.sh` | Actions | Manage pending actions interactively |
| `action_audit.sh` | Actions | View action history and outcomes |
| `metrics_export.sh` | Integration | Export metrics (Prometheus/JSON/InfluxDB/CSV) |
| `health_check.sh` | Diagnostics | Comprehensive system health checker |
| `attribution_report.sh` | K8s | PSI attribution analysis for pods |
| `alert_watcher.sh` | Monitoring | Live alert monitoring with filtering |

## Available Tools

### 🔍 Exploration Tools

#### `api_explorer.sh`
Interactive API explorer for discovering and testing Linnix APIs.

**Usage:**
```bash
./tools/api_explorer.sh list                    # List all categories
./tools/api_explorer.sh list "System & Status"  # List endpoints in category
./tools/api_explorer.sh search incident         # Search for endpoints
./tools/api_explorer.sh test status             # Test an endpoint
./tools/api_explorer.sh interactive             # Interactive mode
```

### 🚨 Incident Management

#### `view_incidents.sh`
Multi-mode incident viewer with table, detail, real-time, and JSON output.

**Usage:**
```bash
./tools/view_incidents.sh list                  # Table view
./tools/view_incidents.sh detail                # Detailed view
./tools/view_incidents.sh watch                 # Real-time stream
./tools/view_incidents.sh json                  # All incidents as JSON
./tools/view_incidents.sh json 5                # First 5 incidents
./tools/view_incidents.sh json 33               # Incident #33
```

#### `incident_report.sh`
Generate formatted incident reports for analysis and documentation.

**Usage:**
```bash
./tools/incident_report.sh --format txt         # Text format
./tools/incident_report.sh --format md          # Markdown format
./tools/incident_report.sh --format json        # JSON format
./tools/incident_report.sh --format csv         # CSV format
./tools/incident_report.sh --since 24h          # Last 24 hours
```

#### `incident_timeline.sh`
Visualize incident history with ASCII graphs and pattern analysis.

**Usage:**
```bash
./tools/incident_timeline.sh                    # Show timeline and patterns
```

### 📊 Monitoring Tools

#### `system_monitor.sh`
Real-time system dashboard showing CPU, memory, PSI metrics, and top processes.

**Usage:**
```bash
./tools/system_monitor.sh                       # Continuous monitoring
./tools/system_monitor.sh --once                # Single snapshot
REFRESH_INTERVAL=5 ./tools/system_monitor.sh    # Custom refresh rate
```

#### `psi_tracker.sh`
Track Pressure Stall Information trends over time with ASCII sparklines.

**Usage:**
```bash
./tools/psi_tracker.sh                          # Continuous tracking
./tools/psi_tracker.sh --once                   # Single sample
./tools/psi_tracker.sh --samples 60 --interval 1  # 60 samples, 1s interval
```

#### `process_watcher.sh`
Stream live process events (fork/exec/exit) with optional filtering.

**Usage:**
```bash
./tools/process_watcher.sh                      # Watch all events
./tools/process_watcher.sh rust                 # Filter for 'rust'
```

#### `alert_watcher.sh`
Monitor real-time alerts with color-coded severity and filtering.

**Usage:**
```bash
./tools/alert_watcher.sh                        # Watch all alerts
./tools/alert_watcher.sh --filter circuit       # Filter for specific alerts
```

### 🔬 Analysis Tools

#### `top_offenders.sh`
Find resource hogs and noisy neighbors with CPU/memory rankings.

**Usage:**
```bash
./tools/top_offenders.sh                        # Show top offenders
```

#### `psi_incident_correlation.sh`
Analyze correlation between PSI levels and incident patterns.

**Usage:**
```bash
./tools/psi_incident_correlation.sh             # Show PSI-incident correlation
```

#### `attribution_report.sh`
PSI attribution analysis for Kubernetes pods and namespaces.

**Usage:**
```bash
./tools/attribution_report.sh                   # Show PSI contributors
```

### 🌳 Process Tools

#### `process_tree.sh`
Explore process hierarchies and parent-child relationships.

**Usage:**
```bash
./tools/process_tree.sh <pid>                   # Show tree for PID
./tools/process_tree.sh --roots                 # List top-level processes
```

### ⚡ Action Management

#### `action_manager.sh`
Manage pending actions (kill, throttle) interactively.

**Usage:**
```bash
./tools/action_manager.sh list                  # List pending actions
./tools/action_manager.sh approve action-1      # Approve action
./tools/action_manager.sh reject action-1       # Reject action
./tools/action_manager.sh interactive           # Interactive mode
```

#### `action_audit.sh`
View action history, outcomes, and statistics.

**Usage:**
```bash
./tools/action_audit.sh                         # Show action audit log
```

### 🔧 Integration Tools

#### `metrics_export.sh`
Export Linnix metrics in multiple formats for external systems.

**Usage:**
```bash
./tools/metrics_export.sh prometheus            # Prometheus format
./tools/metrics_export.sh json                  # JSON format
./tools/metrics_export.sh influx                # InfluxDB line protocol
./tools/metrics_export.sh csv                   # CSV format
```

#### `health_check.sh`
Comprehensive system health checker for diagnostics.

**Usage:**
```bash
./tools/health_check.sh                         # Run health check
```

## Environment Variables

All tools support these environment variables:

- **`LINNIX_URL`** - Base URL (default: `http://127.0.0.1:3000`)
- **`LINNIX_COLOR`** - Enable colors (default: `true`)

Tool-specific variables:
- **`REFRESH_INTERVAL`** - Refresh rate for monitoring tools (default: `2`)
- **`PSI_SAMPLES`** - Number of samples for PSI tracker (default: `30`)
- **`PSI_INTERVAL`** - Sampling interval for PSI tracker (default: `2`)
- **`ALERT_FILTER`** - Default filter for alert watcher

## Directory Purpose

**`tools/`** vs **`scripts/`** vs **`linnix-cli/`**:

- **`linnix-cli/`** - Main compiled CLI application (Rust)
- **`scripts/`** - Build, installation, and development automation scripts
- **`tools/`** - User-facing helper utilities for operators and developers

## Common Workflows

### Investigate an Incident
```bash
# 1. List recent incidents
./tools/view_incidents.sh list

# 2. View details of a specific incident
./tools/view_incidents.sh json 33

# 3. Generate a full report
./tools/incident_report.sh --since 1h --format md > incident_report.md

# 4. Check PSI correlation
./tools/psi_incident_correlation.sh
```

### Monitor System Health
```bash
# 1. Quick health check
./tools/health_check.sh

# 2. Watch system metrics
./tools/system_monitor.sh

# 3. Track PSI trends
./tools/psi_tracker.sh

# 4. Find resource hogs
./tools/top_offenders.sh
```

### Manage Actions
```bash
# 1. List pending actions
./tools/action_manager.sh list

# 2. Review action history
./tools/action_audit.sh

# 3. Approve/reject interactively
./tools/action_manager.sh interactive
```

### Debug and Explore
```bash
# 1. Explore available APIs
./tools/api_explorer.sh interactive

# 2. Watch live process events
./tools/process_watcher.sh

# 3. Monitor alerts
./tools/alert_watcher.sh

# 4. Examine process tree
./tools/process_tree.sh <pid>
```

## Adding New Tools

When adding new tools to this directory:

1. Make the script executable: `chmod +x tools/your_tool.sh`
2. Add usage documentation to this README
3. Follow naming convention: lowercase with underscores
4. Include a help message when run without arguments
5. Support standard environment variables (`LINNIX_URL`, etc.)
6. Use color codes consistently (see existing tools for reference)

## Contributing

These tools should be:
- **User-focused**: Designed for operators and users, not just developers
- **Self-contained**: Minimal dependencies, clear error messages
- **Well-documented**: Include help text and examples
- **Colorful**: Use colors to highlight important information
- **Consistent**: Follow patterns established by existing tools

## Requirements

All tools require:
- **bash** (version 4.0+)
- **curl** - HTTP client for API requests
- **python3** - JSON parsing and formatting
- **bc** - Floating-point arithmetic (for thresholds)

Optional:
- **jq** - Alternative JSON processor
- **kubectl** - For Kubernetes-specific tools

## Testing

Test your tools before committing:
```bash
# Test connectivity
./tools/health_check.sh

# Test API access
./tools/api_explorer.sh test status

# Test data parsing
./tools/view_incidents.sh list
```

## License

All tools in this directory are licensed under AGPL-3.0, consistent with the Linnix project license.
