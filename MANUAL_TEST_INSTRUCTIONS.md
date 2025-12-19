# Manual Testing Instructions for Record/Replay V2

This guide walks you through manually testing the record/replay functionality step-by-step, showing you exactly what the automated scripts do.

## Prerequisites

Check that you have everything needed:

```bash
# 1. Verify cognitod binary exists
ls -lh target/release/cognitod

# 2. Verify eBPF binaries exist
ls -lh target/bpfel-unknown-none/release/linnix-ai-ebpf-ebpf
ls -lh target/bpfel-unknown-none/release/rss_trace

# 3. Check you have required tools
which jq || echo "Install jq: sudo apt-get install jq"
which python3 || echo "Python3 not found"
```

## Part 1: Manual Recording Test

### Step 1: Prepare Test Environment

```bash
# Set variables
RECORDING_FILE="/tmp/linnix_manual_recording.jsonl"
RULES_FILE="/tmp/manual_test_rules.yaml"

# Clean up any existing recording
rm -f "$RECORDING_FILE"
```

### Step 2: Create Test Rules File

```bash
# Create a simple rules file
cat > "$RULES_FILE" << 'EOF'
rules:
  - name: "test_any_activity"
    detector:
      type: "exec_rate"
      threshold: 1.0
      duration_secs: 1
    action:
      notify: true
      kill: false
EOF

# Verify rules file
cat "$RULES_FILE"
```

### Step 3: Start cognitod with Recording

Open a **first terminal** and run:

```bash
# Run cognitod with recording enabled
sudo ./target/release/cognitod \
    --handler "rules:/tmp/manual_test_rules.yaml" \
    --record /tmp/linnix_manual_recording.jsonl
```

**What to watch for:**
- `[cognitod] Recording eBPF events to /tmp/linnix_manual_recording.jsonl`
- `[cognitod] Attached RSS probes: ...`
- `[cognitod] eBPF runtime ready`

### Step 4: Generate System Activity

While cognitod is running, open a **second terminal** and run:

```bash
# Generate some process activity
echo "Generating activity..."

for i in {1..10}; do
    echo "Event $i"
    ls -la /tmp > /dev/null 2>&1
    ps aux | head -5 > /dev/null 2>&1
    sleep 1
done

echo "Activity generation complete"
```

### Step 5: Let Recording Run

Let cognitod run for **30-60 seconds** to capture events, then:

In the **first terminal** where cognitod is running:
- Press `Ctrl+C` to stop cognitod
- It will gracefully shut down and close the recording file

### Step 6: Verify Recording Was Created

```bash
# Check if file exists and its size
ls -lh /tmp/linnix_manual_recording.jsonl

# Count total events captured
wc -l /tmp/linnix_manual_recording.jsonl

# Expected: Hundreds to thousands of lines depending on system activity
```

## Part 2: Manual Recording Analysis

### Step 1: Examine Recording Format

```bash
# View first 3 raw events
head -3 /tmp/linnix_manual_recording.jsonl

# Pretty-print first event with jq
head -1 /tmp/linnix_manual_recording.jsonl | jq '.'
```

**What to look for:**
- `timestamp` field (nanoseconds since epoch)
- `event` field with nested `base` structure
- `event_type`: 0=EXEC, 1=FORK, 2=EXIT
- `pid`, `ppid`, `uid`, `gid`
- `comm` array (command name as bytes)
- `cpu_pct_milli` and `mem_pct_milli`

### Step 2: Count Event Types

```bash
# Extract and count event types
jq -r '.event.base.event_type' /tmp/linnix_manual_recording.jsonl | sort | uniq -c

# Expected output example:
#    1234 0    <- EXEC events
#    2345 1    <- FORK events
#    2340 2    <- EXIT events
```

### Step 3: Analyze RSS Tracking Data

```bash
# Count RSS measurement values
jq -r '.event.base.mem_pct_milli' /tmp/linnix_manual_recording.jsonl | sort | uniq -c

# Expected output:
#    XXXX 0       <- RSS measured but 0%
#    XXXX 65535   <- RSS not measured (PERCENT_MILLI_UNKNOWN)
```

