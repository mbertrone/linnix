#!/bin/bash
# Process Tree - Interactive process tree explorer

BASE_URL="${LINNIX_URL:-http://127.0.0.1:3000}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

show_tree() {
    local pid="$1"
    local prefix="$2"
    local is_last="$3"

    # Get process info
    local proc=$(curl -s "$BASE_URL/processes/$pid")

    if [ -z "$proc" ] || [ "$proc" = "null" ]; then
        return
    fi

    local comm=$(echo "$proc" | python3 -c "import json,sys; print(json.load(sys.stdin).get('comm','unknown'))" 2>/dev/null)
    local mem_pct=$(echo "$proc" | python3 -c "import json,sys; print(json.load(sys.stdin).get('mem_pct',0))" 2>/dev/null)

    # Print current process
    if [ -n "$prefix" ]; then
        if [ "$is_last" = "true" ]; then
            echo -ne "${prefix}└─"
        else
            echo -ne "${prefix}├─"
        fi
    fi

    echo -e " ${CYAN}$pid${NC} ${BOLD}$comm${NC} (${mem_pct}%)"

    # Get children
    local children=$(curl -s "$BASE_URL/ppid/$pid")
    if [ -n "$children" ] && [ "$children" != "[]" ]; then
        local child_count=$(echo "$children" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
        local child_idx=0

        echo "$children" | python3 -c '
import json, sys
for proc in json.load(sys.stdin):
    print(proc["pid"])
' | while read -r child_pid; do
            child_idx=$((child_idx + 1))
            local new_prefix
            if [ -n "$prefix" ]; then
                if [ "$is_last" = "true" ]; then
                    new_prefix="${prefix}  "
                else
                    new_prefix="${prefix}│ "
                fi
            else
                new_prefix=""
            fi

            if [ $child_idx -eq $child_count ]; then
                show_tree "$child_pid" "$new_prefix" "true"
            else
                show_tree "$child_pid" "$new_prefix" "false"
            fi
        done
    fi
}

list_roots() {
    echo -e "${BOLD}Top-level processes:${NC}"
    echo ""

    curl -s "$BASE_URL/processes" | python3 -c '
import json, sys
processes = json.load(sys.stdin)
# Find processes with no parent or parent not in list
pids = {p["pid"] for p in processes}
roots = [p for p in processes if p.get("ppid", 0) not in pids][:10]

for proc in roots:
    pid = proc["pid"]
    comm = proc["comm"][:20]
    mem = proc.get("mem_pct", 0)
    print(f"  {pid:>8} {comm:<20} {mem:>6.1f}%")
'
}

if [ $# -eq 0 ]; then
    echo "Process Tree Explorer"
    echo ""
    echo "Usage:"
    echo "  $0 <pid>         Show process tree starting from PID"
    echo "  $0 --roots       List top-level processes"
    echo ""
    exit 0
fi

if [ "$1" = "--roots" ]; then
    list_roots
else
    echo -e "${BOLD}Process Tree for PID $1:${NC}"
    echo ""
    show_tree "$1" "" "true"
fi
