use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SystemSnapshot {
    pub timestamp: u64,
    pub cpu_percent: f32,
    pub mem_percent: f32,
    pub load_avg: [f32; 3],
    pub disk_read_bytes: u64,
    pub disk_write_bytes: u64,
    pub net_rx_bytes: u64,
    pub net_tx_bytes: u64,
    // PSI (Pressure Stall Information) - measures STALL TIME not just usage
    // Key insight: 100% CPU with 5% PSI = efficient. 40% CPU with 60% PSI = disaster.
    pub psi_cpu_some_avg10: f32, // % time tasks stalled waiting for CPU (10s avg)
    pub psi_memory_some_avg10: f32, // % time tasks stalled waiting for memory
    pub psi_memory_full_avg10: f32, // % time ALL tasks stalled (complete thrashing)
    pub psi_io_some_avg10: f32,  // % time tasks stalled on I/O
    pub psi_io_full_avg10: f32,  // % time ALL tasks stalled on I/O
}

// V2: Enhanced system snapshot with process information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EnhancedSystemSnapshot {
    // All existing SystemSnapshot fields
    pub timestamp: u64,
    pub cpu_percent: f32,
    pub mem_percent: f32,
    pub load_avg: [f32; 3],
    pub disk_read_bytes: u64,
    pub disk_write_bytes: u64,
    pub net_rx_bytes: u64,
    pub net_tx_bytes: u64,
    pub psi_cpu_some_avg10: f32,
    pub psi_memory_some_avg10: f32,
    pub psi_memory_full_avg10: f32,
    pub psi_io_some_avg10: f32,
    pub psi_io_full_avg10: f32,
    
    // V2: Additional process information
    pub active_processes: Vec<ProcessSnapshotEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessSnapshotEntry {
    pub pid: u32,
    pub comm: String,
    pub cpu_percent: f32,
    pub mem_percent: f32,
    pub rss_mb: u64,
}

impl From<SystemSnapshot> for EnhancedSystemSnapshot {
    fn from(snapshot: SystemSnapshot) -> Self {
        Self {
            timestamp: snapshot.timestamp,
            cpu_percent: snapshot.cpu_percent,
            mem_percent: snapshot.mem_percent,
            load_avg: snapshot.load_avg,
            disk_read_bytes: snapshot.disk_read_bytes,
            disk_write_bytes: snapshot.disk_write_bytes,
            net_rx_bytes: snapshot.net_rx_bytes,
            net_tx_bytes: snapshot.net_tx_bytes,
            psi_cpu_some_avg10: snapshot.psi_cpu_some_avg10,
            psi_memory_some_avg10: snapshot.psi_memory_some_avg10,
            psi_memory_full_avg10: snapshot.psi_memory_full_avg10,
            psi_io_some_avg10: snapshot.psi_io_some_avg10,
            psi_io_full_avg10: snapshot.psi_io_full_avg10,
            active_processes: Vec::new(),
        }
    }
}

#[derive(Debug, Serialize, Clone)]
pub struct ProcessAlert {
    pub pid: u32,
    pub comm: String,
    pub cpu_percent: Option<f32>,
    pub mem_percent: Option<f32>,
    pub event_type: u32,
    pub reason: String,
}
