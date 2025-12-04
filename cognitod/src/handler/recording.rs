use crate::{ProcessEvent, types::SystemSnapshot, handler::Handler};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::fs::OpenOptions;
use tokio::io::{AsyncWriteExt, BufWriter};
use tokio::sync::Mutex;

#[derive(Serialize, Deserialize)]
struct RecordedProcessEvent {
    /// Timestamp when event was recorded (nanoseconds since epoch)
    timestamp: u64,
    /// The original ProcessEvent from eBPF
    event: ProcessEvent,
}

pub struct RecordingHandler {
    writer: Mutex<BufWriter<tokio::fs::File>>,
    events_recorded: AtomicU64,
}

impl RecordingHandler {
    pub async fn new(file_path: PathBuf) -> anyhow::Result<Self> {
        // Create parent directory if needed
        if let Some(parent) = file_path.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }

        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(file_path)
            .await?;

        Ok(Self {
            writer: Mutex::new(BufWriter::new(file)),
            events_recorded: AtomicU64::new(0),
        })
    }

    pub fn events_recorded(&self) -> u64 {
        self.events_recorded.load(Ordering::Relaxed)
    }
}

#[async_trait]
impl Handler for RecordingHandler {
    fn name(&self) -> &'static str {
        "recording"
    }

    async fn on_event(&self, event: &ProcessEvent) {
        let recorded_event = RecordedProcessEvent {
            timestamp: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos() as u64,
            event: event.clone(),
        };

        if let Ok(line) = serde_json::to_string(&recorded_event) {
            let mut writer = self.writer.lock().await;
            if let Err(e) = writer.write_all(format!("{}\n", line).as_bytes()).await {
                log::warn!("[recording] Failed to write event: {}", e);
            } else {
                self.events_recorded.fetch_add(1, Ordering::Relaxed);

                // Flush periodically for safety
                if self.events_recorded() % 100 == 0 {
                    let _ = writer.flush().await;
                }
            }
        }
    }

    async fn on_snapshot(&self, _snapshot: &SystemSnapshot) {
        // Phase 1: Ignore system snapshots
    }
}
