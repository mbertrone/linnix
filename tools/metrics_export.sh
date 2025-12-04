#!/bin/bash
# Metrics Export - Export Linnix metrics in various formats

BASE_URL="${LINNIX_URL:-http://127.0.0.1:3000}"
FORMAT="${1:-prometheus}"

case "$FORMAT" in
    prometheus|prom)
        curl -s "$BASE_URL/metrics/prometheus"
        ;;
    json)
        echo "{"
        echo "  \"system\": $(curl -s "$BASE_URL/system"),"
        echo "  \"status\": $(curl -s "$BASE_URL/status"),"
        echo "  \"metrics\": $(curl -s "$BASE_URL/metrics/system")"
        echo "}"
        ;;
    influx|influxdb)
        # InfluxDB line protocol format
        system=$(curl -s "$BASE_URL/system")
        echo "$system" | python3 -c '
import json, sys, time
data = json.load(sys.stdin)
ts = int(time.time() * 1000000000)  # nanoseconds
cpu = data["cpu_percent"]
mem = data["mem_percent"]
psi_cpu = data["psi_cpu_some_avg10"]
psi_mem = data["psi_memory_some_avg10"]
psi_io = data["psi_io_some_avg10"]
print(f"system,host=linnix cpu_percent={cpu} {ts}")
print(f"system,host=linnix mem_percent={mem} {ts}")
print(f"system,host=linnix psi_cpu={psi_cpu} {ts}")
print(f"system,host=linnix psi_memory={psi_mem} {ts}")
print(f"system,host=linnix psi_io={psi_io} {ts}")
'
        ;;
    csv)
        echo "timestamp,metric,value"
        system=$(curl -s "$BASE_URL/system")
        echo "$system" | python3 -c '
import json, sys
data = json.load(sys.stdin)
ts = data["timestamp"]
cpu = data["cpu_percent"]
mem = data["mem_percent"]
psi_cpu = data["psi_cpu_some_avg10"]
psi_mem = data["psi_memory_some_avg10"]
psi_io = data["psi_io_some_avg10"]
print(f"{ts},cpu_percent,{cpu}")
print(f"{ts},mem_percent,{mem}")
print(f"{ts},psi_cpu,{psi_cpu}")
print(f"{ts},psi_memory,{psi_mem}")
print(f"{ts},psi_io,{psi_io}")
'
        ;;
    *)
        echo "Usage: $0 {prometheus|json|influx|csv}"
        echo ""
        echo "Export Linnix metrics in different formats:"
        echo "  prometheus  - Prometheus exposition format"
        echo "  json        - JSON format"
        echo "  influx      - InfluxDB line protocol"
        echo "  csv         - CSV format"
        exit 1
        ;;
esac
