#!/bin/bash
# Process Watcher - Stream live process events

BASE_URL="${LINNIX_URL:-http://127.0.0.1:3000}"
FILTER="${1:-}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}${BOLD}Process Event Stream${NC}"
if [ -n "$FILTER" ]; then
    echo -e "Filter: ${YELLOW}$FILTER${NC}"
fi
echo -e "${CYAN}Press Ctrl+C to stop${NC}"
echo ""

curl -s -N "$BASE_URL/stream" | while read -r line; do
    if [[ "$line" =~ ^data: ]]; then
        json="${line#data: }"

        if [ -n "$FILTER" ] && ! echo "$json" | grep -qi "$FILTER"; then
            continue
        fi

        event_type=$(echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('event_type',''))" 2>/dev/null)
        pid=$(echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('pid',''))" 2>/dev/null)
        comm=$(echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('comm',''))" 2>/dev/null)

        case "$event_type" in
            fork)
                echo -e "${GREEN}[FORK]${NC} PID $pid: $comm"
                ;;
            exec)
                echo -e "${CYAN}[EXEC]${NC} PID $pid: $comm"
                ;;
            exit)
                echo -e "${YELLOW}[EXIT]${NC} PID $pid: $comm"
                ;;
            *)
                echo -e "[${event_type}] PID $pid: $comm"
                ;;
        esac
    fi
done
