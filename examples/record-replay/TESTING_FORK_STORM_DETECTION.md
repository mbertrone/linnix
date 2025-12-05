# Testing Fork Storm Detection Guide

This guide walks through testing the fork storm detection system in both live monitoring and record/replay modes, including how to verify alerts were triggered and analyze the results.

## Prerequisites

### 1. Build the Project
```bash
cd /home/ubuntu/linnix

# Build eBPF programs (one-time setup)
cargo xtask build-ebpf --release

# Build cognitod
cargo build --release
```

### 2. Verify Scripts and Rules
```bash
# Ensure fork storm generator is executable
chmod +x examples/record-replay/fork_storm.sh

# Verify rules file exists
ls -lh examples/record-replay/fork-storm-rules.yaml
```

### 3. Create Log Directory (if needed)
```bash
sudo mkdir -p /var/log/linnix
sudo chown $USER:$USER /var/log/linnix
```

---

## Quick Test with Example Recording

**Want to test immediately without generating your own fork storm?**

Use the included example recording that already contains a fork storm:

```bash
cd /home/ubuntu/linnix

# Replay the example recording with detection rules (5x speed)
sudo RUST_LOG=info ./target/release/cognitod \
  --replay examples/record-replay/fork-storm-example.ndjson \
  --replay-speed 5.0 \
  --handler rules:examples/record-replay/fork-storm-rules.yaml
```

**What you'll see:**
- 8,226 events replayed in ~10 seconds
- Multiple alerts triggered in console logs
- Alerts written to `/var/log/linnix/alerts.ndjson`

**Check the results:**
```bash
# View all triggered alerts
cat /var/log/linnix/alerts.ndjson | jq '.'

# Count alerts by rule
jq -r '.rule' /var/log/linnix/alerts.ndjson | sort | uniq -c
```

**Expected alerts:**
- `fork_storm_sustained` - High sustained fork rate
- `fork_storm_burst` - Sudden burst of forks
- `runaway_parent_tree` - Parent spawning many children
- `fork_storm_extreme` - Critical fork rate threshold

This example recording contains:
- 2,783 Fork events
- 2,774 Exit events
- 2,669 Exec events
- 52 seconds of recorded activity
- Multiple fork storm patterns

---

## Scenario 1: Live Detection (Normal Mode)

This scenario runs cognitod with live eBPF monitoring and detects fork storms in real-time.

### Step 1: Start Cognitod with Rules

**Terminal 1** - Start the daemon:
```bash
cd /home/ubuntu/linnix

# Start with verbose logging and rules enabled
sudo RUST_LOG=info ./target/release/cognitod \
  --handler rules:examples/record-replay/fork-storm-rules.yaml
```

**Expected output:**
```
[cognitod] Starting Cognition Daemon...
[INFO] Running with CAP_BPF + CAP_PERFMON
[INFO] BPF logger initialized.
[cognitod] Fork program loaded and attached.
[INFO] Rules handler loaded from examples/record-replay/fork-storm-rules.yaml (6 rules)
[cognitod] Starting listener for BPF perf buffers...
[cognitod] Running. Press Ctrl+C to exit.
```

**✓ Verify**: Look for the line:
```
[INFO] Rules handler loaded from examples/record-replay/fork-storm-rules.yaml (6 rules)
```

If you see this, rules are loaded successfully.

### Step 2: Generate Fork Storm

**Terminal 2** - Run the fork storm generator:
```bash
cd /home/ubuntu/linnix/examples/record-replay

# Generate 100 forks/sec for 10 seconds
./fork_storm.sh 100 10
```

**Expected output:**
```
[16:58:26] [INFO] Fork Storm Generator starting (PID: 458632)
[16:58:26] [INFO] Configuration:
[16:58:26] [INFO]   Rate: 100 forks/second
[16:58:26] [INFO]   Duration: 10 seconds
[16:58:26] [INFO]   Expected total: ~1000 forks

[16:58:28] [INFO] Progress: 2s / 10s | Forks: 100 | Rate: ~33/s
[16:58:29] [INFO] Progress: 3s / 10s | Forks: 200 | Rate: ~50/s
...
[16:58:36] [INFO] Fork storm complete!
[16:58:36] [INFO]   Total forks: 580
[16:58:36] [INFO]   Duration: 10s
[16:58:36] [INFO]   Actual rate: 58/s
```

### Step 3: Observe Live Alerts

**In Terminal 1** (where cognitod is running), you should see alert messages:

