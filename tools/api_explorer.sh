#!/bin/bash
# Linnix API Explorer - Interactive tool to explore and test Linnix APIs

BASE_URL="${LINNIX_URL:-http://127.0.0.1:3000}"
COLORIZE="${LINNIX_COLOR:-true}"

# Colors
if [ "$COLORIZE" = "true" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    NC=''
fi

# API catalog organized by category
declare -A API_ENDPOINTS=(
    # System & Status
    ["healthz"]="GET|Health check|Simple health status"
    ["status"]="GET|Daemon status & metrics|Version, uptime, CPU/RAM usage, events/sec, top processes"
    ["system"]="GET|Current system snapshot|CPU%, memory%, PSI metrics, load avg, network stats"
    ["metrics"]="GET|Internal metrics|Daemon metrics"
    ["metrics/system"]="GET|System-level metrics|Total CPU, memory, process count"
    ["metrics/prometheus"]="GET|Prometheus format metrics|Metrics in Prometheus format (if enabled)"

    # Process Monitoring
    ["processes"]="GET|List all tracked processes|PID, PPID, comm, memory%, age, K8s metadata"
    ["processes/live"]="GET-SSE|Stream live process updates|Real-time process changes"
    ["processes/{pid}"]="GET|Get specific process info|Detailed process data (replace {pid} with number)"
    ["ppid/{ppid}"]="GET|Get processes by parent PID|Child processes (replace {ppid} with number)"
    ["graph/{pid}"]="GET|Get process tree graph|Process ancestry graph (replace {pid} with number)"
    ["events"]="GET-SSE|Stream process events|fork/exec/exit events stream"
    ["stream"]="GET-SSE|Stream process events (alias)|Same as /events"

    # Incidents & Alerts
    ["incidents"]="GET|List all incidents|Full incident history with PSI, targets, actions"
    ["incidents/summary"]="GET|Incident summary|Total count, by type, recent incidents"
    ["incidents/stats"]="GET|Incident statistics|Totals, recovery times, feedback count"
    ["incidents/{id}"]="GET|Get specific incident|Single incident details (replace {id} with number)"
    ["alerts"]="GET-SSE|Stream real-time alerts|Alert events as they happen"

    # Analysis & Attribution
    ["attribution"]="GET|PSI attribution data|Which pods/processes contributed to PSI"
    ["timeline"]="GET|Event timeline|Historical event timeline"
    ["context"]="GET|System context|Current system state context"

    # Insights
    ["insights"]="GET|List insights|AI-generated insights (if LLM enabled)"
    ["insights/recent"]="GET|Recent insights|Latest insights"
    ["insights/{id}"]="GET|Get specific insight|Single insight details (replace {id} with ID)"

    # Actions
    ["actions"]="GET|List pending actions|Actions awaiting approval (kill, throttle, etc.)"
    ["actions/{id}"]="GET|Get specific action|Single action details (replace {id} with ID)"
)

# Categories for organized display
declare -A CATEGORIES=(
    ["System & Status"]="healthz status system metrics metrics/system metrics/prometheus"
    ["Process Monitoring"]="processes processes/live processes/{pid} ppid/{ppid} graph/{pid} events stream"
    ["Incidents & Alerts"]="incidents incidents/summary incidents/stats incidents/{id} alerts"
    ["Analysis & Attribution"]="attribution timeline context"
    ["Insights"]="insights insights/recent insights/{id}"
    ["Actions"]="actions actions/{id}"
)

show_banner() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              Linnix API Explorer v1.0                        ║"
    echo "║         Interactive API Testing & Documentation              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "Base URL: ${YELLOW}${BASE_URL}${NC}"
    echo ""
}

list_categories() {
    echo -e "${BOLD}Available API Categories:${NC}"
    echo ""
    local idx=1
    for category in "System & Status" "Process Monitoring" "Incidents & Alerts" "Analysis & Attribution" "Insights" "Actions"; do
        local endpoints="${CATEGORIES[$category]}"
        local count=$(echo "$endpoints" | wc -w)
        echo -e "  ${GREEN}$idx${NC}. $category ${CYAN}($count endpoints)${NC}"
        ((idx++))
    done
    echo ""
}

list_endpoints() {
    local category="$1"
    local endpoints="${CATEGORIES[$category]}"

    echo -e "${BOLD}${BLUE}═══ $category ═══${NC}"
    echo ""

    for endpoint in $endpoints; do
        if [ -n "${API_ENDPOINTS[$endpoint]}" ]; then
            IFS='|' read -r method description details <<< "${API_ENDPOINTS[$endpoint]}"
            echo -e "  ${GREEN}$endpoint${NC}"
            echo -e "    Method: ${YELLOW}$method${NC}"
            echo -e "    ${description}"
            echo ""
        fi
    done
}

list_all_endpoints() {
    for category in "System & Status" "Process Monitoring" "Incidents & Alerts" "Analysis & Attribution" "Insights" "Actions"; do
        list_endpoints "$category"
    done
}

search_endpoints() {
    local query="$1"
    echo -e "${BOLD}Search results for: ${YELLOW}$query${NC}"
    echo ""

    local found=false
    for endpoint in "${!API_ENDPOINTS[@]}"; do
        IFS='|' read -r method description details <<< "${API_ENDPOINTS[$endpoint]}"
        if [[ "$endpoint" =~ $query ]] || [[ "$description" =~ $query ]] || [[ "$details" =~ $query ]]; then
            echo -e "  ${GREEN}$endpoint${NC}"
            echo -e "    Method: ${YELLOW}$method${NC}"
            echo -e "    ${description}"
            echo ""
            found=true
        fi
    done

    if [ "$found" = false ]; then
        echo -e "${RED}No endpoints found matching '$query'${NC}"
    fi
}

