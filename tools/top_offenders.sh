#!/bin/bash
# Top Offenders - Find resource hogs and noisy neighbors

BASE_URL="${LINNIX_URL:-http://127.0.0.1:3000}"

CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}${BOLD}═══ Top Resource Offenders ═══${NC}"
echo ""

# Get status for top processes
status=$(curl -s "$BASE_URL/status")

echo -e "${BOLD}Top CPU Consumers:${NC}"
echo -e "     ${CYAN}PID     Command          CPU%    Pod/Namespace${NC}"
echo "$status" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for proc in data.get("top_cpu", [])[:10]:
    k8s = proc.get("k8s", {}) or {}
    pod = k8s.get("pod_name", "-")[:15] if k8s else "-"
    ns = k8s.get("namespace", "-")[:15] if k8s else "-"
    pid = proc["pid"]
    comm = proc["comm"][:15]
    cpu = proc["cpu_percent"]
    print(f"  {pid:>8} {comm:<15} {cpu:>6.1f}%  {pod}/{ns}")
'

echo ""
echo -e "${BOLD}Top Memory Consumers:${NC}"
echo -e "     ${CYAN}PID     Command          MEM%    Pod/Namespace${NC}"
echo "$status" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for proc in data.get("top_rss", [])[:10]:
    k8s = proc.get("k8s", {}) or {}
    pod = k8s.get("pod_name", "-")[:15] if k8s else "-"
    ns = k8s.get("namespace", "-")[:15] if k8s else "-"
    pid = proc["pid"]
    comm = proc["comm"][:15]
    mem = proc["mem_percent"]
    print(f"  {pid:>8} {comm:<15} {mem:>6.1f}%  {pod}/{ns}")
'

echo ""
echo -e "${BOLD}Note:${NC}"
echo "  For detailed PSI attribution analysis, use: ./attribution_report.sh"
