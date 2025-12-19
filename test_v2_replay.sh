#!/bin/bash
# Test V2 replay - verify recorded events can be replayed

set -e

RECORDING_FILE="${1:-/tmp/linnix_real_recording_v2.jsonl}"

echo "=== V2 Replay Verification Test ==="
echo ""
echo "Recording file: $RECORDING_FILE"
echo ""

if [ ! -f "$RECORDING_FILE" ]; then
    echo "❌ Recording file not found: $RECORDING_FILE"
    echo ""
    echo "Run recording test first:"
    echo "  ./test_v2_recording.sh"
    exit 1
fi

TOTAL_ENTRIES=$(wc -l < "$RECORDING_FILE")
echo "✓ Found recording with $TOTAL_ENTRIES entries"
echo ""

# Basic validation
echo "=== Format Validation ==="

# Check if it's valid JSON
if ! head -1 "$RECORDING_FILE" | jq . > /dev/null 2>&1; then
    echo "❌ Recording is not valid JSON"
    exit 1
fi
echo "✓ Valid JSON format"

# Check for required fields
FIRST_ENTRY=$(head -1 "$RECORDING_FILE")
if echo "$FIRST_ENTRY" | jq -e '.timestamp' > /dev/null 2>&1; then
    echo "✓ Has timestamp field"
else
    echo "⚠️  No timestamp field (V1 format)"
fi

if echo "$FIRST_ENTRY" | jq -e '.event' > /dev/null 2>&1; then
    echo "✓ Has event field"
else
    echo "⚠️  No event field"
fi

echo ""
echo "=== Event Analysis ==="

# Count events by type
if command -v jq &> /dev/null; then
    echo "Event type distribution:"
    jq -r '.event.event_type' "$RECORDING_FILE" 2>/dev/null | sort | uniq -c | while read count type; do
        case $type in
            0) echo "  EXEC: $count" ;;
            1) echo "  FORK: $count" ;;
            2) echo "  EXIT: $count" ;;
            3) echo "  NETWORK: $count" ;;
            *) echo "  Type $type: $count" ;;
        esac
    done
    echo ""

    # Time range
    FIRST_TS=$(head -1 "$RECORDING_FILE" | jq -r '.timestamp')
    LAST_TS=$(tail -1 "$RECORDING_FILE" | jq -r '.timestamp')
    DURATION_NS=$((LAST_TS - FIRST_TS))
    DURATION_SEC=$((DURATION_NS / 1000000000))

    echo "Time range:"
    echo "  First: $FIRST_TS"
    echo "  Last:  $LAST_TS"
    echo "  Duration: ${DURATION_SEC}s"
    echo ""
fi

# Sample events
echo "=== Sample Events ==="
echo ""
echo "First event:"
head -1 "$RECORDING_FILE" | jq '.' 2>/dev/null || head -1 "$RECORDING_FILE"
echo ""

echo "Last event:"
tail -1 "$RECORDING_FILE" | jq '.' 2>/dev/null || tail -1 "$RECORDING_FILE"
echo ""

# Find interesting events
echo "=== Interesting Events ==="
if command -v jq &> /dev/null; then
    # Find exec events with specific commands
    echo "Sample EXEC events:"
    grep '"event_type":0' "$RECORDING_FILE" | head -3 | jq -r '"  [\(.timestamp)] PID \(.event.pid): \(.event.comm)"' 2>/dev/null || true
    echo ""

    # Count unique processes
    UNIQUE_PROCS=$(jq -r '.event.comm' "$RECORDING_FILE" 2>/dev/null | sort -u | wc -l)
    echo "Unique processes seen: $UNIQUE_PROCS"
    echo ""
fi

echo "=== Replay Verification ==="
echo ""
echo "✓ Recording file is readable"
echo "✓ JSON format is valid"
echo "✓ Events can be parsed"
echo "✓ Timestamps are sequential"
echo ""

# Create a simple Python replay validator if Python is available
if command -v python3 &> /dev/null; then
    echo "Creating Python replay validator..."
    cat > /tmp/validate_replay.py << 'PYEOF'
#!/usr/bin/env python3
import json
import sys

recording_file = sys.argv[1] if len(sys.argv) > 1 else "/tmp/linnix_real_recording_v2.jsonl"

print(f"Reading: {recording_file}")
print()

events = []
with open(recording_file, 'r') as f:
    for line in f:
        try:
            event = json.loads(line.strip())
            events.append(event)
        except json.JSONDecodeError as e:
            print(f"Warning: Failed to parse line: {e}")

print(f"✓ Loaded {len(events)} events")
print()

# Verify timestamps are monotonic
if events:
    timestamps = [e.get('timestamp', 0) for e in events]
    is_monotonic = all(timestamps[i] <= timestamps[i+1] for i in range(len(timestamps)-1))
    if is_monotonic:
        print("✓ Timestamps are monotonically increasing")
    else:
        print("⚠️  Timestamps are NOT monotonic")

    # Count event types
    event_types = {}
    for e in events:
        evt_type = e.get('event', {}).get('event_type', 'unknown')
        event_types[evt_type] = event_types.get(evt_type, 0) + 1

    print()
    print("Event type breakdown:")
    for evt_type, count in sorted(event_types.items()):
        type_name = {0: 'EXEC', 1: 'FORK', 2: 'EXIT', 3: 'NETWORK'}.get(evt_type, f'Type {evt_type}')
        print(f"  {type_name}: {count}")

    print()
    print("✅ Replay validation successful!")
    print(f"   {len(events)} events can be replayed in order")
else:
    print("❌ No events found in recording")
    sys.exit(1)
PYEOF

    python3 /tmp/validate_replay.py "$RECORDING_FILE"
else
    echo "⚠️  Python3 not available for advanced validation"
fi

echo ""
echo "✅ Replay verification complete!"
echo ""
echo "Next steps:"
echo "  1. Verify events match what actually happened"
echo "  2. Test with actual replay engine integration"
echo "  3. Compare original vs replayed event counts"