test_endpoint() {
    local endpoint="$1"
    local params="$2"

    # Check if endpoint contains placeholder
    if [[ "$endpoint" =~ \{.*\} ]]; then
        echo -e "${YELLOW}This endpoint requires parameters. Example: ${endpoint}${NC}"
        echo -e "Usage: test ${endpoint/\{*\}/123} [query_params]"
        return 1
    fi

    local url="${BASE_URL}/${endpoint}"
    if [ -n "$params" ]; then
        url="${url}?${params}"
    fi

    echo -e "${CYAN}Testing: ${url}${NC}"
    echo ""

    # Check if it's an SSE endpoint
    if [[ "${API_ENDPOINTS[$endpoint]}" =~ "SSE" ]]; then
        echo -e "${YELLOW}This is a Server-Sent Events (SSE) stream.${NC}"
        echo -e "${YELLOW}Press Ctrl+C to stop streaming.${NC}"
        echo ""
        curl -s -N "$url"
    else
        local response=$(curl -s -w "\n%{http_code}" "$url")
        local body=$(echo "$response" | head -n -1)
        local status=$(echo "$response" | tail -n 1)

        if [ "$status" = "200" ]; then
            echo -e "${GREEN}Status: $status OK${NC}"
            echo ""
            echo "$body" | python3 -m json.tool 2>/dev/null || echo "$body"
        else
            echo -e "${RED}Status: $status${NC}"
            echo "$body"
        fi
    fi
}

show_help() {
    echo -e "${BOLD}Usage:${NC}"
    echo "  $0 [command] [args...]"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo -e "  ${GREEN}list${NC}                    - List all API categories"
    echo -e "  ${GREEN}list <category>${NC}         - List endpoints in a category"
    echo -e "  ${GREEN}all${NC}                     - List all endpoints with details"
    echo -e "  ${GREEN}search <query>${NC}          - Search endpoints by keyword"
    echo -e "  ${GREEN}test <endpoint> [params]${NC} - Test an API endpoint"
    echo -e "  ${GREEN}help${NC}                    - Show this help message"
    echo -e "  ${GREEN}interactive${NC}             - Enter interactive mode"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  $0 list"
    echo "  $0 list \"System & Status\""
    echo "  $0 search incident"
    echo "  $0 test status"
    echo "  $0 test incidents \"limit=5\""
    echo "  $0 test incidents/33"
    echo "  $0 interactive"
    echo ""
    echo -e "${BOLD}Environment Variables:${NC}"
    echo "  LINNIX_URL    - Base URL (default: http://127.0.0.1:3000)"
    echo "  LINNIX_COLOR  - Enable colors (default: true)"
}

interactive_mode() {
    show_banner
    echo -e "${BOLD}Interactive Mode${NC}"
    echo "Type 'help' for commands, 'exit' to quit"
    echo ""

    while true; do
        echo -ne "${CYAN}linnix>${NC} "
        read -r input

        if [ -z "$input" ]; then
            continue
        fi

        # Parse input
        read -ra CMD <<< "$input"
        local cmd="${CMD[0]}"

        case "$cmd" in
            exit|quit|q)
                echo "Goodbye!"
                break
                ;;
            help|h)
                show_help
                ;;
            list|ls)
                if [ -n "${CMD[1]}" ]; then
                    list_endpoints "${CMD[@]:1}"
                else
                    list_categories
                fi
                ;;
            all)
                list_all_endpoints
                ;;
            search|s)
                if [ -n "${CMD[1]}" ]; then
                    search_endpoints "${CMD[@]:1}"
                else
                    echo -e "${RED}Usage: search <query>${NC}"
                fi
                ;;
            test|t)
                if [ -n "${CMD[1]}" ]; then
                    test_endpoint "${CMD[1]}" "${CMD[2]}"
                else
                    echo -e "${RED}Usage: test <endpoint> [params]${NC}"
                fi
                ;;
            clear)
                clear
                show_banner
                ;;
            *)
                echo -e "${RED}Unknown command: $cmd${NC}"
                echo "Type 'help' for available commands"
                ;;
        esac
        echo ""
    done
}

# Main script
main() {
    if [ $# -eq 0 ]; then
        show_banner
        show_help
        exit 0
    fi

    case "$1" in
        list|ls)
            show_banner
            if [ -n "$2" ]; then
                list_endpoints "$2"
            else
                list_categories
            fi
            ;;
        all)
            show_banner
            list_all_endpoints
            ;;
        search|s)
            show_banner
            if [ -n "$2" ]; then
                search_endpoints "$2"
            else
                echo -e "${RED}Usage: $0 search <query>${NC}"
                exit 1
            fi
            ;;
        test|t)
            if [ -n "$2" ]; then
                test_endpoint "$2" "$3"
            else
                echo -e "${RED}Usage: $0 test <endpoint> [params]${NC}"
                exit 1
            fi
            ;;
        interactive|i)
            interactive_mode
            ;;
        help|h|--help|-h)
            show_banner
            show_help
            ;;
        *)
            echo -e "${RED}Unknown command: $1${NC}"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
