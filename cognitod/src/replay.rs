use serde::{Deserialize, Serialize};
use std::io::BufRead;
use std::path::Path;

/// Simple replay engine that operates ONLY on recorded data
/// CRITICAL: No live system access allowed during replay
pub struct SimpleReplayEngine {
    entries: Vec<ReplayEntry>,
    current_index: usize,
    replay_mode: bool, // Always true - prevents live system access
}

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct ReplayEntry {
    #[serde(rename = "type")]
    pub entry_type: String,
    pub timestamp: u64,
    pub data: serde_json::Value, // Keep as raw JSON for flexibility
}

impl SimpleReplayEngine {
    /// Load a recording file for replay - ONLY reads from file, no system access
    pub fn load_recording<P: AsRef<Path>>(path: P) -> anyhow::Result<Self> {
        let file = std::fs::File::open(path)?;
        let reader = std::io::BufReader::new(file);
        
        let mut entries = Vec::new();
        for line_result in reader.lines() {
            let line = line_result?;
            if line.trim().is_empty() {
                continue;
            }
            
            let entry: ReplayEntry = serde_json::from_str(&line)
                .with_context(|| format!("Failed to parse line: {}", line))?;
            entries.push(entry);
        }
        
        // Sort by timestamp to ensure chronological order
        entries.sort_by_key(|e| e.timestamp);
        
        Ok(Self { 
            entries, 
            current_index: 0,
            replay_mode: true  // CRITICAL: Mark as replay-only mode
        })
    }

    /// Seek to a specific timestamp - ONLY uses recorded data
    pub fn seek_to_time(&mut self, target_timestamp: u64) -> Option<&ReplayEntry> {
        // REPLAY ONLY: Use binary search on recorded data
        self.current_index = self.entries
            .binary_search_by_key(&target_timestamp, |e| e.timestamp)
            .unwrap_or_else(|i| i.min(self.entries.len().saturating_sub(1)));
            
        self.entries.get(self.current_index)
    }

    /// Get system state at specific timestamp - ONLY from recorded snapshots
    pub fn get_system_state_at(&self, timestamp: u64) -> Option<&serde_json::Value> {
        // REPLAY ONLY: Find nearest recorded system_snapshot before timestamp
        let end_index = self.entries
            .binary_search_by_key(&timestamp, |e| e.timestamp)
            .unwrap_or_else(|i| i);
            
        for entry in self.entries[..=end_index.min(self.current_index)].iter().rev() {
            if entry.entry_type == "system_snapshot" && entry.timestamp <= timestamp {
                return Some(&entry.data);
            }
        }
        None
    }

    /// Get process events in time range - ONLY from recorded data
    pub fn get_process_events_in_range(&self, start_ts: u64, end_ts: u64) -> Vec<&ReplayEntry> {
        // REPLAY ONLY: Filter recorded process events by timestamp range
        self.entries.iter()
            .filter(|entry| {
                entry.entry_type == "process_event" &&
                entry.timestamp >= start_ts && 
                entry.timestamp <= end_ts
            })
            .collect()
    }

    /// Get all entries (for debugging and analysis)
    pub fn get_all_entries(&self) -> &[ReplayEntry] {
        &self.entries
    }

    /// Get total number of entries loaded
    pub fn entry_count(&self) -> usize {
        self.entries.len()
    }

    /// Get time range of the recording
    pub fn time_range(&self) -> Option<(u64, u64)> {
        if self.entries.is_empty() {
            return None;
        }
        Some((
            self.entries.first().unwrap().timestamp,
            self.entries.last().unwrap().timestamp,
        ))
    }

    /// Count entries by type
    pub fn count_entries_by_type(&self) -> std::collections::HashMap<String, usize> {
        let mut counts = std::collections::HashMap::new();
        for entry in &self.entries {
            *counts.entry(entry.entry_type.clone()).or_insert(0) += 1;
        }
        counts
    }

    /// Verify this is in replay mode (should always be true)
    pub fn is_replay_mode(&self) -> bool {
        self.replay_mode
    }
}

// Helper function to ensure we never accidentally access live system during replay
#[allow(dead_code)]
fn assert_replay_only_operation(engine: &SimpleReplayEngine) {
    if !engine.is_replay_mode() {
        panic!("CRITICAL: Attempted live system access during replay mode");
    }
}

// Import context for error handling
use anyhow::Context;