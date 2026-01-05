use crate::{ProcessEvent, types::{SystemSnapshot, EnhancedSystemSnapshot}, handler::Handler};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::fs::OpenOptions;
use tokio::io::{AsyncWriteExt, BufWriter, AsyncWrite};
use tokio::sync::Mutex;
use async_compression::tokio::write::GzipEncoder;

#[derive(Serialize, Deserialize)]
struct RecordedProcessEvent {
    /// Timestamp when event was recorded (nanoseconds since epoch)
    timestamp: u64,
    /// The original ProcessEvent from eBPF
    event: ProcessEvent,
}

// V2: Unified entry format for both process events and system snapshots
#[derive(Serialize, Deserialize)]
struct RecordingEntry {
    #[serde(rename = "type")]
    entry_type: String,
    timestamp: u64,
    data: serde_json::Value,
}

pub struct RecordingHandler {
    writer: Mutex<Box<dyn AsyncWrite + Send + Unpin>>,
    events_recorded: AtomicU64,
    snapshots_recorded: AtomicU64,
    v2_format: bool, // Enable V2 unified JSON format
}

impl RecordingHandler {
    pub async fn new(file_path: PathBuf) -> anyhow::Result<Self> {
        Self::new_with_options(file_path, false, false).await
    }

    pub async fn new_with_options(
        file_path: PathBuf,
        v2_format: bool,
        compress_output: bool,
    ) -> anyhow::Result<Self> {
        // Create parent directory if needed
        if let Some(parent) = file_path.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }

        // Append .gz if compression enabled and not already present
        let actual_path = if compress_output {
            let path_str = file_path.to_string_lossy();
            if path_str.ends_with(".gz") {
                file_path
            } else {
                // Add .gz extension
                PathBuf::from(format!("{}.gz", path_str))
            }
        } else {
            file_path
        };

        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&actual_path)
            .await?;

        // Create writer with or without compression
        let writer: Box<dyn AsyncWrite + Send + Unpin> = if compress_output {
            Box::new(BufWriter::new(GzipEncoder::new(file)))
        } else {
            Box::new(BufWriter::new(file))
        };

        log::info!(
            "[recording] Initialized recording to {} (compression: {})",
            actual_path.display(),
            if compress_output { "enabled" } else { "disabled" }
        );

        Ok(Self {
            writer: Mutex::new(writer),
            events_recorded: AtomicU64::new(0),
            snapshots_recorded: AtomicU64::new(0),
            v2_format,
        })
    }

    pub fn events_recorded(&self) -> u64 {
        self.events_recorded.load(Ordering::Relaxed)
    }

    pub fn snapshots_recorded(&self) -> u64 {
        self.snapshots_recorded.load(Ordering::Relaxed)
    }

    /// Gracefully shutdown the recording handler, ensuring all data is flushed
    /// and the gzip stream is properly finalized
    pub async fn shutdown(&self) -> anyhow::Result<()> {
        log::info!(
            "[recording] Shutting down gracefully ({} events, {} snapshots recorded)",
            self.events_recorded(),
            self.snapshots_recorded()
        );

        let mut writer = self.writer.lock().await;

        // Flush any buffered data
        writer.flush().await?;

        // Shutdown the writer (this finalizes gzip stream if compressed)
        writer.shutdown().await?;

        log::info!("[recording] Recording handler shut down successfully");
        Ok(())
    }

    // V2: Record enhanced system snapshot in unified format
    pub async fn record_enhanced_snapshot(&self, enhanced_snapshot: &EnhancedSystemSnapshot) -> anyhow::Result<()> {
        let timestamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos() as u64;

        let entry = RecordingEntry {
            entry_type: "system_snapshot".to_string(),
            timestamp,
            data: serde_json::to_value(enhanced_snapshot)?,
        };

        let line = serde_json::to_string(&entry)?;
        let mut writer = self.writer.lock().await;
        writer.write_all(format!("{}\n", line).as_bytes()).await?;
        self.snapshots_recorded.fetch_add(1, Ordering::Relaxed);

        // Flush periodically for safety
        if (self.events_recorded() + self.snapshots_recorded()) % 100 == 0 {
            writer.flush().await?;
        }

        Ok(())
    }

    // V2: Record system snapshot in unified format (backward compatibility)
    async fn record_system_snapshot(&self, snapshot: &SystemSnapshot) -> anyhow::Result<()> {
        // Convert to enhanced snapshot without process data for backward compatibility
        let enhanced = EnhancedSystemSnapshot::from(snapshot.clone());
        self.record_enhanced_snapshot(&enhanced).await
    }
}

#[async_trait]
impl Handler for RecordingHandler {
    fn name(&self) -> &'static str {
        "recording"
    }

    async fn on_event(&self, event: &ProcessEvent) {
        let timestamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos() as u64;

        let result = if self.v2_format {
            // V2: Unified JSON format
            let entry = RecordingEntry {
                entry_type: "process_event".to_string(),
                timestamp,
                data: serde_json::to_value(event).unwrap_or_default(),
            };
            serde_json::to_string(&entry)
        } else {
            // V1: Legacy format (backward compatibility)
            let recorded_event = RecordedProcessEvent {
                timestamp,
                event: event.clone(),
            };
            serde_json::to_string(&recorded_event)
        };

        if let Ok(line) = result {
            let mut writer = self.writer.lock().await;
            if let Err(e) = writer.write_all(format!("{}\n", line).as_bytes()).await {
                log::warn!("[recording] Failed to write event: {}", e);
            } else {
                self.events_recorded.fetch_add(1, Ordering::Relaxed);

                // Flush periodically for safety
                if (self.events_recorded() + self.snapshots_recorded()) % 100 == 0 {
                    let _ = writer.flush().await;
                }
            }
        }
    }

    async fn on_snapshot(&self, snapshot: &SystemSnapshot) {
        if self.v2_format {
            if let Err(e) = self.record_system_snapshot(snapshot).await {
                log::warn!("[recording] Failed to write system snapshot: {}", e);
            }
        }
        // V1 format ignores snapshots for backward compatibility
    }
}
