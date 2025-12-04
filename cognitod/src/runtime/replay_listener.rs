use crate::{ProcessEvent, handler::HandlerList, context::ContextStore, metrics::Metrics};
use anyhow::Result;
use log::info;
use serde::{Deserialize, Serialize};
use std::{path::PathBuf, sync::Arc, time::Duration};
use tokio::{fs::File, io::{AsyncBufReadExt, BufReader}, time::sleep};

#[derive(Serialize, Deserialize)]
struct RecordedProcessEvent {
    timestamp: u64,
    event: ProcessEvent,
}

pub async fn start_replay_listener(
    replay_file: PathBuf,
    context: Arc<ContextStore>,
    _metrics: Arc<Metrics>,
    handlers: Arc<HandlerList>,
    replay_speed: f32,
) -> Result<()> {
    info!("[cognitod] Starting replay from {}", replay_file.display());

    let file = File::open(&replay_file).await?;
    let reader = BufReader::new(file);
    let mut lines = reader.lines();

    let mut events_replayed = 0u64;
    let mut last_timestamp: Option<u64> = None;

    while let Some(line) = lines.next_line().await? {
        let recorded_event: RecordedProcessEvent = match serde_json::from_str(&line) {
            Ok(event) => event,
            Err(e) => {
                log::warn!("[replay] Failed to parse line: {} - Error: {}", line, e);
                continue;
            }
        };

        // Calculate delay for realistic timing
        if let Some(last_ts) = last_timestamp {
            let time_diff_ns = recorded_event.timestamp.saturating_sub(last_ts);
            let delay_ms = (time_diff_ns as f64 / 1_000_000.0 / replay_speed as f64) as u64;

            if delay_ms > 0 && delay_ms < 10_000 {
                // Cap at 10 seconds
                sleep(Duration::from_millis(delay_ms)).await;
            }
        }

        // Process the event through normal pipeline
        let event = recorded_event.event;
        handlers.on_event(&event).await;
        context.add(event);

        events_replayed += 1;
        last_timestamp = Some(recorded_event.timestamp);

        // Log progress periodically
        if events_replayed % 1000 == 0 {
            info!("[replay] Processed {} events", events_replayed);
        }
    }

    info!(
        "[replay] Completed: {} events replayed from {}",
        events_replayed,
        replay_file.display()
    );

    Ok(())
}
