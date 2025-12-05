# Record/Replay Examples

This directory contains sample recorded eBPF events and instructions for using the record/replay functionality.

## What is Record/Replay?

The record/replay feature allows you to:
- **Record** live eBPF process events to an NDJSON file
- **Replay** those events later for testing, debugging, or analysis
- Test detection rules and handlers without needing live workloads
- Share reproducible test cases with your team

## Sample Data and Test Scripts

**`sample-events.ndjson`** - A sample recording containing ~270 process events captured during a typical SSH session, including:
- SSH connection and authentication (sshd, PAM modules)
- Shell initialization (bash, run-parts)
- System utilities (landscape-sysinfo, motd scripts)
- Various command executions

**`fork-storm-example.ndjson`** - A comprehensive fork storm recording with 8,226 events over 52 seconds:
- 2,783 Fork events (sustained high fork rate)
- 2,774 Exit events (process completions)
- 2,669 Exec events (command executions)
- Generated using `./fork_storm.sh 100 10` (multiple runs)
- Perfect for testing fork storm detection rules
- Triggers multiple detection rules: fork_storm_burst, fork_storm_sustained, runaway_parent_tree
- File size: 2.4 MB

**`fork_storm.sh`** - Simple, focused fork storm generator:
- Configurable intensity: low, medium, high, extreme
- Generates multiple detection patterns: sustained rate, bursts, runaway trees
- Safe cleanup on exit

**`test_fork_storm.sh`** - Automated test suite that records, generates, and replays fork storms:
- Complete end-to-end testing
- Automatic detection verification
- Generates test reports

**`fork-storm-rules.yaml`** - Detection rules optimized for fork storm testing:
- Multiple detection thresholds
- Covers all fork storm patterns
- Tuned for test script intensities

## Quick Start

### 1. Replay the Fork Storm Example (Recommended)

Test the fork storm detection system with the included example recording:

```bash
# Replay the fork storm recording with detection rules (5x speed)
sudo ../target/release/cognitod \
  --replay examples/record-replay/fork-storm-example.ndjson \
  --replay-speed 5.0 \
  --handler rules:examples/record-replay/fork-storm-rules.yaml
```

**What you'll see:**
- 8,226 events replayed in ~10 seconds (5x speed)
- Multiple detection alerts triggered:
  - `fork_storm_sustained` - High sustained fork rate detected
  - `fork_storm_burst` - Sudden spike in forks
  - `runaway_parent_tree` - Single parent spawning many children
  - `fork_storm_extreme` - Critical fork rate threshold exceeded

**Check the results:**
```bash
# View triggered alerts
cat /var/log/linnix/alerts.ndjson | jq '.'

# Count alerts by rule
jq -r '.rule' /var/log/linnix/alerts.ndjson | sort | uniq -c

# Query via API (while cognitod is running)
curl -s http://127.0.0.1:3000/timeline | jq '.[] | {rule: .alert.rule, severity: .alert.severity}'
```

### 2. Replay Other Sample Events

```bash
# Replay SSH session recording at normal speed
sudo ../target/release/cognitod --replay examples/record-replay/sample-events.ndjson

# Replay at 10x speed (faster testing)
sudo ../target/release/cognitod --replay examples/record-replay/sample-events.ndjson --replay-speed 10.0

# Replay with rules engine active
sudo ../target/release/cognitod --replay examples/record-replay/sample-events.ndjson \
  --handler rules:configs/rules.yaml
```

### 3. Record Your Own Events

```bash
# Start recording (press Ctrl+C to stop)
sudo ../target/release/cognitod --record /tmp/my-recording.ndjson
```

In another terminal, generate activity:
```bash
# Generate some process events
ls -la
ps aux
find /etc -name "*.conf" | head -10
python3 -c "print('hello')"
```

Press Ctrl+C to stop recording, then inspect:
```bash
# View event count
wc -l /tmp/my-recording.ndjson

# View first event (requires jq)
head -1 /tmp/my-recording.ndjson | jq .

# Replay your recording
sudo ../target/release/cognitod --replay /tmp/my-recording.ndjson --replay-speed 5.0
```

## Understanding the Data Format

Each line in the NDJSON file contains one event:

```json
{
  "timestamp": 1764861931088485903,
  "event": {
    "base": {
      "pid": 370030,
      "ppid": 370023,
      "uid": 0,
      "gid": 0,
      "event_type": 2,
      "ts_ns": 101679013688836,
      "seq": 0,
      "comm": [116,111,107,105,111,45,114,117,110,116,105,109,101,45,119,0],
      "exit_time_ns": 101679013688836,
      "cpu_pct_milli": 65535,
      "mem_pct_milli": 65535,
      "data": 0,
      "data2": 0,
      "aux": 0,
      "aux2": 0
    }
  }
}
```

### Field Descriptions