**Key Finding:**
- Events with `mem_pct_milli = 0` have RSS measured but show 0%
- Events with `mem_pct_milli = 65535` don't have RSS measurement

### Step 4: Verify Which Events Get RSS Measurement

```bash
# Show event types that have RSS = 0 (measured)
jq -r 'select(.event.base.mem_pct_milli == 0) | .event.base.event_type' \
    /tmp/linnix_manual_recording.jsonl | sort | uniq -c

# Expected: Only event_type 0 (EXEC)

# Show event types that have RSS = 65535 (not measured)
jq -r 'select(.event.base.mem_pct_milli == 65535) | .event.base.event_type' \
    /tmp/linnix_manual_recording.jsonl | sort | uniq -c

# Expected: event_type 1 (FORK) and 2 (EXIT)
```

**Critical Validation:**
✅ EXEC events get RSS measurement (at process startup)
✅ RSS is 0% because processes just started (confirms our analysis!)
✅ FORK/EXIT events don't get RSS measurement

### Step 5: Extract Sample Events

```bash
# Find first EXEC event (event_type: 0)
grep -m 1 '"event_type":0' /tmp/linnix_manual_recording.jsonl | jq .

# Find first FORK event (event_type: 1)
grep -m 1 '"event_type":1' /tmp/linnix_manual_recording.jsonl | jq .

# Find first EXIT event (event_type: 2)
grep -m 1 '"event_type":2' /tmp/linnix_manual_recording.jsonl | jq .
```

### Step 6: Decode Command Names

```bash
# Extract and decode command names from events
jq -r '.event.base.comm | map(select(. != 0)) | implode' \
    /tmp/linnix_manual_recording.jsonl | head -10

# This converts byte arrays to strings
```

### Step 7: Calculate Recording Statistics

```bash
# Get time range
FIRST_TS=$(head -1 /tmp/linnix_manual_recording.jsonl | jq -r '.timestamp')
LAST_TS=$(tail -1 /tmp/linnix_manual_recording.jsonl | jq -r '.timestamp')

# Calculate duration in seconds
DURATION_NS=$((LAST_TS - FIRST_TS))
DURATION_SEC=$((DURATION_NS / 1000000000))

echo "Recording Statistics:"
echo "  First timestamp: $FIRST_TS"
echo "  Last timestamp:  $LAST_TS"
echo "  Duration: ${DURATION_SEC} seconds"

# Calculate events per second
TOTAL_EVENTS=$(wc -l < /tmp/linnix_manual_recording.jsonl)
EPS=$((TOTAL_EVENTS / DURATION_SEC))

echo "  Total events: $TOTAL_EVENTS"
echo "  Events/second: $EPS"
```

## Part 3: Manual Replay Verification

### Step 1: Validate JSON Format

```bash
# Test if first line is valid JSON
head -1 /tmp/linnix_manual_recording.jsonl | jq . > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "✓ Valid JSON format"
else
    echo "✗ Invalid JSON format"
fi
```

### Step 2: Check Required Fields

```bash
# Verify first event has all required fields
FIRST_EVENT=$(head -1 /tmp/linnix_manual_recording.jsonl)

echo "Checking required fields:"

echo "$FIRST_EVENT" | jq -e '.timestamp' > /dev/null && echo "  ✓ timestamp" || echo "  ✗ timestamp"
echo "$FIRST_EVENT" | jq -e '.event' > /dev/null && echo "  ✓ event" || echo "  ✗ event"
echo "$FIRST_EVENT" | jq -e '.event.base' > /dev/null && echo "  ✓ event.base" || echo "  ✗ event.base"
echo "$FIRST_EVENT" | jq -e '.event.base.pid' > /dev/null && echo "  ✓ pid" || echo "  ✗ pid"
echo "$FIRST_EVENT" | jq -e '.event.base.event_type' > /dev/null && echo "  ✓ event_type" || echo "  ✗ event_type"
```

