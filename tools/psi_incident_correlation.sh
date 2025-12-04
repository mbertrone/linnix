#!/bin/bash
# PSI Incident Correlation - Correlate PSI levels with incident patterns

BASE_URL="${LINNIX_URL:-http://127.0.0.1:3000}"

CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}${BOLD}═══ PSI-Incident Correlation Analysis ═══${NC}"
echo ""

incidents=$(curl -s "$BASE_URL/incidents")
system=$(curl -s "$BASE_URL/system")

echo -e "${BOLD}Current System State:${NC}"
echo "$system" | python3 << 'EOF'
import json, sys
data = json.load(sys.stdin)
print(f"  CPU Usage: {data['cpu_percent']:.1f}%")
print(f"  PSI CPU:   {data['psi_cpu_some_avg10']:.1f}%")
print(f"  PSI Mem:   {data['psi_memory_some_avg10']:.1f}%")
print(f"  PSI I/O:   {data['psi_io_some_avg10']:.1f}%")
EOF

echo ""
echo -e "${BOLD}Incident PSI Analysis:${NC}"
echo ""

echo "$incidents" | python3 << 'EOF'
import json, sys
from statistics import mean, stdev

incidents = json.load(sys.stdin)
if not incidents:
    print("No incidents to analyze")
    sys.exit(0)

# Categorize by PSI level
low_psi = [inc for inc in incidents if inc['psi_cpu'] < 40]
medium_psi = [inc for inc in incidents if 40 <= inc['psi_cpu'] < 60]
high_psi = [inc for inc in incidents if inc['psi_cpu'] >= 60]

print(f"PSI Distribution at Incident Time:")
print(f"  Low PSI (<40%):     {len(low_psi):3d} incidents")
print(f"  Medium PSI (40-60%): {len(medium_psi):3d} incidents")
print(f"  High PSI (>60%):     {len(high_psi):3d} incidents")
print("")

# PSI stats
psi_values = [inc['psi_cpu'] for inc in incidents]
if len(psi_values) > 1:
    print(f"PSI CPU Statistics:")
    print(f"  Mean:   {mean(psi_values):.1f}%")
    print(f"  StdDev: {stdev(psi_values):.1f}%")
    print(f"  Min:    {min(psi_values):.1f}%")
    print(f"  Max:    {max(psi_values):.1f}%")
    print("")

# Correlation: CPU vs PSI
print(f"CPU vs PSI Correlation:")
for inc in incidents[:5]:
    print(f"  CPU: {inc['cpu_percent']:5.1f}% | PSI: {inc['psi_cpu']:5.1f}% | Target: {inc['target_name']}")
EOF
