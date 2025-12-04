#!/bin/bash
# Attribution Report - PSI attribution analysis for K8s

BASE_URL="${LINNIX_URL:-http://127.0.0.1:3000}"

CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}${BOLD}═══ PSI Attribution Report ═══${NC}"
echo ""

# Note: The attribution endpoint requires a pod parameter
# This tool would need to query specific pods to show attribution
echo "No attribution data available"
echo ""
echo "Attribution tracks which pods/processes contribute to system PSI."
echo ""
echo "Note: The /attribution endpoint requires a pod name parameter."
echo "Example API usage:"
echo "  curl http://127.0.0.1:3000/attribution?pod=<pod-name>"
echo ""
echo "For a list of processes contributing to PSI, see top_offenders.sh instead."