```
[INFO cognitod::alerts] [rules] emitting alert rule=fork_storm_sustained severity=high message=fork rate exceeded 10 per second
[INFO cognitod::alerts] [rules] emitting alert rule=fork_storm_burst severity=critical message=fork burst: 99 forks in 5s
[INFO cognitod::alerts] [rules] emitting alert rule=runaway_parent_tree severity=critical message=ppid 458632 spawned 25 forks in 10s
[INFO cognitod::alerts] [rules] emitting alert rule=fork_storm_extreme severity=critical message=CRITICAL: Extreme fork storm detected - possible fork bomb
```

**What to look for:**
- `[rules] emitting alert` - Indicates a rule triggered
- `rule=fork_storm_*` - The specific rule that fired
- `severity=critical/high/medium` - Alert severity level
- Message details about what triggered the alert

### Step 4: Check Alerts File

**Terminal 3** - Verify alerts were written to disk:
```bash
# View all alerts (NDJSON format)
cat /var/log/linnix/alerts.ndjson | jq '.'

# Count total alerts
wc -l /var/log/linnix/alerts.ndjson

# View just the last 5 alerts
tail -5 /var/log/linnix/alerts.ndjson | jq '.'

# Filter by specific rule
jq 'select(.rule == "fork_storm_burst")' /var/log/linnix/alerts.ndjson
```

**Example output:**
```json
{
  "rule": "fork_storm_burst",
  "severity": "critical",
  "message": "fork burst: 99 forks in 5s",
  "host": "ip-172-31-6-62"
}
{
  "rule": "fork_storm_sustained",
  "severity": "high",
  "message": "fork rate exceeded 10 per second",
  "host": "ip-172-31-6-62"
}
```

### Step 5: Query Timeline API

**While cognitod is still running**, check the in-memory alert history:

```bash
# Get all alerts from the current session
curl -s http://127.0.0.1:3000/timeline | jq '.'

# Count alerts in memory
curl -s http://127.0.0.1:3000/timeline | jq 'length'

# Filter by rule name
curl -s http://127.0.0.1:3000/timeline | \
  jq '.[] | select(.alert.rule | startswith("fork_storm"))'

# Filter by severity
curl -s http://127.0.0.1:3000/timeline?severity=critical | jq '.'

# Get alerts in a time range (Unix timestamps)
START=$(date -d '5 minutes ago' +%s)
END=$(date +%s)
curl -s "http://127.0.0.1:3000/timeline?start=$START&end=$END" | jq '.'
```

**Example output:**
```json
[
  {
    "id": 1,
    "timestamp": 1733333914,
    "alert": {
      "rule": "fork_storm_burst",
      "severity": "critical",
      "message": "fork burst: 99 forks in 5s",
      "host": "ip-172-31-6-62"
    }
  },
  {
    "id": 2,
    "timestamp": 1733333915,
    "alert": {
      "rule": "fork_storm_sustained",
      "severity": "high",
      "message": "fork rate exceeded 10 per second",
      "host": "ip-172-31-6-62"
    }
  }
]
```

### Step 6: Stream Live Alerts (Optional)

**In a separate terminal**, stream alerts in real-time using SSE:

```bash
# This will block and show alerts as they occur
curl -N http://127.0.0.1:3000/alerts
```

**Example output:**
```
event: alert
data: {"rule":"fork_storm_burst","severity":"critical","message":"fork burst: 99 forks in 5s","host":"ip-172-31-6-62"}

event: alert
data: {"rule":"fork_storm_sustained","severity":"high","message":"fork rate exceeded 10 per second","host":"ip-172-31-6-62"}
```

### Step 7: Analyze Results

**Group alerts by rule:**
```bash
jq -r '.rule' /var/log/linnix/alerts.ndjson | sort | uniq -c
```

**Output example:**
```
      3 fork_storm_burst
      2 fork_storm_extreme
      4 fork_storm_sustained
      1 runaway_parent_tree
      2 short_lived_flood
```

**Count by severity:**
```bash
jq -r '.severity' /var/log/linnix/alerts.ndjson | sort | uniq -c
```

**Output example:**
```
      8 critical
      4 high
```

**Timeline visualization:**
```bash
jq -r '[.rule, .message] | @tsv' /var/log/linnix/alerts.ndjson | nl
```

### Step 8: Stop Cognitod

**In Terminal 1**, press `Ctrl+C`:
```
^C[cognitod] Shutting down...
```

---

## Scenario 2: Record + Replay Detection

This scenario records fork storm events to a file, then replays them through the detection system to verify reproducibility.

### Step 1: Start Recording Session

