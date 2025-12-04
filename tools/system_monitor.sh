#!/bin/bash
# System Monitor - Real-time system dashboard for Linnix
# Displays CPU, memory, PSI metrics, and top processes

BASE_URL="${LINNIX_URL:-http://127.0.0.1:3000}"
REFRESH_INTERVAL="${REFRESH_INTERVAL:-2}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

get_psi_level_color() {
    local psi=$1
    if (( $(echo "$psi >= 60" | bc -l) )); then
        echo -e "${RED}"
    elif (( $(echo "$psi >= 40" | bc -l) )); then
        echo -e "${YELLOW}"
    elif (( $(echo "$psi >= 20" | bc -l) )); then
        echo -e "${CYAN}"
    else
        echo -e "${GREEN}"
    fi
}

display_dashboard() {
    clear

    # Fetch data
    local status=$(curl -s "$BASE_URL/status")
    local system=$(curl -s "$BASE_URL/system")

    if [ -z "$status" ] || [ -z "$system" ]; then
        echo -e "${RED}Error: Cannot connect to Linnix at $BASE_URL${NC}"
        exit 1
    fi

    # Parse status
    local version=$(echo "$status" | python3 -c "import json,sys; print(json.load(sys.stdin).get('version','N/A'))")
    local uptime=$(echo "$status" | python3 -c "import json,sys; print(json.load(sys.stdin).get('uptime_s',0))")
    local daemon_cpu=$(echo "$status" | python3 -c "import json,sys; print(json.load(sys.stdin).get('cpu_pct',0))")
    local daemon_rss=$(echo "$status" | python3 -c "import json,sys; print(json.load(sys.stdin).get('rss_mb',0))")
    local events_per_sec=$(echo "$status" | python3 -c "import json,sys; print(json.load(sys.stdin).get('events_per_sec',0))")
    local incidents_1h=$(echo "$status" | python3 -c "import json,sys; print(json.load(sys.stdin).get('incidents_last_1h',0))")

    # Parse system metrics
    local cpu_percent=$(echo "$system" | python3 -c "import json,sys; print(json.load(sys.stdin).get('cpu_percent',0))")
    local mem_percent=$(echo "$system" | python3 -c "import json,sys; print(json.load(sys.stdin).get('mem_percent',0))")
    local psi_cpu=$(echo "$system" | python3 -c "import json,sys; print(json.load(sys.stdin).get('psi_cpu_some_avg10',0))")
    local psi_mem=$(echo "$system" | python3 -c "import json,sys; print(json.load(sys.stdin).get('psi_memory_some_avg10',0))")
    local psi_io=$(echo "$system" | python3 -c "import json,sys; print(json.load(sys.stdin).get('psi_io_some_avg10',0))")
    local load_avg=$(echo "$system" | python3 -c "import json,sys; print(','.join(map(str,json.load(sys.stdin).get('load_avg',[0,0,0]))))")

    # Get top processes
    local top_cpu=$(echo "$status" | python3 -c "
import json,sys
data = json.load(sys.stdin)
for proc in data.get('top_cpu', [])[:5]:
    print(f\"{proc['pid']:>8} {proc['comm'][:15]:<15} {proc['cpu_percent']:>6.1f}%\")
")

    local top_rss=$(echo "$status" | python3 -c "
import json,sys
data = json.load(sys.stdin)
for proc in data.get('top_rss', [])[:5]:
    print(f\"{proc['pid']:>8} {proc['comm'][:15]:<15} {proc['mem_percent']:>6.1f}%\")
")

    # Calculate uptime
    local uptime_hours=$((uptime / 3600))
    local uptime_mins=$(((uptime % 3600) / 60))

    # Header
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║                   Linnix System Monitor v$version                        ${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Daemon Status
    echo -e "${BOLD}Daemon Status${NC}"
    echo -e "  Uptime:    ${uptime_hours}h ${uptime_mins}m"
    echo -e "  CPU/RSS:   ${daemon_cpu}% / ${daemon_rss} MB"
    echo -e "  Events:    ${events_per_sec}/sec"
    echo -e "  Incidents: ${incidents_1h} in last hour"
    echo ""

    # System Metrics
    echo -e "${BOLD}System Metrics${NC}"
    printf "  CPU:       %6.2f%%  " "$cpu_percent"
    if (( $(echo "$cpu_percent >= 90" | bc -l) )); then
        echo -e "${RED}[HIGH]${NC}"
    elif (( $(echo "$cpu_percent >= 70" | bc -l) )); then
        echo -e "${YELLOW}[MEDIUM]${NC}"
    else
        echo -e "${GREEN}[OK]${NC}"
    fi

    printf "  Memory:    %6.2f%%  " "$mem_percent"
    if (( $(echo "$mem_percent >= 90" | bc -l) )); then
        echo -e "${RED}[HIGH]${NC}"
    elif (( $(echo "$mem_percent >= 70" | bc -l) )); then
        echo -e "${YELLOW}[MEDIUM]${NC}"
    else
        echo -e "${GREEN}[OK]${NC}"
    fi

    echo -e "  Load Avg:  $load_avg"
    echo ""

    # PSI Metrics (Pressure Stall Information)
    echo -e "${BOLD}PSI Metrics (10s avg)${NC}"

    local psi_cpu_color=$(get_psi_level_color "$psi_cpu")
    printf "  CPU:       %6.2f%%  " "$psi_cpu"
    echo -e "${psi_cpu_color}$(get_psi_label "$psi_cpu")${NC}"

    local psi_mem_color=$(get_psi_level_color "$psi_mem")
    printf "  Memory:    %6.2f%%  " "$psi_mem"
    echo -e "${psi_mem_color}$(get_psi_label "$psi_mem")${NC}"

    local psi_io_color=$(get_psi_level_color "$psi_io")
    printf "  I/O:       %6.2f%%  " "$psi_io"
    echo -e "${psi_io_color}$(get_psi_label "$psi_io")${NC}"
    echo ""

    # Top CPU Processes
    echo -e "${BOLD}Top CPU Processes${NC}"
    echo -e "      ${CYAN}PID     Command              CPU%${NC}"
    echo "$top_cpu"
    echo ""

    # Top Memory Processes
    echo -e "${BOLD}Top Memory Processes${NC}"
    echo -e "      ${CYAN}PID     Command              MEM%${NC}"
    echo "$top_rss"
    echo ""

    # Footer
    echo -e "${CYAN}Press Ctrl+C to exit | Refresh: ${REFRESH_INTERVAL}s${NC}"
}

get_psi_label() {
    local psi=$1
    if (( $(echo "$psi >= 60" | bc -l) )); then
        echo "[CRITICAL]"
    elif (( $(echo "$psi >= 40" | bc -l) )); then
        echo "[HIGH]"
    elif (( $(echo "$psi >= 20" | bc -l) )); then
        echo "[MEDIUM]"
    else
        echo "[OK]"
    fi
}

# Main loop
if [ "$1" = "--once" ]; then
    display_dashboard
else
    while true; do
        display_dashboard
        sleep "$REFRESH_INTERVAL"
    done
fi
