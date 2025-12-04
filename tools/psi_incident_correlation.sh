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
echo "$system" | python3 -c '
import json, sys
data = json.load(sys.stdin)
cpu = data["cpu_percent"]
psi_cpu = data["psi_cpu_some_avg10"]
psi_mem = data["psi_memory_some_avg10"]
psi_io = data["psi_io_some_avg10"]
print(f"  CPU Usage: {cpu:.1f}%")
print(f"  PSI CPU:   {psi_cpu:.1f}%")
print(f"  PSI Mem:   {psi_mem:.1f}%")
print(f"  PSI I/O:   {psi_io:.1f}%")
'

echo ""
echo -e "${BOLD}Incident PSI Analysis:${NC}"
echo ""

echo "$incidents" | python3 -c '
import json, sys
from statistics import mean, stdev

incidents = json.load(sys.stdin)
if not incidents:
    print("No incidents to analyze")
    sys.exit(0)

# Categorize by PSI level
low_psi = [inc for inc in incidents if inc["psi_cpu"] < 40]
medium_psi = [inc for inc in incidents if 40 <= inc["psi_cpu"] < 60]
high_psi = [inc for inc in incidents if inc["psi_cpu"] >= 60]

low_count = len(low_psi)
med_count = len(medium_psi)
high_count = len(high_psi)

print(f"PSI Distribution at Incident Time:")
print(f"  Low PSI (<40%):     {low_count:3d} incidents")
print(f"  Medium PSI (40-60%): {med_count:3d} incidents")
print(f"  High PSI (>60%):     {high_count:3d} incidents")
print("")

# PSI stats
psi_values = [inc["psi_cpu"] for inc in incidents]
if len(psi_values) > 1:
    psi_mean = mean(psi_values)
    psi_stdev = stdev(psi_values)
    psi_min = min(psi_values)
    psi_max = max(psi_values)
    print(f"PSI CPU Statistics:")
    print(f"  Mean:   {psi_mean:.1f}%")
    print(f"  StdDev: {psi_stdev:.1f}%")
    print(f"  Min:    {psi_min:.1f}%")
    print(f"  Max:    {psi_max:.1f}%")
    print("")

# Correlation: CPU vs PSI
print(f"CPU vs PSI Correlation:")
for inc in incidents[:5]:
    cpu = inc["cpu_percent"]
    psi = inc["psi_cpu"]
    target = inc["target_name"]
    print(f"  CPU: {cpu:5.1f}% | PSI: {psi:5.1f}% | Target: {target}")
'
