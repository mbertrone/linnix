#!/bin/bash
# Helper script to view Linnix incidents

case "$1" in
  "list")
    echo "=== Recent Incidents ==="
    curl -s "http://127.0.0.1:3000/incidents" | python3 -c '
import json, sys
from datetime import datetime
incidents = json.load(sys.stdin)
print("{:<5} {:<20} {:<25} {:<20} {:<10} {:<10} {:<15}".format("ID", "Time", "Type", "Target", "PSI CPU", "CPU%", "Action"))
print("-" * 115)
for inc in incidents[:10]:
    timestamp = datetime.fromtimestamp(inc["timestamp"]).strftime("%Y-%m-%d %H:%M:%S")
    iid = inc["id"]
    etype = inc["event_type"]
    target = inc["target_name"]
    psi = inc["psi_cpu"]
    cpu = inc["cpu_percent"]
    action = inc["action"]
    print("{:<5} {:<20} {:<25} {:<20} {:<10.2f} {:<10.2f} {:<15}".format(iid, timestamp, etype, target, psi, cpu, action))
'
    ;;
  "detail")
    echo "=== Latest Incident Details ==="
    curl -s "http://127.0.0.1:3000/incidents" > /tmp/incidents.json && python3 -c '
import json
from datetime import datetime
with open("/tmp/incidents.json") as f:
    incidents = json.load(f)
if incidents:
    inc = incidents[0]
    iid = inc["id"]
    etype = inc["event_type"].upper().replace("_", " ")
    ts = datetime.fromtimestamp(inc["timestamp"]).strftime("%Y-%m-%d %H:%M:%S")
    pid = inc["target_pid"]
    target = inc["target_name"]
    action = inc["action"]
    cpu = inc["cpu_percent"]
    psi_cpu = inc["psi_cpu"]
    psi_mem = inc["psi_memory"]
    load_avg = inc["load_avg"]
    snapshot = json.loads(inc["system_snapshot"])
    snap_mem = snapshot["mem_percent"]
    snap_cpu = snapshot["psi_cpu_some_avg10"]
    snap_mem_psi = snapshot["psi_memory_some_avg10"]
    snap_io = snapshot["psi_io_some_avg10"]

    print("=" * 80)
    print(f"INCIDENT #{iid} - {etype}")
    print("=" * 80)
    print(f"Time:        {ts}")
    print(f"Target:      PID {pid} ({target})")
    print(f"Action:      {action}")
    print(f"CPU Usage:   {cpu:.2f}%")
    print(f"PSI CPU:     {psi_cpu:.2f}% (Pressure Stall Information)")
    print(f"PSI Memory:  {psi_mem:.2f}%")
    print(f"Load Avg:    {load_avg}")
    print("\n" + "-" * 80)
    print("SYSTEM SNAPSHOT AT INCIDENT TIME")
    print("-" * 80)
    print(f"Memory:      {snap_mem:.2f}%")
    print(f"PSI CPU:     {snap_cpu:.2f}% (10s avg)")
    print(f"PSI Memory:  {snap_mem_psi:.2f}% (10s avg)")
    print(f"PSI I/O:     {snap_io:.2f}% (10s avg)")
    print("=" * 80)
'
    ;;
  "watch")
    echo "=== Watching for new incidents (Ctrl+C to stop) ==="
    /home/ubuntu/linnix/target/release/linnix-cli --alerts
    ;;
  "json")
    # Optional: specify incident ID (with # prefix) or limit
    # Usage: ./view_incidents.sh json [#ID|limit]
    if [ -n "$2" ]; then
      # Check if argument starts with # for explicit ID lookup
      if [[ "$2" =~ ^#[0-9]+$ ]]; then
        # Explicit incident ID with # prefix
        ID="${2#\#}"
        echo "=== Incident #$ID (JSON) ===" >&2
        curl -s "http://127.0.0.1:3000/incidents/$ID" | python3 -m json.tool
      elif [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -le 20 ]; then
        # Number 1-20: treat as limit
        echo "=== Recent Incidents (JSON, limit: $2) ===" >&2
        curl -s "http://127.0.0.1:3000/incidents" | python3 -c '
import json, sys
incidents = json.load(sys.stdin)
print(json.dumps(incidents[:'"$2"'], indent=2))
'
      elif [[ "$2" =~ ^[0-9]+$ ]]; then
        # Number > 20: treat as incident ID
        echo "=== Incident #$2 (JSON) ===" >&2
        curl -s "http://127.0.0.1:3000/incidents/$2" | python3 -m json.tool
      else
        echo "Error: Invalid argument '$2'" >&2
        echo "Use a number (1-20 for limit, >20 for ID) or #ID for explicit ID lookup" >&2
        exit 1
      fi
    else
      echo "=== All Incidents (JSON) ===" >&2
      curl -s "http://127.0.0.1:3000/incidents" | python3 -m json.tool
    fi
    ;;
  *)
    echo "Usage: $0 {list|detail|watch|json}"
    echo ""
    echo "Commands:"
    echo "  list            - Show recent incidents in table format"
    echo "  detail          - Show detailed view of latest incident"
    echo "  watch           - Stream new incidents in real-time"
    echo "  json [#id|limit] - Pretty-print incidents as JSON"
    echo ""
    echo "Examples:"
    echo "  $0 json          - Show all incidents as JSON"
    echo "  $0 json 5        - Show last 5 incidents as JSON (limit)"
    echo "  $0 json 33       - Show specific incident #33 as JSON (ID)"
    echo "  $0 json #5       - Force ID lookup for incident #5"
    ;;
esac