**Terminal 1** - Start cognitod in recording mode with rules:
```bash
cd /home/ubuntu/linnix

# Clear previous alerts file for clean test
sudo rm -f /var/log/linnix/alerts.ndjson

# Start recording with rules enabled
sudo RUST_LOG=info ./target/release/cognitod \
  --record /tmp/fork-storm-recording.ndjson \
  --handler rules:examples/record-replay/fork-storm-rules.yaml
```

**Expected output:**
```
[cognitod] Starting Cognition Daemon...
[INFO] Rules handler loaded from examples/record-replay/fork-storm-rules.yaml (6 rules)
[INFO] Recording to: /tmp/fork-storm-recording.ndjson
[cognitod] Running. Press Ctrl+C to exit.
```

**Note**: Recording happens WHILE detection is active, so you'll see both:
- Events being recorded to NDJSON file
- Alerts being triggered in real-time

### Step 2: Generate Fork Storm

**Terminal 2** - Run the generator:
```bash
cd /home/ubuntu/linnix/examples/record-replay

# Generate a substantial fork storm
./fork_storm.sh 100 10
```

**Watch Terminal 1** - You should see:
- Live event captures: `[event] type="Fork" pid=...`
- Alert triggers: `[rules] emitting alert...`

### Step 3: Stop Recording

**In Terminal 1**, press `Ctrl+C`:
```
^C[cognitod] Shutting down...
```

### Step 4: Verify Recording

```bash
# Check recording size
ls -lh /tmp/fork-storm-recording.ndjson

# Count events recorded
wc -l /tmp/fork-storm-recording.ndjson

# View event types distribution
jq -r '.event.base.event_type' /tmp/fork-storm-recording.ndjson | \
  sort | uniq -c | \
  awk '{
    if ($2 == 0) print $1 " Exec events"
    else if ($2 == 1) print $1 " Fork events"
    else if ($2 == 2) print $1 " Exit events"
    else print $1 " Unknown(" $2 ") events"
  }'
```

**Example output:**
```
-rw-r--r-- 1 root root 147K Dec  4 17:30 /tmp/fork-storm-recording.ndjson
     580
    290 Fork events
    290 Exit events
```

### Step 5: Analyze Recording Alerts

**Check what alerts were triggered during recording:**
```bash
# View alerts from the recording session
cat /var/log/linnix/alerts.ndjson | jq '.'

# Count alerts triggered
wc -l /var/log/linnix/alerts.ndjson

# Save for comparison
cp /var/log/linnix/alerts.ndjson /tmp/alerts-recording-phase.ndjson
```

### Step 6: Clear Alerts for Replay Test

```bash
# Clear alerts file to distinguish recording vs replay alerts
sudo rm -f /var/log/linnix/alerts.ndjson

# Verify it's gone
ls -lh /var/log/linnix/alerts.ndjson 2>&1
```

**Expected output:**
```
ls: cannot access '/var/log/linnix/alerts.ndjson': No such file or directory
```

### Step 7: Replay with Detection

**Terminal 1** - Replay the recorded events:
```bash
cd /home/ubuntu/linnix

# Replay at 5x speed with rules enabled
sudo RUST_LOG=info ./target/release/cognitod \
  --replay /tmp/fork-storm-recording.ndjson \
  --replay-speed 5.0 \
  --handler rules:examples/record-replay/fork-storm-rules.yaml
```

**Expected output:**
```
[cognitod] Starting Cognition Daemon...
[INFO] Rules handler loaded from examples/record-replay/fork-storm-rules.yaml (6 rules)
[INFO] Replaying from: /tmp/fork-storm-recording.ndjson at 5.0x speed
[INFO] Replay: Processing events...
[INFO cognitod::alerts] [rules] emitting alert rule=fork_storm_sustained ...
[INFO cognitod::alerts] [rules] emitting alert rule=fork_storm_burst ...
[INFO] Replay: Completed 580 events
```

**What to observe:**
- Rules are loaded (same as live mode)
- Replay processes events quickly (5x speed)
- Same alerts trigger as during recording
- Replay completes automatically when file is exhausted

### Step 8: Verify Replay Alerts

```bash
# Check alerts generated during replay
cat /var/log/linnix/alerts.ndjson | jq '.'

# Count replay alerts
wc -l /var/log/linnix/alerts.ndjson

# Save replay alerts
cp /var/log/linnix/alerts.ndjson /tmp/alerts-replay-phase.ndjson
```

### Step 9: Compare Recording vs Replay

