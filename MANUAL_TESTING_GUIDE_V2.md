# Manual Testing Guide: Record/Replay V2 Functionality

**Version:** 2.0
**Date:** 2025-12-19
**Branch:** mbertrone/mbertrone/feat-capture-replay-v2

## Table of Contents
1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Quick Start: Example Testing](#quick-start-example-testing)
4. [Full Integration Testing](#full-integration-testing)
5. [Advanced Testing Scenarios](#advanced-testing-scenarios)
6. [Validation Checklist](#validation-checklist)
7. [Troubleshooting](#troubleshooting)
8. [Understanding the Output](#understanding-the-output)

---

## Overview

The Record/Replay V2 functionality introduces:
- **Unified JSON format** combining process events and system snapshots
- **Enhanced system snapshots** with per-process metrics (CPU, memory, RSS)
- **File-only replay** for safe, isolated incident analysis
- **Configurable recording** with flexible snapshot intervals and thresholds
- **RSS tracking fix** that captures memory regardless of activity level

### Key Files
- `cognitod/src/handler/recording.rs` - Recording handler (cognitod/src/handler/recording.rs:0)
- `cognitod/test-config-v2.toml` - Test configuration
- `cognitod/test-rules-v2.yaml` - Simple test rules
- `examples/record-replay-v2/example_usage.rs` - Standalone example

---

## Prerequisites

### System Requirements
- Linux system (Ubuntu/Debian recommended)
- Rust toolchain installed
- Sudo access (for full cognitod testing)
- At least 100MB free disk space

### Build the Project
```bash
cd /home/ubuntu/linnix
cargo build --release
```

This should compile without errors. The cognitod binary will be at:
```
/home/ubuntu/linnix/target/release/cognitod
```

---

## Quick Start: Example Testing

The quickest way to validate V2 functionality is using the standalone example.

### Step 1: Run the Example

```bash
cd /home/ubuntu/linnix/examples/record-replay-v2
cargo run --bin example_usage
```

**Expected Output:**
```
=== Record/Replay V2 Example Workflow ===

✅ Recording written to: example_recording_v2.jsonl
📊 Total entries: 8
   - process_event: 5 entries
   - system_snapshot: 3 entries

=== Replay Analysis ===
✅ Loaded 8 entries from recording
📅 Time range: 1705939200000000000 to 1705939210000000000 (10s duration)
📈 Found 3 system snapshots

🖥️  CPU Usage Trend:
   Time 1705939200000000000: CPU=45.2%, Memory=67.8%, PSI=23.4%, 2 processes
   Time 1705939205000000000: CPU=50.2%, Memory=69.8%, PSI=24.4%, 2 processes
   Time 1705939210000000000: CPU=55.2%, Memory=71.8%, PSI=25.4%, 2 processes
...
```

### Step 2: Inspect the Recording File

```bash
cat example_recording_v2.jsonl
```

**Expected Format:**
Each line should be valid JSON with this structure:
```json
{"type":"process_event","timestamp":1705939200000000000,"data":{"comm":"process0","cpu_percent":10.0,"event_type":0,"pid":1000}}
{"type":"system_snapshot","timestamp":1705939200000000000,"data":{"active_processes":[...],"cpu_percent":45.2,"mem_percent":67.8,"psi_cpu_some_avg10":23.4,"timestamp":1705939200000000000}}
```

### Step 3: Validate JSON Format

```bash
# Verify each line is valid JSON
cat example_recording_v2.jsonl | while read line; do
  echo "$line" | jq . > /dev/null || echo "Invalid JSON: $line"
done
```

**Expected:** No output (all lines are valid JSON)

### Step 4: Query the Data

```bash
# Count entries by type
cat example_recording_v2.jsonl | jq -r '.type' | sort | uniq -c

# Extract all PIDs from process events
cat example_recording_v2.jsonl | jq -r 'select(.type=="process_event") | .data.pid'

# View system snapshot at specific time
cat example_recording_v2.jsonl | jq 'select(.type=="system_snapshot" and .timestamp==1705939210000000000)'
```

### Verification Points
- ✅ Example runs without errors
- ✅ Recording file is created (example_recording_v2.jsonl)
- ✅ File contains 8 entries (5 process events + 3 snapshots)
- ✅ Each line is valid JSON
- ✅ Two entry types present: "process_event" and "system_snapshot"
- ✅ Timestamps are in nanoseconds (19-digit numbers)
- ✅ System snapshots include active_processes array

---

## Full Integration Testing

This tests V2 recording with the actual cognitod daemon.

### Step 1: Set Up Test Environment

```bash
# Navigate to project root
cd /home/ubuntu/linnix

# Ensure test recording file doesn't exist
rm -f /tmp/linnix_test_recording_v2.jsonl

# Verify test configuration exists
cat cognitod/test-config-v2.toml
```

**Configuration Review:**
Check that these settings are present:
- `recording.enabled = true`
- `recording.v2_format = true`
- `recording.snapshots_enabled = true`
- `recording.snapshot_interval_ms = 5000` (5 seconds)
- `recording.activity_threshold = 0` (always update RSS)
- `rules.enabled = true`
- `rules.path = "cognitod/test-rules-v2.yaml"` (rules file location)

### Step 2: Start cognitod with V2 Configuration

```bash
# Option A: Run in foreground (recommended for testing)
sudo RUST_LOG=info ./target/release/cognitod --config cognitod/test-config-v2.toml

# Option B: Run in background
sudo RUST_LOG=info ./target/release/cognitod --config cognitod/test-config-v2.toml &
COGNITOD_PID=$!
```

**Expected Log Output:**
```
[INFO] Recording enabled: /tmp/linnix_test_recording_v2.jsonl
[INFO] Using V2 format: true
[INFO] Snapshots enabled: interval=5000ms
[INFO] cognitod started
```

### Step 3: Generate System Activity

While cognitod is running, generate some process activity:

```bash
# Open a new terminal and run these commands:

# Create some short-lived processes
for i in {1..10}; do
  sleep 0.1 &
done

# Run a CPU-intensive task briefly
yes > /dev/null &
CPU_PID=$!
sleep 2
kill $CPU_PID

# Create and exit processes rapidly
for i in {1..20}; do
  bash -c "echo test > /dev/null" &
done

# Wait a bit for activity to be recorded
sleep 10
```

### Step 4: Stop cognitod

```bash
# If running in foreground: Press Ctrl+C

# If running in background:
sudo kill $COGNITOD_PID

# Wait for graceful shutdown
sleep 2
```

### Step 5: Verify Recording File

```bash
# Check file exists and has content
ls -lh /tmp/linnix_test_recording_v2.jsonl

# Count entries
wc -l /tmp/linnix_test_recording_v2.jsonl

# View first few entries
head -n 5 /tmp/linnix_test_recording_v2.jsonl | jq .

# Count by type
cat /tmp/linnix_test_recording_v2.jsonl | jq -r '.type' | sort | uniq -c
```

**Expected Results:**
- File size: 10KB - 1MB (depending on activity and duration)
- Multiple entries (at least 2 snapshots for 10+ seconds of recording)
- Mix of "process_event" and "system_snapshot" entries
- System snapshots every ~5 seconds

### Step 6: Analyze Recording Content

```bash
# Extract unique process names
cat /tmp/linnix_test_recording_v2.jsonl | \
  jq -r 'select(.type=="process_event") | .data.comm' | \
  sort | uniq

# View system snapshots timeline
cat /tmp/linnix_test_recording_v2.jsonl | \
  jq -r 'select(.type=="system_snapshot") |
  "\(.timestamp): CPU=\(.data.cpu_percent)% Mem=\(.data.mem_percent)% Processes=\(.data.active_processes | length)"'

# Find highest CPU processes
cat /tmp/linnix_test_recording_v2.jsonl | \
  jq -r 'select(.type=="system_snapshot") |
  .data.active_processes[] | "\(.comm): \(.cpu_percent)% CPU, \(.rss_mb)MB RSS"' | \
  sort -t: -k2 -rn | head -10
```

### Verification Points
- ✅ cognitod starts without errors
- ✅ Recording file is created at configured path
- ✅ Process events are captured (verify your test processes appear)
- ✅ System snapshots appear every 5 seconds
- ✅ Active processes in snapshots have non-zero RSS values
- ✅ Timestamps are monotonically increasing
- ✅ No duplicate entries (same timestamp + same data)

---

## Advanced Testing Scenarios

### Scenario 1: Long-Running Recording

Test recording over an extended period to validate:
- File growth rate
- Memory stability
- No data corruption

```bash
# Start recording
sudo RUST_LOG=info ./target/release/cognitod \
  --config cognitod/test-config-v2.toml &
COGNITOD_PID=$!

# Monitor for 5 minutes
for i in {1..5}; do
  sleep 60
  echo "Minute $i:"
  ls -lh /tmp/linnix_test_recording_v2.jsonl
  tail -1 /tmp/linnix_test_recording_v2.jsonl | jq .
done

# Stop and verify
sudo kill $COGNITOD_PID
cat /tmp/linnix_test_recording_v2.jsonl | jq . > /dev/null
echo "JSON validation: $?"
```

**Expected:**
- File grows steadily (~1-2 MB/hour)
- All JSON valid
- No errors in logs

### Scenario 2: High Process Activity

Test with many concurrent processes:

```bash
# Create fork bomb simulation (controlled)
cat > /tmp/fork_test.sh << 'EOF'
#!/bin/bash
for i in {1..100}; do
  (sleep 0.5) &
done
wait
EOF
chmod +x /tmp/fork_test.sh

# Start recording
sudo RUST_LOG=info ./target/release/cognitod \
  --config cognitod/test-config-v2.toml &
COGNITOD_PID=$!

# Run fork test
/tmp/fork_test.sh

# Wait for snapshots
sleep 10

# Stop and analyze
sudo kill $COGNITOD_PID

# Verify all processes captured
cat /tmp/linnix_test_recording_v2.jsonl | \
  jq -r 'select(.type=="system_snapshot") |
  "\(.timestamp): \(.data.active_processes | length) processes"'
```

**Expected:**
- Multiple processes in snapshots (up to `process_snapshot_limit` = 50)
- No crashes or errors
- Process events for fork/exec/exit

### Scenario 3: Custom Configuration

Test with different configuration options:

```bash
# Create custom config
cat > /tmp/test-custom-v2.toml << 'EOF'
[recording]
enabled = true
file_path = "/tmp/custom_recording.jsonl"
v2_format = true
snapshots_enabled = true
snapshot_interval_ms = 2000  # 2 seconds instead of 5
process_snapshot_limit = 20  # Only top 20 processes
process_cpu_threshold = 5.0  # Only processes using >5% CPU
compress_output = false
activity_threshold = 0

[circuit_breaker]
enabled = false

[rules]
enabled = false
path = ""  # No rules file needed for this test

[api]
enabled = false

[llm]
enabled = false

[notifications]
enabled = false
EOF

# Run with custom config
sudo RUST_LOG=info ./target/release/cognitod \
  --config /tmp/test-custom-v2.toml &
COGNITOD_PID=$!

# Monitor
sleep 10

# Verify custom settings
sudo kill $COGNITOD_PID

# Check snapshot interval (should be ~2 seconds)
cat /tmp/custom_recording.jsonl | \
  jq -r 'select(.type=="system_snapshot") | .timestamp' | \
  awk 'NR>1 {print ($1 - prev)/1000000000 "s"} {prev=$1}'
```

**Expected:**
- Snapshots every ~2 seconds
- Only high CPU processes in snapshots
- Maximum 20 processes per snapshot

### Scenario 4: RSS Tracking Validation

Verify that RSS is tracked continuously for long-running processes:

```bash
# Start a memory-growing process
python3 << 'EOF' &
import time
data = []
for i in range(60):
    data.append(' ' * 1024 * 1024)  # Allocate 1MB
    time.sleep(1)
EOF
PYTHON_PID=$!

# Start recording
sudo RUST_LOG=info ./target/release/cognitod \
  --config cognitod/test-config-v2.toml &
COGNITOD_PID=$!

# Wait for recording
sleep 30

# Stop both
kill $PYTHON_PID
sudo kill $COGNITOD_PID

# Analyze RSS growth for python process
cat /tmp/linnix_test_recording_v2.jsonl | \
  jq -r 'select(.type=="system_snapshot") |
  .data.active_processes[] |
  select(.comm=="python3") |
  "\(.timestamp): RSS=\(.rss_mb)MB"'
```

**Expected:**
- RSS values present in every snapshot
- RSS increases over time (showing memory growth)
- No gaps in RSS tracking

---

## Validation Checklist

Use this checklist to ensure all functionality is working:

### Recording Features
- [ ] V2 format enabled (unified JSON structure)
- [ ] Process events captured (exec, fork, exit)
- [ ] System snapshots generated at configured interval
- [ ] Active processes included in snapshots
- [ ] RSS values present and non-zero for active processes
- [ ] Timestamps in nanoseconds (19 digits)
- [ ] File created at configured path
- [ ] All entries are valid JSON
- [ ] No duplicate entries
- [ ] File grows at expected rate

### Configuration
- [ ] `v2_format` setting respected
- [ ] `snapshots_enabled` setting respected
- [ ] `snapshot_interval_ms` controls snapshot frequency
- [ ] `process_snapshot_limit` limits processes per snapshot
- [ ] `process_cpu_threshold` filters low-activity processes
- [ ] `activity_threshold = 0` ensures RSS always updated
- [ ] `file_path` setting creates file in correct location

### Data Quality
- [ ] CPU percentages in reasonable range (0-100%)
- [ ] Memory percentages in reasonable range (0-100%)
- [ ] PSI metrics present (if available on system)
- [ ] PIDs are valid integers
- [ ] Process names (comm) are non-empty strings
- [ ] RSS values match expected process memory usage
- [ ] Timestamps monotonically increase

### Replay Capabilities (Example)
- [ ] Load recording from file without errors
- [ ] Filter by entry type (process_event vs system_snapshot)
- [ ] Filter by time range
- [ ] Extract process metrics
- [ ] Analyze CPU/memory trends over time
- [ ] Reconstruct system state at specific timestamps

---

## Troubleshooting

### Issue: No recording file created

**Symptoms:** cognitod runs but `/tmp/linnix_test_recording_v2.jsonl` doesn't exist

**Solutions:**
1. Check configuration: `recording.enabled = true`
2. Verify file path has write permissions: `touch /tmp/test.txt`
3. Check cognitod logs: `sudo RUST_LOG=debug ./target/release/cognitod ...`
4. Ensure parent directory exists: `mkdir -p /tmp`

### Issue: Empty recording file

**Symptoms:** File exists but has 0 bytes or no entries

**Solutions:**
1. Wait longer - first snapshot may take 5+ seconds
2. Generate process activity (run some commands)
3. Check if recording handler is initialized: Look for "Recording enabled" in logs
4. Verify eBPF probes loaded: `sudo bpftool prog list | grep cognitod`

### Issue: Only process events, no snapshots

**Symptoms:** File has process_event entries but no system_snapshot entries

**Solutions:**
1. Check `recording.snapshots_enabled = true`
2. Verify snapshot interval is reasonable: `snapshot_interval_ms = 5000`
3. Ensure cognitod runs long enough (at least 10 seconds)
4. Check for errors related to /proc access (requires root)

### Issue: Snapshots missing active_processes

**Symptoms:** System snapshots exist but active_processes array is empty

**Solutions:**
1. Check `process_cpu_threshold` - may be filtering out all processes
2. Set `activity_threshold = 0` in config
3. Verify processes are actually running: `ps aux | wc -l`
4. Lower `process_cpu_threshold` to 0.1 or 0.0

### Issue: Invalid JSON in recording

**Symptoms:** `jq` or JSON parsing fails

**Solutions:**
1. Check for partial writes: Last line may be incomplete
2. Stop cognitod gracefully: Use kill (SIGTERM), not kill -9
3. Verify disk not full: `df -h /tmp`
4. Check for special characters in process names

### Issue: File growing too fast

**Symptoms:** Recording file is multiple GB after short time

**Solutions:**
1. Increase `snapshot_interval_ms` (default 5000 = 5 seconds)
2. Reduce `process_snapshot_limit` (default 50)
3. Increase `process_cpu_threshold` (filter out idle processes)
4. Enable `compress_output = true` (if implemented)
5. Implement log rotation or retention policy

### Issue: Missing RSS values or RSS always zero

**Symptoms:** active_processes entries show `"rss_mb": 0` or RSS field missing

**Solutions:**
1. Ensure `activity_threshold = 0` in configuration
2. Run cognitod as root: `sudo ./target/release/cognitod ...`
3. Check /proc access: `cat /proc/$$/status | grep VmRSS`
4. Verify process tracking is working: Look for process_event entries

---

## Understanding the Output

### V2 Recording Format Structure

Each line in the recording file is a JSON object with this structure:

```json
{
  "type": "process_event" | "system_snapshot",
  "timestamp": <nanoseconds_since_epoch>,
  "data": { ... type-specific data ... }
}
```

### Process Event Entry

```json
{
  "type": "process_event",
  "timestamp": 1705939200000000000,
  "data": {
    "pid": 1234,
    "comm": "example_process",
    "cpu_percent": 15.5,
    "event_type": 0
  }
}
```

**Fields:**
- `pid`: Process ID
- `comm`: Process name (command)
- `cpu_percent`: CPU usage percentage at event time
- `event_type`: 0=exec, 1=fork, 2=exit

### System Snapshot Entry

```json
{
  "type": "system_snapshot",
  "timestamp": 1705939200000000000,
  "data": {
    "timestamp": 1705939200000000000,
    "cpu_percent": 45.2,
    "mem_percent": 67.8,
    "psi_cpu_some_avg10": 23.4,
    "active_processes": [
      {
        "pid": 1001,
        "comm": "python3",
        "cpu_percent": 15.2,
        "mem_percent": 8.9,
        "rss_mb": 145
      },
      {
        "pid": 1002,
        "comm": "node",
        "cpu_percent": 8.1,
        "mem_percent": 12.3,
        "rss_mb": 89
      }
    ]
  }
}
```

**System Fields:**
- `cpu_percent`: Overall system CPU usage (0-100%)
- `mem_percent`: Overall system memory usage (0-100%)
- `psi_cpu_some_avg10`: CPU pressure stall information (10-second average)

**Per-Process Fields:**
- `pid`: Process ID
- `comm`: Process name
- `cpu_percent`: Process CPU usage
- `mem_percent`: Process memory usage (% of total system memory)
- `rss_mb`: Resident Set Size in megabytes (actual RAM used)

### Timestamp Format

Timestamps are in **nanoseconds since Unix epoch** (January 1, 1970):
- Format: 19-digit integer
- Example: `1705939200000000000`
- Convert to seconds: divide by `1_000_000_000`
- Convert to human readable:
  ```bash
  echo 1705939200000000000 | awk '{print strftime("%Y-%m-%d %H:%M:%S", $1/1000000000)}'
  ```

### Common Queries

**Extract all unique process names:**
```bash
cat recording.jsonl | jq -r 'select(.type=="process_event") | .data.comm' | sort -u
```

**Find CPU usage over time:**
```bash
cat recording.jsonl | jq -r 'select(.type=="system_snapshot") | [.timestamp, .data.cpu_percent] | @tsv'
```

**Get top memory consumers:**
```bash
cat recording.jsonl | jq -r 'select(.type=="system_snapshot") | .data.active_processes[] | [.rss_mb, .comm] | @tsv' | sort -rn | head -10
```

**Find all events in time range:**
```bash
START=1705939200000000000
END=1705939210000000000
cat recording.jsonl | jq "select(.timestamp >= $START and .timestamp <= $END)"
```

---

## Next Steps

After successful manual testing:

1. **Commit your changes:**
   ```bash
   git add -A
   git commit -m "Validate Record/Replay V2 functionality"
   ```

2. **Integrate with main.rs:**
   - Update recording initialization to use V2 format
   - Add periodic snapshot collection task
   - Implement CLI replay commands

3. **Real-world validation:**
   - Deploy to staging environment
   - Test with actual production-like workloads
   - Validate incident replay capabilities

4. **Documentation:**
   - Update user-facing documentation
   - Add configuration examples
   - Document storage and retention recommendations

---

## References

- **Implementation:** `cognitod/src/handler/recording.rs`
- **Test Config:** `cognitod/test-config-v2.toml`
- **Example Code:** `examples/record-replay-v2/example_usage.rs`
- **Test Results:** `examples/record-replay-v2/TEST_RESULTS.md`
- **Feature Branch:** `mbertrone/mbertrone/feat-capture-replay-v2`