### Step 3: Verify Timestamp Ordering

Create a simple Python script to check timestamp monotonicity:

```bash
cat > /tmp/check_timestamps.py << 'PYEOF'
#!/usr/bin/env python3
import json
import sys

filename = sys.argv[1] if len(sys.argv) > 1 else "/tmp/linnix_manual_recording.jsonl"

timestamps = []
with open(filename, 'r') as f:
    for line_num, line in enumerate(f, 1):
        try:
            event = json.loads(line.strip())
            ts = event.get('timestamp', 0)
            timestamps.append(ts)
        except json.JSONDecodeError as e:
            print(f"Warning: Line {line_num} invalid JSON")

print(f"Loaded {len(timestamps)} timestamps")

# Check if mostly monotonic (allow some out-of-order from multi-CPU)
out_of_order = 0
for i in range(len(timestamps) - 1):
    if timestamps[i] > timestamps[i+1]:
        out_of_order += 1

percentage = (out_of_order / len(timestamps)) * 100

print(f"Out-of-order events: {out_of_order} ({percentage:.2f}%)")

if percentage < 5:
    print("✓ Timestamps are mostly monotonic (< 5% out of order)")
else:
    print("⚠️  Many out-of-order events (multi-CPU timing)")
PYEOF

chmod +x /tmp/check_timestamps.py
python3 /tmp/check_timestamps.py /tmp/linnix_manual_recording.jsonl
```

### Step 4: Create Event Summary

```bash
cat > /tmp/summarize_recording.py << 'PYEOF'
#!/usr/bin/env python3
import json
import sys
from collections import Counter

filename = sys.argv[1] if len(sys.argv) > 1 else "/tmp/linnix_manual_recording.jsonl"

events = []
with open(filename, 'r') as f:
    for line in f:
        try:
            events.append(json.loads(line.strip()))
        except:
            pass

print(f"=== Recording Summary ===")
print(f"Total events: {len(events)}")
print()

# Count event types
event_types = Counter()
rss_values = Counter()
cpu_values = Counter()
processes = set()

for e in events:
    base = e.get('event', {}).get('base', {})
    event_types[base.get('event_type', 'unknown')] += 1
    rss_values[base.get('mem_pct_milli', 'unknown')] += 1
    cpu_values[base.get('cpu_pct_milli', 'unknown')] += 1

    # Decode comm
    comm_bytes = base.get('comm', [])
    if comm_bytes:
        comm = ''.join(chr(b) for b in comm_bytes if b != 0)
        if comm:
            processes.add(comm)

print("Event Types:")
for evt_type, count in sorted(event_types.items()):
    type_name = {0: 'EXEC', 1: 'FORK', 2: 'EXIT'}.get(evt_type, f'Type {evt_type}')
    print(f"  {type_name}: {count}")

print()
print("RSS Measurement:")
for rss_val, count in sorted(rss_values.items()):
    if rss_val == 0:
        print(f"  RSS = 0%: {count} events")
    elif rss_val == 65535:
        print(f"  RSS = UNKNOWN: {count} events")
    else:
        print(f"  RSS = {rss_val}: {count} events")

print()
print(f"Unique processes: {len(processes)}")
print("Sample processes:", list(processes)[:10])
PYEOF

chmod +x /tmp/summarize_recording.py
python3 /tmp/summarize_recording.py /tmp/linnix_manual_recording.jsonl
```

### Step 5: Test Replay Capability (Conceptual)

The recording can be replayed by:

```bash
# 1. Load all events
cat /tmp/linnix_manual_recording.jsonl | jq -c '.' > /tmp/replay_events.jsonl

# 2. Sort by timestamp (if needed)
cat /tmp/linnix_manual_recording.jsonl | \
    jq -s 'sort_by(.timestamp)' > /tmp/sorted_events.json

# 3. Process events in order
jq -c '.[]' /tmp/sorted_events.json | while read event; do
    echo "$event" | jq -r '"[\(.timestamp)] PID: \(.event.base.pid) Type: \(.event.base.event_type)"'
done | head -20
```