```bash
# Compare alert counts
echo "Recording phase alerts:"
wc -l /tmp/alerts-recording-phase.ndjson

echo "Replay phase alerts:"
wc -l /tmp/alerts-replay-phase.ndjson

# Compare alert rules triggered
echo "Recording phase rules:"
jq -r '.rule' /tmp/alerts-recording-phase.ndjson | sort | uniq -c

echo "Replay phase rules:"
jq -r '.rule' /tmp/alerts-replay-phase.ndjson | sort | uniq -c

# Detailed comparison (should be similar, accounting for timing variations)
echo "Recording alerts:"
jq -c '{rule, severity, message}' /tmp/alerts-recording-phase.ndjson | sort

echo "Replay alerts:"
jq -c '{rule, severity, message}' /tmp/alerts-replay-phase.ndjson | sort
```

**Expected result:**
- Same rules should trigger in both phases
- Alert counts may differ slightly due to:
  - Cooldown timing differences (replay is 5x faster)
  - Exact timing of fork bursts
- Message content should be similar (e.g., "99 forks" vs "101 forks" due to timing)

### Step 10: Query Replay Timeline

**During replay**, in another terminal:
```bash
# Query timeline while replay is running
curl -s http://127.0.0.1:3000/timeline | jq 'length'

# View recent alerts
curl -s http://127.0.0.1:3000/timeline | jq '.[-5:]'
```

**Note**: The timeline API only shows alerts from the CURRENT cognitod session, so:
- Recording phase alerts: Available during recording session only
- Replay phase alerts: Available during replay session only
- Both are saved to `/var/log/linnix/alerts.ndjson` across sessions

---

## Understanding Alert Output

### Console Log Format
```
[2025-12-04T16:58:44Z INFO  cognitod::alerts] [rules] emitting alert rule=fork_storm_burst severity=critical message=fork burst: 99 forks in 5s
```

**Fields:**
- `2025-12-04T16:58:44Z` - Timestamp (UTC)
- `INFO` - Log level
- `cognitod::alerts` - Source module
- `[rules]` - Subsystem
- `rule=fork_storm_burst` - Which rule triggered
- `severity=critical` - Alert severity (critical/high/medium/low/info)
- `message=...` - Human-readable description

### NDJSON File Format
```json
{
  "rule": "fork_storm_burst",
  "severity": "critical",
  "message": "fork burst: 99 forks in 5s",
  "host": "ip-172-31-6-62"
}
```

**Fields:**
- `rule` - Rule identifier (matches rules YAML)
- `severity` - Alert level
- `message` - Trigger details
- `host` - Hostname where alert occurred

### Timeline API Format
```json
{
  "id": 1,
  "timestamp": 1733333914,
  "alert": {
    "rule": "fork_storm_burst",
    "severity": "critical",
    "message": "fork burst: 99 forks in 5s",
    "host": "ip-172-31-6-62"
  }
}
```

**Additional fields:**
- `id` - Sequential alert ID (per session)
- `timestamp` - Unix epoch seconds

---

## Troubleshooting

### Problem: No Alerts Triggered

**Check 1:** Verify rules loaded
```bash
# Look for this line in cognitod output:
[INFO] Rules handler loaded from examples/record-replay/fork-storm-rules.yaml (6 rules)
```

If missing, check:
- File path is correct
- YAML syntax is valid: `python3 -c "import yaml; yaml.safe_load(open('examples/record-replay/fork-storm-rules.yaml'))"`

**Check 2:** Verify fork rate is high enough
```bash
# The fork storm script should show actual rate
# Look for: "Actual rate: XX/s"
# Needs to be > 10/s to trigger fork_storm_sustained
```

If rate is too low:
- Increase forks per second: `./fork_storm.sh 150 10`
- System might be under load - close other processes

**Check 3:** Check cooldown periods
```bash
# Rules have 30-second cooldown by default
# If you run fork storm twice quickly, second run won't alert
# Wait 30+ seconds between tests
```

**Check 4:** Verify RUST_LOG is set
```bash
# Without RUST_LOG=info, you won't see the alert logs
# Must include: RUST_LOG=info
```

### Problem: Alerts File Empty

**Check permissions:**
```bash
ls -l /var/log/linnix/
sudo mkdir -p /var/log/linnix
sudo chown $USER:$USER /var/log/linnix
```

**Check disk space:**
```bash
df -h /var/log
```

**Manually test write:**
```bash
echo '{"test": "write"}' >> /var/log/linnix/alerts.ndjson
cat /var/log/linnix/alerts.ndjson
```

### Problem: Timeline API Returns Empty Array

