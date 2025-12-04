# Record/Replay Examples

This directory contains sample recorded eBPF events and instructions for using the record/replay functionality.

## What is Record/Replay?

The record/replay feature allows you to:
- **Record** live eBPF process events to an NDJSON file
- **Replay** those events later for testing, debugging, or analysis
- Test detection rules and handlers without needing live workloads
- Share reproducible test cases with your team

## Sample Data

**`sample-events.ndjson`** - A sample recording containing ~270 process events captured during a typical SSH session, including:
- SSH connection and authentication (sshd, PAM modules)
- Shell initialization (bash, run-parts)
- System utilities (landscape-sysinfo, motd scripts)
- Various command executions

## Quick Start

### 1. Replay the Sample Events

```bash
# Replay at normal speed (respects original timing)
sudo ../target/release/cognitod --replay examples/record-replay/sample-events.ndjson

# Replay at 10x speed (faster testing)
sudo ../target/release/cognitod --replay examples/record-replay/sample-events.ndjson --replay-speed 10.0

# Replay with rules engine active
sudo ../target/release/cognitod --replay examples/record-replay/sample-events.ndjson \
  --handler rules:configs/rules.yaml
```

### 2. Record Your Own Events

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

### Testing Detection Rules

**Test fork storm detection:**
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
