#!/bin/bash
# Attribution Report - PSI attribution analysis for K8s

BASE_URL="${LINNIX_URL:-http://127.0.0.1:3000}"

CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}${BOLD}═══ PSI Attribution Report ═══${NC}"
echo ""

attribution=$(curl -s "$BASE_URL/attribution")

if [ -z "$attribution" ] || [ "$attribution" = "[]" ]; then
    echo "No attribution data available"
    echo ""
    echo "Attribution tracks which pods/processes contribute to system PSI."
    echo "Data may not be available if:"
    echo "  - Not running in Kubernetes"
    echo "  - No recent PSI pressure"
    echo "  - Attribution collection disabled"
    exit 0
fi

echo "$attribution" | python3 << 'EOF'
import json, sys
from collections import defaultdict

attributions = json.load(sys.stdin)

# Group by namespace
by_namespace = defaultdict(list)
for attr in attributions:
    ns = attr.get('offender_namespace', 'unknown')
    by_namespace[ns].append(attr)

# Sort by blame score
sorted_attr = sorted(attributions, key=lambda x: x.get('blame_score', 0), reverse=True)

print("Top PSI Contributors:")
print("")
print(f"{'Rank':<6} {'Pod Name':<30} {'Namespace':<20} {'Score':<10}")
print("-" * 76)

for idx, attr in enumerate(sorted_attr[:15], 1):
    pod = attr.get('offender_pod', 'unknown')[:29]
    ns = attr.get('offender_namespace', 'unknown')[:19]
    score = attr.get('blame_score', 0)
    print(f"{idx:<6} {pod:<30} {ns:<20} {score:<10.2f}")

print("")
print("By Namespace:")
print("")

for ns, attrs in sorted(by_namespace.items(), key=lambda x: len(x[1]), reverse=True):
    total_score = sum(a.get('blame_score', 0) for a in attrs)
    print(f"  {ns}: {len(attrs)} contributors, total score: {total_score:.2f}")

print("")
print("Analysis:")
total_contributors = len(attributions)
if total_contributors > 0:
    top_score = sorted_attr[0].get('blame_score', 0)
    print(f"  Total contributors: {total_contributors}")
    print(f"  Top offender score: {top_score:.2f}")
    if top_score > 50:
        print(f"  ⚠ High blame score detected - investigate {sorted_attr[0].get('offender_pod')}")
EOF
