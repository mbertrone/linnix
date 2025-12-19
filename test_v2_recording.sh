#!/bin/bash
# Test V2 recording with real cognitod

set -e

RECORDING_FILE="/tmp/linnix_real_recording_v2.jsonl"
RULES_FILE="/tmp/test_rules.yaml"

echo "=== V2 Recording Test ==="
echo ""

# Clean up any existing recording
rm -f "$RECORDING_FILE"

# Create simple test rules
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

echo "✓ Created test rules: $RULES_FILE"
echo "✓ Recording will be saved to: $RECORDING_FILE"
echo ""
echo "Starting cognitod with V2 recording (will run for 30 seconds)..."
echo "Generating some system activity in parallel..."
echo ""

# Function to generate activity
generate_activity() {
    sleep 5
    echo "[Activity] Running some commands to generate events..."
    for i in {1..10}; do
        echo "  - Event $i"
        ls -la /tmp > /dev/null 2>&1
        ps aux | head -5 > /dev/null 2>&1
        sleep 1
    done
    echo "[Activity] Activity generation complete"
}

# Start activity generator in background
generate_activity &
ACTIVITY_PID=$!

# Run cognitod with recording
# Note: Currently using --record flag (V1 style)
# In future we'll integrate V2 format via config
timeout 30s sudo ./target/release/cognitod \
    --handler "rules:$RULES_FILE" \
    --record "$RECORDING_FILE" \
    2>&1 | grep -E "(Recording|events recorded|INFO)" || true

# Wait for activity generator
wait $ACTIVITY_PID 2>/dev/null || true

echo ""
echo "=== Recording Complete ==="
echo ""

# Check if recording was created
if [ ! -f "$RECORDING_FILE" ]; then
    echo "❌ Recording file not created!"
    exit 1
fi

# Analyze the recording
TOTAL_LINES=$(wc -l < "$RECORDING_FILE")
echo "✓ Recording file created: $RECORDING_FILE"
echo "  Total entries: $TOTAL_LINES"
echo ""

# Show first few entries
echo "=== First 3 entries ==="
head -3 "$RECORDING_FILE" | jq -r '. | "[\(.timestamp)] \(.event.event_type // "unknown") - PID: \(.event.pid // "N/A") \(.event.comm // "")"' 2>/dev/null || head -3 "$RECORDING_FILE"
echo ""

# Count event types if jq is available
if command -v jq &> /dev/null; then
    echo "=== Event Type Summary ==="
    jq -r '.event.event_type' "$RECORDING_FILE" 2>/dev/null | sort | uniq -c | while read count type; do
        case $type in
            0) echo "  EXEC: $count events" ;;
            1) echo "  FORK: $count events" ;;
            2) echo "  EXIT: $count events" ;;
            *) echo "  Type $type: $count events" ;;
        esac
    done
    echo ""
fi

echo "=== Sample Events ==="
echo "First EXEC event:"
grep -m 1 '"event_type":0' "$RECORDING_FILE" | jq . 2>/dev/null || grep -m 1 '"event_type":0' "$RECORDING_FILE"
echo ""

echo "✅ Test complete!"
echo ""
echo "Recording saved at: $RECORDING_FILE"
echo "View it with: cat $RECORDING_FILE | jq ."
echo "Or: less $RECORDING_FILE"
