#!/bin/bash
# Action Manager - Manage pending actions interactively

BASE_URL="${LINNIX_URL:-http://127.0.0.1:3000}"

CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

show_actions() {
    echo -e "${CYAN}${BOLD}═══ Pending Actions ═══${NC}"
    echo ""

    actions=$(curl -s "$BASE_URL/actions")

    if [ "$actions" = "[]" ] || [ -z "$actions" ]; then
        echo "No pending actions"
        return 1
    fi

    echo "$actions" | python3 << 'EOF'
import json, sys
from datetime import datetime

for action in json.load(sys.stdin):
    print(f"\n[{action['id']}] {action['status'].upper()}")
    print(f"  Type:    {action['action']['type']}")
    if 'pid' in action['action']:
        print(f"  Target:  PID {action['action']['pid']}")
    print(f"  Reason:  {action['reason']}")
    print(f"  Source:  {action['source']}")
    created = datetime.fromtimestamp(action['created_at']).strftime('%Y-%m-%d %H:%M:%S')
    expires = datetime.fromtimestamp(action['expires_at']).strftime('%Y-%m-%d %H:%M:%S')
    print(f"  Created: {created}")
    print(f"  Expires: {expires}")
EOF
    return 0
}

approve_action() {
    local action_id="$1"
    echo -e "${YELLOW}Approving action $action_id...${NC}"

    response=$(curl -s -X POST "$BASE_URL/actions/$action_id/approve")
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Action approved${NC}"
    else
        echo -e "${RED}✗ Failed to approve action${NC}"
    fi
}

reject_action() {
    local action_id="$1"
    echo -e "${YELLOW}Rejecting action $action_id...${NC}"

    response=$(curl -s -X POST "$BASE_URL/actions/$action_id/reject")
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Action rejected${NC}"
    else
        echo -e "${RED}✗ Failed to reject action${NC}"
    fi
}

case "$1" in
    list|"")
        show_actions
        ;;
    approve)
        if [ -z "$2" ]; then
            echo "Usage: $0 approve <action-id>"
            exit 1
        fi
        approve_action "$2"
        ;;
    reject)
        if [ -z "$2" ]; then
            echo "Usage: $0 reject <action-id>"
            exit 1
        fi
        reject_action "$2"
        ;;
    interactive)
        while true; do
            show_actions
            if [ $? -ne 0 ]; then
                echo "No actions to manage"
                sleep 5
                continue
            fi
            echo ""
            echo -e "${BOLD}Commands: approve <id>, reject <id>, refresh, exit${NC}"
            echo -ne "> "
            read -r cmd arg
            case "$cmd" in
                approve) approve_action "$arg" ;;
                reject) reject_action "$arg" ;;
                refresh|r) clear ;;
                exit|quit|q) break ;;
                *) echo "Unknown command" ;;
            esac
            echo ""
            sleep 1
        done
        ;;
    *)
        echo "Usage: $0 {list|approve|reject|interactive} [action-id]"
        exit 1
        ;;
esac
