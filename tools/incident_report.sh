#!/bin/bash
# Incident Report Generator - Create formatted incident reports

BASE_URL="${LINNIX_URL:-http://127.0.0.1:3000}"
FORMAT="${FORMAT:-txt}"

CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

show_help() {
    echo "Incident Report Generator"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --since <time>    Time range (e.g., 1h, 24h, 7d)"
    echo "  --type <type>     Filter by incident type"
    echo "  --format <fmt>    Output format: txt, md, json, csv (default: txt)"
    echo "  --help            Show this help"
}

generate_report() {
    local since="$1"
    local type_filter="$2"
    local format="$3"

    local url="$BASE_URL/incidents"
    if [ -n "$since" ]; then
        url="${url}?since=${since}"
    fi

    local incidents=$(curl -s "$url")
    local summary=$(curl -s "$BASE_URL/incidents/summary")

    if [ "$format" = "json" ]; then
        echo "$incidents" | python3 -m json.tool
        return
    fi

    if [ "$format" = "csv" ]; then
        echo "ID,Timestamp,Type,Target,PSI_CPU,CPU%,Action"
        echo "$incidents" | python3 << 'EOF'
import json, sys
from datetime import datetime
for inc in json.load(sys.stdin):
    ts = datetime.fromtimestamp(inc['timestamp']).strftime('%Y-%m-%d %H:%M:%S')
    print(f"{inc['id']},{ts},{inc['event_type']},{inc['target_name']},{inc['psi_cpu']},{inc['cpu_percent']},{inc['action']}")
EOF
        return
    fi

    # Text/Markdown format
    if [ "$format" = "md" ]; then
        echo "# Linnix Incident Report"
        echo ""
        echo "**Generated:** $(date)"
        echo ""
        echo "## Summary"
        echo ""
    else
        echo "═══════════════════════════════════════════════════════════"
        echo "           Linnix Incident Report"
        echo "═══════════════════════════════════════════════════════════"
        echo ""
        echo "Generated: $(date)"
        echo ""
        echo "SUMMARY"
        echo "-------"
    fi

    echo "$summary" | python3 << EOF
import json, sys
data = json.load(sys.stdin)
print(f"Total Incidents:     {data.get('total', 0)}")
print(f"Analyzed:            {data.get('analyzed', 0)}")
print(f"Pending Analysis:    {data.get('pending_analysis', 0)}")
print("")
print("By Type:")
for event_type, count in data.get('by_event_type', {}).items():
    print(f"  {event_type}: {count}")
EOF

    echo ""
    if [ "$format" = "md" ]; then
        echo "## Recent Incidents"
        echo ""
        echo "| ID | Time | Type | Target | PSI CPU | Action |"
        echo "|----|------|------|--------|---------|--------|"
    else
        echo "RECENT INCIDENTS"
        echo "----------------"
        echo ""
    fi

    echo "$incidents" | python3 << EOF
import json, sys
from datetime import datetime
incidents = json.load(sys.stdin)
for inc in incidents[:20]:
    ts = datetime.fromtimestamp(inc['timestamp']).strftime('%Y-%m-%d %H:%M:%S')
    if "$format" == "md":
        print(f"| {inc['id']} | {ts} | {inc['event_type']} | {inc['target_name']} | {inc['psi_cpu']:.1f}% | {inc['action']} |")
    else:
        print(f"[{inc['id']}] {ts} - {inc['event_type']}")
        print(f"    Target: {inc['target_name']} (PID {inc['target_pid']})")
        print(f"    PSI CPU: {inc['psi_cpu']:.1f}% | CPU: {inc['cpu_percent']:.1f}%")
        print(f"    Action: {inc['action']}")
        print("")
EOF
}

# Parse arguments
SINCE=""
TYPE_FILTER=""
while [ $# -gt 0 ]; do
    case "$1" in
        --since)
            SINCE="$2"
            shift 2
            ;;
        --type)
            TYPE_FILTER="$2"
            shift 2
            ;;
        --format)
            FORMAT="$2"
            shift 2
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

generate_report "$SINCE" "$TYPE_FILTER" "$FORMAT"
