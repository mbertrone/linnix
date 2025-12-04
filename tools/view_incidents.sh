#!/bin/bash
# Helper script to view Linnix incidents

case "$1" in
  "list")
    echo "=== Recent Incidents ==="
    curl -s "http://127.0.0.1:3000/incidents" | python3 -c "
import json, sys
from datetime import datetime
incidents = json.load(sys.stdin)
print('{:<5} {:<20} {:<25} {:<20} {:<10} {:<10} {:<15}'.format('ID', 'Time', 'Type', 'Target', 'PSI CPU', 'CPU%', 'Action'))
print('-' * 115)
for inc in incidents[:10]:
    timestamp = datetime.fromtimestamp(inc['timestamp']).strftime('%Y-%m-%d %H:%M:%S')
    print('{:<5} {:<20} {:<25} {:<20} {:<10.2f} {:<10.2f} {:<15}'.format(
        inc['id'], timestamp, inc['event_type'], inc['target_name'], 
        inc['psi_cpu'], inc['cpu_percent'], inc['action']))
"
    ;;
  "detail")
    echo "=== Latest Incident Details ==="
    curl -s "http://127.0.0.1:3000/incidents" > /tmp/incidents.json && python3 << 'EOF'
import json
from datetime import datetime
with open('/tmp/incidents.json') as f:
    incidents = json.load(f)
if incidents:
    inc = incidents[0]
    print("=" * 80)
    print(f"INCIDENT #{inc['id']} - {inc['event_type'].upper().replace('_', ' ')}")
    print("=" * 80)
    print(f"Time:        {datetime.fromtimestamp(inc['timestamp']).strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"Target:      PID {inc['target_pid']} ({inc['target_name']})")
    print(f"Action:      {inc['action']}")
    print(f"CPU Usage:   {inc['cpu_percent']:.2f}%")
    print(f"PSI CPU:     {inc['psi_cpu']:.2f}% (Pressure Stall Information)")
    print(f"PSI Memory:  {inc['psi_memory']:.2f}%")
    print(f"Load Avg:    {inc['load_avg']}")
    snapshot = json.loads(inc['system_snapshot'])
    print("\n" + "-" * 80)
    print("SYSTEM SNAPSHOT AT INCIDENT TIME")
    print("-" * 80)
    print(f"Memory:      {snapshot['mem_percent']:.2f}%")
    print(f"PSI CPU:     {snapshot['psi_cpu_some_avg10']:.2f}% (10s avg)")
    print(f"PSI Memory:  {snapshot['psi_memory_some_avg10']:.2f}% (10s avg)")
    print(f"PSI I/O:     {snapshot['psi_io_some_avg10']:.2f}% (10s avg)")
    print("=" * 80)
EOF
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
        curl -s "http://127.0.0.1:3000/incidents" | python3 -c "
import json, sys
incidents = json.load(sys.stdin)
print(json.dumps(incidents[:$2], indent=2))
"
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
