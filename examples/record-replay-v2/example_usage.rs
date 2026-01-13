// Example usage of Record/Replay V2 simple implementation
// This demonstrates the basic workflow without requiring Linux compilation

use std::path::PathBuf;

// Mock data structures for demonstration (would use real ones in actual implementation)
#[derive(serde::Serialize, serde::Deserialize, Clone, Debug)]
pub struct MockSystemSnapshot {
    pub timestamp: u64,
    pub cpu_percent: f32,
    pub mem_percent: f32,
    pub psi_cpu_some_avg10: f32,
    pub active_processes: Vec<MockProcessEntry>,
}

#[derive(serde::Serialize, serde::Deserialize, Clone, Debug)]
pub struct MockProcessEntry {
    pub pid: u32,
    pub comm: String,
    pub cpu_percent: f32,
    pub mem_percent: f32,
    pub rss_mb: u64,
}

#[derive(serde::Serialize, serde::Deserialize, Clone, Debug)]
pub struct MockRecordingEntry {
    #[serde(rename = "type")]
    pub entry_type: String,
    pub timestamp: u64,
    pub data: serde_json::Value,
}

/// Example V2 recording workflow
pub async fn example_recording_workflow() -> anyhow::Result<()> {
    println!("=== Record/Replay V2 Example Workflow ===\n");

    // 1. Generate sample recording data
    let mut recording_entries = Vec::new();
    let base_time = 1705939200000000000u64; // Example timestamp

    // Generate some process events
    for i in 0..5 {
        let process_event = serde_json::json!({
            "pid": 1000 + i,
            "event_type": 0, // exec
            "comm": format!("process{}", i),
            "cpu_percent": 10.0 + i as f32,
        });

        let entry = MockRecordingEntry {
            entry_type: "process_event".to_string(),
            timestamp: base_time + i * 1000000000, // 1 second apart
            data: process_event,
        };
        recording_entries.push(entry);
    }

    // Generate system snapshots every 5 seconds
    for i in 0..3 {
        let active_processes = vec![
            MockProcessEntry {
                pid: 1001,
                comm: "python3".to_string(),
                cpu_percent: 15.2 + i as f32,
                mem_percent: 8.9 + i as f32,
                rss_mb: 145 + i * 10,
            },
            MockProcessEntry {
                pid: 1002,
                comm: "node".to_string(),
                cpu_percent: 8.1 - i as f32,
                mem_percent: 12.3 + i as f32 * 0.5,
                rss_mb: 89 + i * 5,
            },
        ];

        let snapshot = MockSystemSnapshot {
            timestamp: base_time + i * 5000000000, // 5 seconds apart
            cpu_percent: 45.2 + i as f32 * 5.0,
            mem_percent: 67.8 + i as f32 * 2.0,
            psi_cpu_some_avg10: 23.4 + i as f32,
            active_processes,
        };

        let entry = MockRecordingEntry {
            entry_type: "system_snapshot".to_string(),
            timestamp: base_time + i * 5000000000,
            data: serde_json::to_value(&snapshot)?,
        };
        recording_entries.push(entry);
    }

    // 2. Write recording to file (V2 JSONL format)
    let recording_path = "example_recording_v2.jsonl";
    let mut file_content = String::new();
    
    recording_entries.sort_by_key(|e| e.timestamp);
    for entry in &recording_entries {
        file_content.push_str(&serde_json::to_string(entry)?);
        file_content.push('\n');
    }
    
    std::fs::write(recording_path, file_content)?;
    println!("✅ Recording written to: {}", recording_path);
    println!("📊 Total entries: {}", recording_entries.len());
    
    // Count entries by type
    let mut type_counts = std::collections::HashMap::new();
    for entry in &recording_entries {
        *type_counts.entry(entry.entry_type.clone()).or_insert(0) += 1;
    }
    for (entry_type, count) in type_counts {
        println!("   - {}: {} entries", entry_type, count);
    }

    // 3. Demonstrate replay functionality
    println!("\n=== Replay Analysis ===");
    
    // Load recording for replay
    let entries = load_recording_entries(recording_path)?;
    println!("✅ Loaded {} entries from recording", entries.len());

    // Find time range
    if let (Some(first), Some(last)) = (entries.first(), entries.last()) {
        println!("📅 Time range: {} to {} ({}s duration)", 
            first.timestamp, last.timestamp, 
            (last.timestamp - first.timestamp) / 1_000_000_000);
    }

    // Get system snapshots
    let snapshots: Vec<_> = entries.iter()
        .filter(|e| e.entry_type == "system_snapshot")
        .collect();
    println!("📈 Found {} system snapshots", snapshots.len());

    // Analyze CPU trends
    println!("\n🖥️  CPU Usage Trend:");
    for snapshot_entry in &snapshots {
        if let Ok(snapshot) = serde_json::from_value::<MockSystemSnapshot>(snapshot_entry.data.clone()) {
            println!("   Time {}: CPU={:.1}%, Memory={:.1}%, PSI={:.1}%, {} processes",
                snapshot.timestamp, snapshot.cpu_percent, snapshot.mem_percent, 
                snapshot.psi_cpu_some_avg10, snapshot.active_processes.len());
        }
    }

    // Analyze process events
    let process_events: Vec<_> = entries.iter()
        .filter(|e| e.entry_type == "process_event")
        .collect();
    println!("\n🔄 Process Events:");
    for event in &process_events {
        if let Some(pid) = event.data.get("pid") {
            if let Some(comm) = event.data.get("comm") {
                println!("   PID {} ({}): event at time {}", 
                    pid, comm, event.timestamp);
            }
        }
    }

    // Demonstrate incident-style analysis
    println!("\n🚨 Incident Analysis Example:");
    let incident_time = base_time + 10_000_000_000; // 10 seconds in
    
    if let Some(system_state) = get_system_state_at(&entries, incident_time) {
        println!("   System state at incident time {}:", incident_time);
        if let Ok(snapshot) = serde_json::from_value::<MockSystemSnapshot>(system_state.data.clone()) {
            println!("     CPU: {:.1}%", snapshot.cpu_percent);
            println!("     Memory: {:.1}%", snapshot.mem_percent);
            println!("     CPU Pressure: {:.1}%", snapshot.psi_cpu_some_avg10);
            println!("     Active processes:");
            for proc in snapshot.active_processes {
                println!("       - PID {}: {} (CPU: {:.1}%, RSS: {}MB)", 
                    proc.pid, proc.comm, proc.cpu_percent, proc.rss_mb);
            }
        }
    }

    // Show process activity in time window
    let window_start = incident_time - 5_000_000_000; // 5 seconds before
    let window_end = incident_time + 5_000_000_000;   // 5 seconds after
    let events_in_window: Vec<_> = entries.iter()
        .filter(|e| e.entry_type == "process_event" && 
               e.timestamp >= window_start && e.timestamp <= window_end)
        .collect();
    
    println!("\n⏱️  Process events around incident time ({} second window):", 
        (window_end - window_start) / 1_000_000_000);
    for event in events_in_window {
        if let Some(pid) = event.data.get("pid") {
            if let Some(comm) = event.data.get("comm") {
                let relative_time = (event.timestamp as i64 - incident_time as i64) / 1_000_000_000;
                println!("     T{:+3}s: PID {} ({})", relative_time, pid, comm);
            }
        }
    }

    println!("\n✅ Example completed successfully!");
    println!("📁 Recording file: {}", recording_path);
    println!("\n💡 This demonstrates:");
    println!("   - V2 unified JSON format for events + snapshots");
    println!("   - File-only replay with complete isolation");
    println!("   - System state reproduction at specific times");
    println!("   - Process timeline analysis around incidents");
    println!("   - Memory and CPU tracking over time");

    Ok(())
}

// Helper functions (would be part of replay engine in real implementation)
fn load_recording_entries(path: &str) -> anyhow::Result<Vec<MockRecordingEntry>> {
    let content = std::fs::read_to_string(path)?;
    let mut entries = Vec::new();
    
    for line in content.lines() {
        if line.trim().is_empty() {
            continue;
        }
        let entry: MockRecordingEntry = serde_json::from_str(line)?;
        entries.push(entry);
    }
    
    entries.sort_by_key(|e| e.timestamp);
    Ok(entries)
}

fn get_system_state_at(entries: &[MockRecordingEntry], timestamp: u64) -> Option<&MockRecordingEntry> {
    entries.iter()
        .filter(|e| e.entry_type == "system_snapshot" && e.timestamp <= timestamp)
        .last()
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    example_recording_workflow().await
}