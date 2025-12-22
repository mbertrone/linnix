use crate::{ProcessEvent, handler::HandlerList, context::ContextStore, metrics::Metrics, types::SystemSnapshot};
use anyhow::Result;
use log::info;
use serde::{Deserialize, Serialize};
use std::{path::PathBuf, sync::Arc, time::Duration};
use tokio::{fs::File, io::{AsyncBufReadExt, BufReader}, time::sleep};

// V1 format: Legacy process events only
#[derive(Serialize, Deserialize)]
struct RecordedProcessEvent {
    timestamp: u64,
    event: ProcessEvent,
}

// V2 format: Unified entries with type field
#[derive(Serialize, Deserialize)]
struct RecordingEntry {
    #[serde(rename = "type")]
    entry_type: String,
    timestamp: u64,
    data: serde_json::Value,
}

enum ReplayEntry {
    ProcessEvent { timestamp: u64, event: ProcessEvent },
    SystemSnapshot { timestamp: u64, snapshot: SystemSnapshot },
}

pub async fn start_replay_listener(
    replay_file: PathBuf,
    context: Arc<ContextStore>,
    _metrics: Arc<Metrics>,
    handlers: Arc<HandlerList>,
    replay_speed: f32,
) -> Result<()> {
    info!("[replay] Starting replay from {}", replay_file.display());

    let file = File::open(&replay_file).await?;
    let reader = BufReader::new(file);
    let mut lines = reader.lines();

    let mut entries_replayed = 0u64;
    let mut process_events = 0u64;
    let mut snapshots = 0u64;
    let mut last_timestamp: Option<u64> = None;
    let mut detected_format: Option<String> = None;

    while let Some(line) = lines.next_line().await? {
        // Try to parse as V2 first, then fall back to V1
        let entry = match parse_entry(&line) {
            Ok(e) => {
                if detected_format.is_none() {
                    detected_format = Some(match &e {
                        ReplayEntry::ProcessEvent { .. } => {
                            // Could be V1 or V2, check if line has "type" field
                            if line.contains("\"type\"") {
                                "V2".to_string()
                            } else {
                                "V1".to_string()
                            }
                        }
                        ReplayEntry::SystemSnapshot { .. } => "V2".to_string(),
                    });
                    info!("[replay] Detected {} format", detected_format.as_ref().unwrap());
                }
                e
            }
            Err(e) => {
                log::warn!("[replay] Failed to parse line: {} - Error: {}", line, e);
                continue;
            }
        };

        let timestamp = match &entry {
            ReplayEntry::ProcessEvent { timestamp, .. } => *timestamp,
            ReplayEntry::SystemSnapshot { timestamp, .. } => *timestamp,
        };

        // Calculate delay for realistic timing
        if let Some(last_ts) = last_timestamp {
            let time_diff_ns = timestamp.saturating_sub(last_ts);
            let delay_ms = (time_diff_ns as f64 / 1_000_000.0 / replay_speed as f64) as u64;

            if delay_ms > 0 && delay_ms < 10_000 {
                // Cap at 10 seconds
                sleep(Duration::from_millis(delay_ms)).await;
            }
        }

        // Process the entry through appropriate handler
        match entry {
            ReplayEntry::ProcessEvent { event, .. } => {
                handlers.on_event(&event).await;
                context.add(event);
                process_events += 1;
            }
            ReplayEntry::SystemSnapshot { snapshot, .. } => {
                handlers.on_snapshot(&snapshot).await;
                snapshots += 1;
            }
        }

        entries_replayed += 1;
        last_timestamp = Some(timestamp);

        // Log progress periodically
        if entries_replayed % 1000 == 0 {
            info!(
                "[replay] Processed {} entries ({} events, {} snapshots)",
                entries_replayed, process_events, snapshots
            );
        }
    }

    info!(
        "[replay] Completed: {} entries replayed from {} ({} events, {} snapshots)",
        entries_replayed,
        replay_file.display(),
        process_events,
        snapshots
    );

    Ok(())
}

fn parse_entry(line: &str) -> Result<ReplayEntry> {
    // Try V2 format first (unified with type field)
    if let Ok(v2_entry) = serde_json::from_str::<RecordingEntry>(line) {
        match v2_entry.entry_type.as_str() {
            "process_event" => {
                let event: ProcessEvent = serde_json::from_value(v2_entry.data)?;
                return Ok(ReplayEntry::ProcessEvent {
                    timestamp: v2_entry.timestamp,
                    event,
                });
            }
            "system_snapshot" => {
                let snapshot: SystemSnapshot = serde_json::from_value(v2_entry.data)?;
                return Ok(ReplayEntry::SystemSnapshot {
                    timestamp: v2_entry.timestamp,
                    snapshot,
                });
            }
            unknown => {
                return Err(anyhow::anyhow!("Unknown entry type: {}", unknown));
            }
        }
    }

    // Fall back to V1 format (legacy)
    let v1_entry: RecordedProcessEvent = serde_json::from_str(line)?;
    Ok(ReplayEntry::ProcessEvent {
        timestamp: v1_entry.timestamp,
        event: v1_entry.event,
    })
}
