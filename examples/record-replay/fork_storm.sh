#!/bin/bash
#
# Simple Fork Storm Generator
#
# Generates a controlled fork storm for testing detection rules.
#
# Usage:
#   ./fork_storm.sh [FORKS_PER_SEC] [DURATION]
#
# Examples:
#   ./fork_storm.sh           # Default: 50 forks/sec for 10 seconds
#   ./fork_storm.sh 100 15    # 100 forks/sec for 15 seconds
#   ./fork_storm.sh 200 5     # 200 forks/sec for 5 seconds

# Note: NOT using set -e to avoid exit on conditions
set -uo pipefail

# Logging function
log_info() {
    echo "[$(date +'%H:%M:%S')] [INFO] $*"
}

# Parameters
FORKS_PER_SEC=${1:-50}
DURATION=${2:-10}

log_info "Fork Storm Generator starting (PID: $$)"

# Validate inputs
if ! [[ "$FORKS_PER_SEC" =~ ^[0-9]+$ ]] || [[ "$FORKS_PER_SEC" -lt 1 ]]; then
    echo "Error: FORKS_PER_SEC must be a positive integer" >&2
    exit 1
fi

if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || [[ "$DURATION" -lt 1 ]]; then
    echo "Error: DURATION must be a positive integer" >&2
    exit 1
fi

# Cleanup on exit
cleanup() {
    log_info "Cleaning up background processes..."
    jobs -p | xargs -r kill 2>/dev/null || true
    wait 2>/dev/null || true
    log_info "Cleanup complete"
}
trap cleanup EXIT INT TERM

# Calculate delay
DELAY_SEC=$(awk "BEGIN {printf \"%.3f\", 1.0 / $FORKS_PER_SEC}")

log_info "Configuration:"
log_info "  Rate: $FORKS_PER_SEC forks/second"
log_info "  Duration: $DURATION seconds"
log_info "  Delay: ${DELAY_SEC}s between forks"
log_info "  Expected total: ~$((FORKS_PER_SEC * DURATION)) forks"
echo ""

# Warn for high rates
if [[ $FORKS_PER_SEC -gt 100 ]]; then
    log_info "WARNING: High fork rate - may stress system (waiting 2s)..."
    sleep 2
fi

log_info "Starting fork storm..."
echo ""

# Track forks
FORK_COUNT=0
START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION))

# Main loop
while true; do
    CURRENT_TIME=$(date +%s)

    # Check if we've reached the duration
    if [[ $CURRENT_TIME -ge $END_TIME ]]; then
        break
    fi

    # Fork a short-lived process
    (exec sleep 0.05) &
    FORK_COUNT=$((FORK_COUNT + 1))

    # Log progress every second
    ELAPSED=$((CURRENT_TIME - START_TIME))
    if [[ $((FORK_COUNT % FORKS_PER_SEC)) -eq 0 ]]; then
        RATE=$((FORK_COUNT / (ELAPSED + 1)))
        log_info "Progress: ${ELAPSED}s / ${DURATION}s | Forks: $FORK_COUNT | Rate: ~${RATE}/s"
    fi

    # Control fork rate
    sleep "$DELAY_SEC" || sleep 0.001
done

ACTUAL_DURATION=$(($(date +%s) - START_TIME))
if [[ $ACTUAL_DURATION -gt 0 ]]; then
    ACTUAL_RATE=$((FORK_COUNT / ACTUAL_DURATION))
else
    ACTUAL_RATE=$FORK_COUNT
fi

echo ""
log_info "Fork storm complete!"
log_info "  Total forks: $FORK_COUNT"
log_info "  Duration: ${ACTUAL_DURATION}s"
log_info "  Actual rate: ${ACTUAL_RATE}/s"
log_info "  Efficiency: $(( (ACTUAL_RATE * 100) / FORKS_PER_SEC ))%"
echo ""

exit 0
