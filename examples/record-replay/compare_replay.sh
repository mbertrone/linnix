#!/bin/sh

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