**Reason 1:** Timeline is per-session
- Alerts only available during the cognitod session that generated them
- After restart, timeline is empty (but file has historical data)

**Reason 2:** No alerts triggered yet
- Generate a fork storm first
- Check console logs for `[rules] emitting alert`

**Reason 3:** Wrong URL
```bash
# Correct:
curl http://127.0.0.1:3000/timeline

# Wrong (streaming endpoint, not historical):
curl http://127.0.0.1:3000/alerts
```

### Problem: Replay Doesn't Trigger Alerts

**Check 1:** Verify recording has events
```bash
# Should have hundreds/thousands of events
wc -l /tmp/fork-storm-recording.ndjson

# Should show Fork events
jq -r '.event.base.event_type' /tmp/fork-storm-recording.ndjson | grep -c '^1$'
```

**Check 2:** Rules must be specified
```bash
# WRONG - no rules:
sudo ./target/release/cognitod --replay /tmp/fork-storm-recording.ndjson

# CORRECT - with rules:
sudo ./target/release/cognitod --replay /tmp/fork-storm-recording.ndjson \
  --handler rules:examples/record-replay/fork-storm-rules.yaml
```

**Check 3:** Replay speed affects timing
- Very fast replay (100x) may cause timing issues
- Recommended: 5x - 10x speed
- For debugging: 1x speed (real-time)

---

## Quick Reference Commands

### Start Cognitod (Live Detection)
```bash
sudo RUST_LOG=info ./target/release/cognitod \
  --handler rules:examples/record-replay/fork-storm-rules.yaml
```

### Start Recording with Detection
```bash
sudo RUST_LOG=info ./target/release/cognitod \
  --record /tmp/recording.ndjson \
  --handler rules:examples/record-replay/fork-storm-rules.yaml
```

### Replay with Detection
```bash
sudo RUST_LOG=info ./target/release/cognitod \
  --replay /tmp/recording.ndjson \
  --replay-speed 5.0 \
  --handler rules:examples/record-replay/fork-storm-rules.yaml
```

### Generate Fork Storm
```bash
cd examples/record-replay
./fork_storm.sh 100 10  # 100 forks/sec for 10 seconds
```

### Check Alerts (File)
```bash
cat /var/log/linnix/alerts.ndjson | jq '.'
jq -r '.rule' /var/log/linnix/alerts.ndjson | sort | uniq -c
```

### Check Alerts (API)
```bash
curl -s http://127.0.0.1:3000/timeline | jq '.'
curl -s http://127.0.0.1:3000/timeline?severity=critical | jq '.'
```

### Stream Live Alerts
```bash
curl -N http://127.0.0.1:3000/alerts
```

---

## Alert Persistence Summary

| Location | Survives Restart? | Max Size | Format | Access Method |
|----------|-------------------|----------|--------|---------------|
| Console Logs | No | N/A | Text | stdout/stderr |
| `/var/log/linnix/alerts.ndjson` | Yes | Unlimited* | NDJSON | `cat`, `jq` |
| `/timeline` API | No | 1000 alerts | JSON | HTTP GET |
| `/alerts` stream | No | N/A | SSE | HTTP GET (streaming) |

*No automatic rotation - manual cleanup required

---

## Next Steps

### Production Deployment
- Configure log rotation for `/var/log/linnix/alerts.ndjson`
- Set up alerting based on severity levels
- Integrate with monitoring systems (Prometheus, Grafana)
- Tune rule thresholds based on workload

### Advanced Testing
- Test with different fork rates: `./fork_storm.sh 50 5`, `./fork_storm.sh 200 3`
- Create custom rules in `fork-storm-rules.yaml`
- Test multiple simultaneous fork storms
- Replay at different speeds to test timing sensitivity

### Analysis
- Correlate alerts with system metrics
- Build dashboards using the timeline API
- Export alerts to external systems
- Create alert aggregation and reporting

---

## Summary

This guide demonstrated:
1. ✅ Starting cognitod with rules in normal mode
2. ✅ Generating fork storms with the test script
3. ✅ Observing real-time alerts in console logs
4. ✅ Querying alerts via file and API
5. ✅ Recording process events with detection active
6. ✅ Replaying events to reproduce detections
7. ✅ Comparing recording vs replay alert output

**Key Takeaway**: The fork storm detection system works identically in both live and replay modes, making it possible to:
- Test detection rules with reproducible workloads
- Debug false positives/negatives using recorded sessions
- Validate rule changes without impacting production
- Share test cases as NDJSON recordings
