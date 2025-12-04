#!/bin/bash
# Action Audit - Show action history and outcomes

BASE_URL="${LINNIX_URL:-http://127.0.0.1:3000}"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}${BOLD}═══ Action Audit Log ═══${NC}"
echo ""

actions=$(curl -s "$BASE_URL/actions")

if [ "$actions" = "[]" ] || [ -z "$actions" ]; then
    echo "No actions found"
    exit 0
fi

echo "$actions" | python3 -c '
import json, sys
from datetime import datetime
from collections import Counter

actions = json.load(sys.stdin)

# Statistics
total = len(actions)
by_status = Counter(a["status"] for a in actions)
by_type = Counter(a["action"]["type"] for a in actions)
by_source = Counter(a["source"] for a in actions)

print(f"Total Actions: {total}")
print("")

print("By Status:")
for status, count in by_status.items():
    print(f"  {status}: {count}")
print("")

print("By Type:")
for action_type, count in by_type.items():
    print(f"  {action_type}: {count}")
print("")

print("By Source:")
for source, count in by_source.items():
    print(f"  {source}: {count}")
print("")

print("Recent Actions:")
print("")

for action in actions[:10]:
    status = action["status"]
    status_icon = "✓" if status == "approved" else "✗" if status == "rejected" else "⏸"
    created = datetime.fromtimestamp(action["created_at"]).strftime("%Y-%m-%d %H:%M:%S")
    aid = action["id"]
    atype = action["action"]["type"]
    reason = action["reason"]
    print(f"{status_icon} [{aid}] {status}")
    print(f"   {atype} - {created}")
    print(f"   {reason}")
    print("")
'
