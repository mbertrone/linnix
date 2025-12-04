#!/bin/bash
# Incident Timeline - Visualize incident history over time

BASE_URL="${LINNIX_URL:-http://127.0.0.1:3000}"

CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}${BOLD}═══ Incident Timeline ═══${NC}"
echo ""

incidents=$(curl -s "$BASE_URL/incidents")

# Group by time buckets (hourly)
echo "$incidents" | python3 << 'EOF'
import json, sys
from datetime import datetime, timedelta
from collections import defaultdict

incidents = json.load(sys.stdin)
if not incidents:
    print("No incidents found")
    sys.exit(0)

# Group by hour
hourly = defaultdict(list)
for inc in incidents:
    dt = datetime.fromtimestamp(inc['timestamp'])
    hour_key = dt.strftime('%Y-%m-%d %H:00')
    hourly[hour_key].append(inc)

# Sort by time
sorted_hours = sorted(hourly.keys())

print(f"Timeline: {sorted_hours[0]} to {sorted_hours[-1]}")
print("")

# Display timeline
for hour in sorted_hours[-24:]:  # Last 24 hours
    count = len(hourly[hour])
    bar = "█" * min(count, 50)
    print(f"{hour}  {bar} ({count})")

# Show patterns
print("")
print("Pattern Analysis:")

# Time of day distribution
hour_dist = defaultdict(int)
for inc in incidents:
    dt = datetime.fromtimestamp(inc['timestamp'])
    hour_dist[dt.hour] += 1

peak_hour = max(hour_dist.items(), key=lambda x: x[1])
print(f"  Peak Hour: {peak_hour[0]}:00 ({peak_hour[1]} incidents)")

# By type
type_dist = defaultdict(int)
for inc in incidents:
    type_dist[inc['event_type']] += 1

print("  By Type:")
for event_type, count in sorted(type_dist.items(), key=lambda x: -x[1]):
    print(f"    {event_type}: {count}")

# Recovery time stats
recovery_times = [inc.get('recovery_time_ms') for inc in incidents if inc.get('recovery_time_ms')]
if recovery_times:
    avg_recovery = sum(recovery_times) / len(recovery_times)
    print(f"  Avg Recovery: {avg_recovery:.0f}ms")
EOF