## Part 4: RSS Tracking Issue Validation

### Confirm the Issue

Run these commands to prove the RSS tracking limitation:

```bash
echo "=== RSS Tracking Analysis ==="
echo ""

# 1. Count events with RSS measured
RSS_MEASURED=$(jq -r 'select(.event.base.mem_pct_milli != 65535) | .event.base.mem_pct_milli' \
    /tmp/linnix_manual_recording.jsonl | wc -l)

# 2. Count events with RSS = 0
RSS_ZERO=$(jq -r 'select(.event.base.mem_pct_milli == 0) | .event.base.mem_pct_milli' \
    /tmp/linnix_manual_recording.jsonl | wc -l)

# 3. Count events with RSS unknown
RSS_UNKNOWN=$(jq -r 'select(.event.base.mem_pct_milli == 65535) | .event.base.mem_pct_milli' \
    /tmp/linnix_manual_recording.jsonl | wc -l)

echo "Events with RSS measured: $RSS_MEASURED"
echo "Events with RSS = 0%: $RSS_ZERO"
echo "Events with RSS unknown: $RSS_UNKNOWN"
echo ""

# 4. Prove only EXEC events get RSS
echo "Event types with RSS measured (should be only type 0 - EXEC):"
jq -r 'select(.event.base.mem_pct_milli == 0) | .event.base.event_type' \
    /tmp/linnix_manual_recording.jsonl | sort | uniq -c

echo ""
echo "✓ This confirms:"
echo "  - Only EXEC events get RSS measurement"
echo "  - RSS is always 0% because measured at startup"
echo "  - No RSS data for running processes"
echo "  - V2 snapshots will solve this by periodic sampling"
```

## Expected Results Summary

### Recording Phase
- ✅ cognitod starts and loads eBPF probes
- ✅ Recording file created and grows as events occur
- ✅ Hundreds to thousands of events captured per minute
- ✅ File size: ~270 bytes per event

### Analysis Phase
- ✅ Events have valid JSON format
- ✅ Three event types: EXEC (0), FORK (1), EXIT (2)
- ✅ RSS tracking shows limitation:
  - ~33% of events have `mem_pct_milli = 0` (EXEC events)
  - ~67% of events have `mem_pct_milli = 65535` (FORK/EXIT events)
- ✅ All events with RSS measurement are EXEC type
- ✅ RSS is always 0% confirming startup measurement issue

### Replay Phase
- ✅ Recording is valid JSON Lines format
- ✅ Events can be loaded and parsed
- ✅ Timestamps are mostly sequential (some multi-CPU reordering ok)
- ✅ Events can be replayed in chronological order
- ✅ All required fields present for replay

## Troubleshooting

### Issue: No recording file created

**Check:**
```bash
# Verify cognitod started successfully
sudo ./target/release/cognitod --record /tmp/test.jsonl 2>&1 | head -20

# Check permissions
ls -la /tmp/
```

### Issue: Very few events captured

**Check:**
```bash
# Verify eBPF probes loaded
sudo ./target/release/cognitod --probe-only

# Check kernel version supports eBPF
uname -r
```

### Issue: jq command not found

**Install jq:**
```bash
sudo apt-get update
sudo apt-get install jq
```

### Issue: Permission denied

**Run with sudo:**
```bash
# cognitod needs root for eBPF
sudo ./target/release/cognitod --record /tmp/recording.jsonl
```

## What This Validates

1. ✅ **V1 Recording Works** - Real eBPF events captured successfully
2. ✅ **Replay Format Valid** - Events can be loaded and processed
3. ✅ **RSS Issue Confirmed** - Only EXEC events measured, always 0%
4. ✅ **V2 Solution Clear** - Periodic snapshots will provide RSS continuity
5. ✅ **Event Ordering Verified** - Timestamps allow chronological replay

## Next Steps

After validating manually:
1. Commit test scripts and results
2. Integrate V2 format into main.rs recording
3. Add periodic snapshot collection
4. Test with V2 unified format
5. Implement full replay engine integration
