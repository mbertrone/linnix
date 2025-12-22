#!/bin/bash
# Test script for PSI-based alerting
#
# This script demonstrates recording and replaying with PSI-sensitive alerts.
# The sensitive config has lower thresholds (50% CPU + 20% PSI) that are
# easier to trigger during testing.

set -e

echo "=== PSI-Based Alert Testing ==="
echo ""
echo "This test will:"
echo "1. Record system activity with PSI monitoring"
echo "2. Generate load to trigger PSI alerts"
echo "3. Replay the recording to verify alerts trigger"
echo ""

# Clean up old files
echo "Cleaning up old recordings..."
sudo rm -f /tmp/psi_test_recording.jsonl
sudo rm -f /var/log/linnix/alerts.ndjson

# Step 1: Start recording
echo ""
echo "Step 1: Starting recording with PSI-sensitive config..."
sudo RUST_LOG=info ./target/release/cognitod \
  --config cognitod/config-psi-sensitive.toml &
COGNITOD_PID=$!
echo "Recording started (PID: $COGNITOD_PID)"
sleep 3

# Step 2: Generate load
echo ""
echo "Step 2: Generating system load to trigger PSI alerts..."
echo "  - Creating CPU load (50%+)"
echo "  - This should trigger: CPU > 50% AND PSI > 20%"
echo ""

# CPU stress to trigger PSI
stress-ng --cpu 2 --timeout 20s &
STRESS_PID=$!

echo "Waiting 20 seconds for load to generate..."
sleep 20

# Wait for stress to complete
wait $STRESS_PID || true

echo ""
echo "Waiting 5 more seconds for final snapshots..."
sleep 5

# Step 3: Stop recording
echo ""
echo "Step 3: Stopping recording..."
sudo kill $COGNITOD_PID
sleep 2

# Step 4: Analyze recording
echo ""
echo "Step 4: Analyzing recorded PSI data..."
echo ""

if [ ! -f /tmp/psi_test_recording.jsonl ]; then
    echo "❌ Recording file not found!"
    exit 1
fi

TOTAL_ENTRIES=$(cat /tmp/psi_test_recording.jsonl | wc -l)
SNAPSHOTS=$(cat /tmp/psi_test_recording.jsonl | jq -r 'select(.type=="system_snapshot")' | wc -l)
echo "✅ Recording contains $TOTAL_ENTRIES entries ($SNAPSHOTS snapshots)"

echo ""
echo "PSI values during recording:"
cat /tmp/psi_test_recording.jsonl | \
  jq -r 'select(.type=="system_snapshot") |
  "\(.timestamp): CPU=\(.data.cpu_percent | round)% PSI_CPU=\(.data.psi_cpu_some_avg10 | round)% PSI_MEM=\(.data.psi_memory_some_avg10 | round)%"' | \
  head -10

echo ""
echo "Peak PSI values:"
cat /tmp/psi_test_recording.jsonl | \
  jq -r 'select(.type=="system_snapshot") | {
    time: .timestamp,
    cpu: (.data.cpu_percent | round),
    psi_cpu: (.data.psi_cpu_some_avg10 | round)
  } | "\(.time): CPU=\(.cpu)% PSI=\(.psi_cpu)%"' | \
  sort -t= -k3 -rn | head -5

# Step 5: Check alerts from live recording
echo ""
echo "Step 5: Checking alerts from live recording..."
if [ -f /var/log/linnix/alerts.ndjson ] && [ -s /var/log/linnix/alerts.ndjson ]; then
    ALERT_COUNT=$(cat /var/log/linnix/alerts.ndjson | wc -l)
    echo "✅ Generated $ALERT_COUNT alert(s) during recording:"
    sudo cat /var/log/linnix/alerts.ndjson | jq -r '"\(.rule): \(.message)"'

    # Backup live alerts
    sudo cp /var/log/linnix/alerts.ndjson /tmp/psi_live_alerts.ndjson
else
    echo "⚠️  No alerts generated during recording"
    echo "   (System may not have reached CPU=50% + PSI=20% threshold)"
fi

# Step 6: Replay
echo ""
echo "Step 6: Replaying recording to verify alert reproduction..."
sudo rm -f /var/log/linnix/alerts.ndjson

sudo RUST_LOG=info ./target/release/cognitod \
  --config cognitod/config-psi-sensitive.toml \
  --replay /tmp/psi_test_recording.jsonl \
  --replay-speed 10.0 2>&1 | \
  grep -E "\[replay\]|circuit_breaker" | head -20 &
REPLAY_PID=$!

echo "Replay started (PID: $REPLAY_PID), waiting for completion..."
sleep 10

# Kill replay if still running
sudo kill $REPLAY_PID 2>/dev/null || true
sleep 2

# Step 7: Compare alerts
echo ""
echo "Step 7: Comparing live vs replay alerts..."

if [ -f /tmp/psi_live_alerts.ndjson ]; then
    LIVE_COUNT=$(cat /tmp/psi_live_alerts.ndjson | wc -l)
    echo "Live recording: $LIVE_COUNT alert(s)"
fi

if [ -f /var/log/linnix/alerts.ndjson ] && [ -s /var/log/linnix/alerts.ndjson ]; then
    REPLAY_COUNT=$(cat /var/log/linnix/alerts.ndjson | wc -l)
    echo "Replay: $REPLAY_COUNT alert(s)"
    sudo cat /var/log/linnix/alerts.ndjson | jq -r '"\(.rule): \(.message)"'
else
    echo "Replay: 0 alert(s)"
fi

echo ""
echo "=== Test Complete ==="
echo ""
echo "Summary:"
echo "- Recording: /tmp/psi_test_recording.jsonl"
echo "- Live alerts: /tmp/psi_live_alerts.ndjson (if generated)"
echo "- Config: cognitod/config-psi-sensitive.toml"
echo ""
echo "Thresholds used:"
echo "- CPU > 50% AND PSI > 20% for 10+ seconds"
echo ""
echo "To view full replay with logs:"
echo "  sudo RUST_LOG=info ./target/release/cognitod \\"
echo "    --config cognitod/config-psi-sensitive.toml \\"
echo "    --replay /tmp/psi_test_recording.jsonl \\"
echo "    --replay-speed 10.0"
