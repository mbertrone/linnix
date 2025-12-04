#!/bin/bash
# Health Check - Comprehensive system health checker

BASE_URL="${LINNIX_URL:-http://127.0.0.1:3000}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

check_connectivity() {
    if curl -s -f "$BASE_URL/healthz" > /dev/null; then
        echo -e "  ${GREEN}✓${NC} API Connectivity"
        return 0
    else
        echo -e "  ${RED}✗${NC} API Connectivity"
        return 1
    fi
}

check_daemon() {
    status=$(curl -s "$BASE_URL/status")
    if [ -z "$status" ]; then
        echo -e "  ${RED}✗${NC} Daemon Status"
        return 1
    fi

    offline=$(echo "$status" | python3 -c "import json,sys; print(json.load(sys.stdin).get('offline',True))")
    if [ "$offline" = "False" ]; then
        echo -e "  ${GREEN}✓${NC} Daemon Status (online)"
    else
        echo -e "  ${YELLOW}⚠${NC} Daemon Status (offline mode)"
    fi

    events=$(echo "$status" | python3 -c "import json,sys; print(json.load(sys.stdin).get('events_per_sec',0))")
    echo -e "    Events: ${events}/sec"
}

check_probes() {
    status=$(curl -s "$BASE_URL/status")

    btf=$(echo "$status" | python3 -c "import json,sys; print(json.load(sys.stdin)['probes']['btf'])")
    if [ "$btf" = "True" ]; then
        echo -e "  ${GREEN}✓${NC} Kernel BTF"
    else
        echo -e "  ${YELLOW}⚠${NC} Kernel BTF"
    fi

    rss_probe=$(echo "$status" | python3 -c "import json,sys; print(json.load(sys.stdin)['probes']['rss_probe'])")
    echo -e "  ${GREEN}✓${NC} RSS Probe: $rss_probe"
}

check_resources() {
    system=$(curl -s "$BASE_URL/system")

    cpu=$(echo "$system" | python3 -c "import json,sys; print(json.load(sys.stdin).get('cpu_percent',0))")
    mem=$(echo "$system" | python3 -c "import json,sys; print(json.load(sys.stdin).get('mem_percent',0))")
    psi_cpu=$(echo "$system" | python3 -c "import json,sys; print(json.load(sys.stdin).get('psi_cpu_some_avg10',0))")

    if (( $(echo "$cpu < 90" | bc -l) )); then
        echo -e "  ${GREEN}✓${NC} CPU Usage: ${cpu}%"
    else
        echo -e "  ${YELLOW}⚠${NC} CPU Usage: ${cpu}%"
    fi

    if (( $(echo "$mem < 90" | bc -l) )); then
        echo -e "  ${GREEN}✓${NC} Memory Usage: ${mem}%"
    else
        echo -e "  ${YELLOW}⚠${NC} Memory Usage: ${mem}%"
    fi

    if (( $(echo "$psi_cpu < 40" | bc -l) )); then
        echo -e "  ${GREEN}✓${NC} PSI CPU: ${psi_cpu}%"
    elif (( $(echo "$psi_cpu < 60" | bc -l) )); then
        echo -e "  ${YELLOW}⚠${NC} PSI CPU: ${psi_cpu}%"
    else
        echo -e "  ${RED}✗${NC} PSI CPU: ${psi_cpu}%"
    fi
}

check_incidents() {
    summary=$(curl -s "$BASE_URL/incidents/summary")
    pending=$(echo "$summary" | python3 -c "import json,sys; print(json.load(sys.stdin).get('pending_analysis',0))")

    if [ "$pending" -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} No pending incidents"
    else
        echo -e "  ${YELLOW}⚠${NC} $pending pending incidents"
    fi
}

echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║           Linnix Health Check                            ║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}Connectivity:${NC}"
check_connectivity
echo ""

echo -e "${BOLD}Daemon:${NC}"
check_daemon
echo ""

echo -e "${BOLD}Probes:${NC}"
check_probes
echo ""

echo -e "${BOLD}Resources:${NC}"
check_resources
echo ""

echo -e "${BOLD}Incidents:${NC}"
check_incidents
echo ""

echo -e "${CYAN}Health check complete${NC}"