| Field | Description |
|-------|-------------|
| `timestamp` | Recording timestamp (nanoseconds since Unix epoch) |
| `pid` | Process ID |
| `ppid` | Parent process ID |
| `uid` | User ID |
| `gid` | Group ID |
| `event_type` | Event type: 0=Exec, 1=Fork, 2=Exit |
| `ts_ns` | eBPF kernel timestamp (nanoseconds since boot) |
| `comm` | Command name as byte array (16 bytes, null-terminated) |
| `cpu_pct_milli` | CPU usage in milli-percent (65535 = unknown) |
| `mem_pct_milli` | Memory usage in milli-percent (65535 = unknown) |

## Advanced Usage

### Recording Specific Workloads

**Capture a build process:**
```bash
sudo ../target/release/cognitod --record /tmp/build-events.ndjson &
RECORD_PID=$!
cargo build --release
sudo kill $RECORD_PID
```

**Capture a deployment:**
```bash
sudo ../target/release/cognitod --record /tmp/deploy-events.ndjson &
RECORD_PID=$!
kubectl apply -f deployment.yaml
sleep 60
sudo kill $RECORD_PID
```

### Analyzing Recordings

**Count events by type:**
```bash
jq '.event.base.event_type' sample-events.ndjson | sort | uniq -c
```

**Extract unique commands:**
```bash
jq -r '.event.base.comm | @json' sample-events.ndjson | \
  python3 -c "import sys, json; [print(bytes(json.loads(line)).decode('utf-8', errors='ignore').rstrip('\x00')) for line in sys.stdin]" | \
  sort | uniq
```

**Find events for specific PID:**
```bash
jq 'select(.event.base.pid == 370104)' sample-events.ndjson
```

### Fork Storm Testing (Automated)

**Quick automated test:**
```bash
cd examples/record-replay
sudo ./test_fork_storm.sh
```

This will:
1. Start recording
2. Generate a medium-intensity fork storm for 10 seconds
3. Stop recording
4. Replay with detection rules
5. Verify detections occurred

**Customize intensity:**
```bash
# Low intensity (10 forks/sec, good for threshold testing)
sudo ./test_fork_storm.sh --intensity low

# Medium intensity (50 forks/sec, default)
sudo ./test_fork_storm.sh --intensity medium

# High intensity (100 forks/sec, stress testing)
sudo ./test_fork_storm.sh --intensity high --duration 15

# Extreme intensity (200 forks/sec, may stress system)
sudo ./test_fork_storm.sh --intensity extreme --duration 5
```

**Keep recording for analysis:**
```bash
sudo ./test_fork_storm.sh --intensity high --keep-recording
# Recording saved to /tmp/fork-storm-*.ndjson
```

**Manual fork storm generation:**
```bash
# Just generate the storm without recording
./generate_fork_storm.sh --intensity medium --duration 10

# With custom recording
sudo ../target/release/cognitod --record /tmp/my-test.ndjson &
RECORD_PID=$!
./generate_fork_storm.sh --intensity high --duration 15
sudo kill $RECORD_PID

# Replay
sudo ../target/release/cognitod --replay /tmp/my-test.ndjson \
  --handler rules:fork-storm-rules.yaml --replay-speed 5.0
```

### Testing Detection Rules (Manual)

**Test fork storm detection (manual method):**
```bash
# Generate fork storm during recording
(while true; do (sleep 0.1 &); done) &
STORM_PID=$!

sudo ../target/release/cognitod --record /tmp/fork-storm.ndjson &
RECORD_PID=$!
sleep 10
sudo kill $RECORD_PID $STORM_PID

# Verify detection during replay
sudo ../target/release/cognitod --replay /tmp/fork-storm.ndjson \
  --handler rules:configs/rules.yaml
```

## File Size Estimates

- **~250 bytes per event** (with JSON formatting)
- **1000 events/sec** ≈ 250 KB/sec ≈ 15 MB/minute
- **High activity workload** ≈ 20-50 GB/day
- **Typical SSH session** ≈ 50-100 KB (200-400 events)

## Limitations (Phase 1)

The current implementation records **only process events**:

✅ **Works:**
- Process lifecycle (fork/exec/exit)
- Fork storm detection
- Process tree analysis
- Command execution patterns

❌ **Not yet supported:**
- System snapshots (CPU, memory, PSI metrics)
- Circuit breaker incidents
- Real-time resource thresholds

These will be added in Phase 2 (see `docs/RECORD_REPLAY_PLAN.md`).

## Troubleshooting

**Error: "Cannot use --record and --replay simultaneously"**
- These flags are mutually exclusive - use one or the other

**No events recorded:**
- Ensure cognitod has CAP_BPF and CAP_PERFMON capabilities
- Check that the eBPF programs are loaded (no errors at startup)
- Try generating some activity in another terminal

**Replay timing seems off:**
- The replay speed is based on the **time between events**, not wall clock time
- Use `--replay-speed` to adjust (higher = faster, lower = slower)

## Contributing

To add new examples:
1. Record interesting workloads or scenarios
2. Compress large files: `gzip sample-events.ndjson`
3. Document what the recording contains
4. Submit a PR with the recording and updated README

## See Also

- [Full Implementation Plan](../../docs/RECORD_REPLAY_PLAN.md)
- [Testing Guide](../../docs/RECORD_REPLAY_PLAN.md#quick-start-guide)
- [Build Instructions](../../README.md)
