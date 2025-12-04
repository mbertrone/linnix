#!/bin/bash
# PSI Tracker - Track and analyze Pressure Stall Information over time

BASE_URL="${LINNIX_URL:-http://127.0.0.1:3000}"
SAMPLES="${PSI_SAMPLES:-30}"
INTERVAL="${PSI_INTERVAL:-2}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Storage for historical data
declare -a PSI_CPU_HISTORY
declare -a PSI_MEM_HISTORY
declare -a PSI_IO_HISTORY
declare -a TIMESTAMPS

show_help() {
    echo "PSI Tracker - Monitor Pressure Stall Information trends"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --samples N    Number of samples to collect (default: 30)"
    echo "  --interval N   Sampling interval in seconds (default: 2)"
    echo "  --continuous   Run continuously (default)"
    echo "  --once         Collect one sample and exit"
    echo "  --graph        Show ASCII graph of trends"
    echo "  --help         Show this help"
    echo ""
    echo "Environment:"
    echo "  LINNIX_URL      Base URL (default: http://127.0.0.1:3000)"
    echo "  PSI_SAMPLES     Number of samples (default: 30)"
    echo "  PSI_INTERVAL    Sampling interval (default: 2)"
}

collect_sample() {
    local system=$(curl -s "$BASE_URL/system")

    if [ -z "$system" ]; then
        echo -e "${RED}Error: Cannot connect to Linnix${NC}" >&2
        return 1
    fi

    local psi_cpu=$(echo "$system" | python3 -c "import json,sys; print(json.load(sys.stdin).get('psi_cpu_some_avg10',0))")
    local psi_mem=$(echo "$system" | python3 -c "import json,sys; print(json.load(sys.stdin).get('psi_memory_some_avg10',0))")
    local psi_io=$(echo "$system" | python3 -c "import json,sys; print(json.load(sys.stdin).get('psi_io_some_avg10',0))")
    local timestamp=$(date +%s)

    PSI_CPU_HISTORY+=("$psi_cpu")
    PSI_MEM_HISTORY+=("$psi_mem")
    PSI_IO_HISTORY+=("$psi_io")
    TIMESTAMPS+=("$timestamp")

    # Keep only last N samples
    if [ ${#PSI_CPU_HISTORY[@]} -gt $SAMPLES ]; then
        PSI_CPU_HISTORY=("${PSI_CPU_HISTORY[@]:1}")
        PSI_MEM_HISTORY=("${PSI_MEM_HISTORY[@]:1}")
        PSI_IO_HISTORY=("${PSI_IO_HISTORY[@]:1}")
        TIMESTAMPS=("${TIMESTAMPS[@]:1}")
    fi
}

draw_sparkline() {
    local -n array=$1
    local width=40
    local height=8

    if [ ${#array[@]} -eq 0 ]; then
        echo "No data"
        return
    fi

    # Find min/max
    local max=0
    for val in "${array[@]}"; do
        if (( $(echo "$val > $max" | bc -l) )); then
            max=$val
        fi
    done

    # If max is 0, set to 1 to avoid division by zero
    if (( $(echo "$max == 0" | bc -l) )); then
        max=1
    fi

    # Draw bars
    local blocks=("" "▁" "▂" "▃" "▄" "▅" "▆" "▇" "█")
    local output=""

    for val in "${array[@]:(-$width)}"; do
        local normalized=$(echo "scale=2; $val / $max * 8" | bc)
        local idx=$(printf "%.0f" "$normalized")
        if [ $idx -ge 8 ]; then idx=8; fi
        output+="${blocks[$idx]}"
    done

    echo "$output"
}

calculate_stats() {
    local -n array=$1

    if [ ${#array[@]} -eq 0 ]; then
        echo "0.00 / 0.00 / 0.00"
        return
    fi

    local sum=0
    local min=${array[0]}
    local max=${array[0]}

    for val in "${array[@]}"; do
        sum=$(echo "$sum + $val" | bc)
        if (( $(echo "$val < $min" | bc -l) )); then min=$val; fi
        if (( $(echo "$val > $max" | bc -l) )); then max=$val; fi
    done

    local avg=$(echo "scale=2; $sum / ${#array[@]}" | bc)
    printf "%.2f / %.2f / %.2f" "$min" "$avg" "$max"
}

display_report() {
    clear
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║              PSI Tracker - Pressure Analysis                 ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}Samples:${NC} ${#PSI_CPU_HISTORY[@]}/$SAMPLES | ${BOLD}Interval:${NC} ${INTERVAL}s"
    echo ""

    # Current values
    if [ ${#PSI_CPU_HISTORY[@]} -gt 0 ]; then
        local latest_cpu=${PSI_CPU_HISTORY[-1]}
        local latest_mem=${PSI_MEM_HISTORY[-1]}
        local latest_io=${PSI_IO_HISTORY[-1]}

        echo -e "${BOLD}Current PSI (10s avg):${NC}"
        printf "  CPU:    %6.2f%%  " "$latest_cpu"
        get_psi_status "$latest_cpu"

        printf "  Memory: %6.2f%%  " "$latest_mem"
        get_psi_status "$latest_mem"

        printf "  I/O:    %6.2f%%  " "$latest_io"
        get_psi_status "$latest_io"
        echo ""
    fi

    # Statistics
    echo -e "${BOLD}Statistics (min / avg / max):${NC}"
    echo "  CPU:    $(calculate_stats PSI_CPU_HISTORY)"
    echo "  Memory: $(calculate_stats PSI_MEM_HISTORY)"
    echo "  I/O:    $(calculate_stats PSI_IO_HISTORY)"
    echo ""

    # Sparklines
    echo -e "${BOLD}Trends (last $width samples):${NC}"
    echo -ne "  CPU:    "
    draw_sparkline PSI_CPU_HISTORY
    echo -ne "  Memory: "
    draw_sparkline PSI_MEM_HISTORY
    echo -ne "  I/O:    "
    draw_sparkline PSI_IO_HISTORY
    echo ""

    # Time range
    if [ ${#TIMESTAMPS[@]} -gt 1 ]; then
        local duration=$((${TIMESTAMPS[-1]} - ${TIMESTAMPS[0]}))
        echo -e "${CYAN}Duration: ${duration}s | Press Ctrl+C to exit${NC}"
    fi
}

get_psi_status() {
    local psi=$1
    if (( $(echo "$psi >= 60" | bc -l) )); then
        echo -e "${RED}[CRITICAL]${NC}"
    elif (( $(echo "$psi >= 40" | bc -l) )); then
        echo -e "${YELLOW}[HIGH]${NC}"
    elif (( $(echo "$psi >= 20" | bc -l) )); then
        echo -e "${CYAN}[MEDIUM]${NC}"
    else
        echo -e "${GREEN}[OK]${NC}"
    fi
}

# Parse arguments
MODE="continuous"
while [ $# -gt 0 ]; do
    case "$1" in
        --samples)
            SAMPLES="$2"
            shift 2
            ;;
        --interval)
            INTERVAL="$2"
            shift 2
            ;;
        --once)
            MODE="once"
            shift
            ;;
        --continuous)
            MODE="continuous"
            shift
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

# Main loop
if [ "$MODE" = "once" ]; then
    collect_sample
    display_report
else
    while true; do
        collect_sample
        display_report
        sleep "$INTERVAL"
    done
fi
