#!/bin/bash
# Alert Watcher - Live alert monitoring with filtering

BASE_URL="${LINNIX_URL:-http://127.0.0.1:3000}"
FILTER="${ALERT_FILTER:-}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

get_severity_color() {
    case "$1" in
        critical|high)
            echo -e "${RED}${BOLD}"
            ;;
        medium|warning)
            echo -e "${YELLOW}"
            ;;
        *)
            echo -e "${CYAN}"
            ;;
    esac
}

show_help() {
    echo "Alert Watcher - Monitor real-time alerts"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --filter <text>    Filter alerts containing text"
    echo "  --help             Show this help"
    echo ""
    echo "Environment:"
    echo "  LINNIX_URL         Base URL (default: http://127.0.0.1:3000)"
    echo "  ALERT_FILTER       Default filter text"
}

if [ "$1" = "--help" ]; then
    show_help
    exit 0
fi

if [ "$1" = "--filter" ]; then
    FILTER="$2"
fi

echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║              Alert Watcher - Live Monitor                ║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

if [ -n "$FILTER" ]; then
    echo -e "Filter: ${YELLOW}$FILTER${NC}"
fi

echo -e "${CYAN}Watching for alerts... (Ctrl+C to stop)${NC}"
echo ""

# Track seen alerts to avoid duplicates
declare -A seen_alerts

curl -s -N "$BASE_URL/alerts" | while read -r line; do
    if [[ "$line" =~ ^data: ]]; then
        json="${line#data: }"

        # Apply filter
        if [ -n "$FILTER" ] && ! echo "$json" | grep -qi "$FILTER"; then
            continue
        fi

        # Parse alert
        parsed=$(echo "$json" | python3 << 'EOF' 2>/dev/null
import json, sys
from datetime import datetime
try:
    alert = json.load(sys.stdin)
    timestamp = datetime.now().strftime('%H:%M:%S')
    rule = alert.get('rule', 'unknown')
    severity = alert.get('severity', 'info')
    message = alert.get('message', '')
    target = alert.get('target', {})
    target_info = f"PID {target.get('pid', 'N/A')} ({target.get('name', 'N/A')})" if target else ''

    print(f"{timestamp}|{severity}|{rule}|{message}|{target_info}")
except:
    pass
EOF
)

        if [ -n "$parsed" ]; then
            IFS='|' read -r timestamp severity rule message target_info <<< "$parsed"

            # Generate alert hash
            alert_hash=$(echo "$rule$message$target_info" | md5sum | cut -d' ' -f1)

            # Skip if seen recently
            if [ -n "${seen_alerts[$alert_hash]}" ]; then
                continue
            fi
            seen_alerts[$alert_hash]=1

            # Display alert
            color=$(get_severity_color "$severity")
            echo -e "${color}[${timestamp}] ${severity^^}${NC}"
            echo -e "  Rule:   $rule"
            echo -e "  ${message}"
            if [ -n "$target_info" ]; then
                echo -e "  Target: $target_info"
            fi
            echo ""
        fi
    fi
done
