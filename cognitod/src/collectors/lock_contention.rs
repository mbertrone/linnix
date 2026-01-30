//! Lock contention monitoring collector
//!
//! Receives LockContention events from eBPF and aggregates statistics by lock type
//! and by process. Logs periodic summaries and exposes data via API endpoint.
//!
//! ## Scalability Design
//! - **Sharded state**: 16 shards to reduce lock contention (accessed by pid % NUM_SHARDS)
//! - **Bounded tracking**: Max processes per shard prevents unbounded memory growth
//! - **Reduced allocations**: Uses pid as key, stores comm in value (one allocation per new process)
//! - **Atomic counters**: Global counters updated without locks for fast path

use async_trait::async_trait;
use linnix_ai_ebpf_common::{lock_flags, EventType};
use log::info;
use serde::Serialize;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::config::LockContentionConfig;
use crate::handler::Handler;
use crate::types::SystemSnapshot;
use crate::ProcessEvent;

/// Number of shards for parallel access (must be power of 2)
const NUM_SHARDS: usize = 16;
const SHARD_MASK: u32 = (NUM_SHARDS - 1) as u32;

/// Maximum processes tracked per shard (total max = NUM_SHARDS * MAX_PROCESSES_PER_SHARD)
const MAX_PROCESSES_PER_SHARD: usize = 256;

/// Maximum number of top processes to report
const MAX_TOP_PROCESSES: usize = 5;

/// Statistics for a specific lock type
#[derive(Default, Clone, Serialize)]
pub struct LockTypeStats {
    /// Total number of contention events
    pub contention_count: u64,
    /// Total wait time in nanoseconds
    pub total_wait_ns: u64,
    /// Maximum single wait time in nanoseconds
    pub max_wait_ns: u64,
}

impl LockTypeStats {
    fn merge(&mut self, other: &LockTypeStats) {
        self.contention_count += other.contention_count;
        self.total_wait_ns += other.total_wait_ns;
        if other.max_wait_ns > self.max_wait_ns {
            self.max_wait_ns = other.max_wait_ns;
        }
    }
}

/// Per-process contention statistics
#[derive(Default, Clone, Serialize)]
pub struct ProcessContention {
    /// Process ID
    pub pid: u32,
    /// Process name (comm)
    pub comm: String,
    /// Total number of contention events
    pub contention_count: u64,
    /// Total wait time in nanoseconds
    pub total_wait_ns: u64,
    /// Maximum single wait time in nanoseconds
    pub max_wait_ns: u64,
}

/// Aggregated lock contention statistics
#[derive(Default, Clone, Serialize)]
pub struct LockContentionStats {
    pub spinlock: LockTypeStats,
    pub mutex: LockTypeStats,
    pub rwlock_read: LockTypeStats,
    pub rwlock_write: LockTypeStats,
    pub rtmutex: LockTypeStats,
    pub percpu: LockTypeStats,
    pub other: LockTypeStats,
    /// Top processes by total wait time (sorted descending)
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub top_processes: Vec<ProcessContention>,
}

impl LockContentionStats {
    fn merge(&mut self, other: &LockContentionStats) {
        self.spinlock.merge(&other.spinlock);
        self.mutex.merge(&other.mutex);
        self.rwlock_read.merge(&other.rwlock_read);
        self.rwlock_write.merge(&other.rwlock_write);
        self.rtmutex.merge(&other.rtmutex);
        self.percpu.merge(&other.percpu);
        self.other.merge(&other.other);
    }

    fn total_events(&self) -> u64 {
        self.spinlock.contention_count
            + self.mutex.contention_count
            + self.rwlock_read.contention_count
            + self.rwlock_write.contention_count
            + self.rtmutex.contention_count
            + self.percpu.contention_count
            + self.other.contention_count
    }
}

/// Per-shard state for stats accumulation
struct ShardState {
    stats: LockContentionStats,
    /// Per-process stats: pid -> ProcessContention
    /// Using pid as key avoids string allocation on lookup
    by_process: HashMap<u32, ProcessContention>,
}

impl Default for ShardState {
    fn default() -> Self {
        Self {
            stats: LockContentionStats::default(),
            by_process: HashMap::with_capacity(64), // Pre-allocate for typical usage
        }
    }
}

impl ShardState {
    fn clear(&mut self) {
        self.stats = LockContentionStats::default();
        self.by_process.clear();
    }
}

/// Lock contention collector with sharded state for scalability
pub struct LockContentionCollector {
    /// Sharded state - each shard has its own lock
    shards: [Mutex<ShardState>; NUM_SHARDS],
    /// Last log time (shared across shards)
    last_log_time: Mutex<Instant>,
    log_interval: Duration,
    enabled: bool,
    log_summary: bool,
    // Atomic counters for quick stats (no lock needed)
    total_events: AtomicU64,
    total_wait_ns: AtomicU64,
}

impl LockContentionCollector {
    pub fn new(config: &LockContentionConfig) -> Self {
        info!(
            "[lock-contention] initializing collector enabled={} log_summary={} log_interval={}s shards={}",
            config.enabled, config.log_summary, config.log_interval_secs, NUM_SHARDS
        );
        Self {
            shards: std::array::from_fn(|_| Mutex::new(ShardState::default())),
            last_log_time: Mutex::new(Instant::now()),
            log_interval: Duration::from_secs(config.log_interval_secs),
            enabled: config.enabled,
            log_summary: config.log_summary,
            total_events: AtomicU64::new(0),
            total_wait_ns: AtomicU64::new(0),
        }
    }

    /// Get shard index for a pid
    #[inline]
    fn shard_index(pid: u32) -> usize {
        (pid & SHARD_MASK) as usize
    }

    /// Record a lock contention event with process attribution
    pub fn record_contention(&self, flags: u32, duration_ns: u64, pid: u32, comm: &str) {
        if !self.enabled {
            return;
        }

        // Update atomic counters (lock-free fast path)
        self.total_events.fetch_add(1, Ordering::Relaxed);
        self.total_wait_ns.fetch_add(duration_ns, Ordering::Relaxed);

        // Get the appropriate shard
        let shard_idx = Self::shard_index(pid);
        let mut shard = self.shards[shard_idx].lock().unwrap();

        // Update per-lock-type stats
        let lock_stats = classify_lock_type(flags, &mut shard.stats);
        lock_stats.contention_count += 1;
        lock_stats.total_wait_ns += duration_ns;
        if duration_ns > lock_stats.max_wait_ns {
            lock_stats.max_wait_ns = duration_ns;
        }

        // Update per-process stats
        // Check if we need to evict before inserting
        if !shard.by_process.contains_key(&pid) && shard.by_process.len() >= MAX_PROCESSES_PER_SHARD {
            // Evict the process with lowest total_wait_ns
            if let Some((&evict_pid, _)) = shard
                .by_process
                .iter()
                .min_by_key(|(_, v)| v.total_wait_ns)
            {
                shard.by_process.remove(&evict_pid);
            }
        }

        let proc_stats = shard.by_process.entry(pid).or_insert_with(|| ProcessContention {
            pid,
            comm: comm.to_string(), // Only allocate when new process seen
            contention_count: 0,
            total_wait_ns: 0,
            max_wait_ns: 0,
        });
        proc_stats.contention_count += 1;
        proc_stats.total_wait_ns += duration_ns;
        if duration_ns > proc_stats.max_wait_ns {
            proc_stats.max_wait_ns = duration_ns;
        }

        // Drop shard lock before checking log time
        drop(shard);

        // Check if we should log stats (only if log_summary is enabled)
        if self.log_summary {
            self.maybe_log_stats();
        }
    }

    /// Check if it's time to log and do so if needed
    fn maybe_log_stats(&self) {
        let mut last_log = self.last_log_time.lock().unwrap();
        if last_log.elapsed() < self.log_interval {
            return;
        }

        // Collect stats from all shards
        let (stats, by_process) = self.collect_all_shards();

        // Log the stats
        self.log_stats(&stats, &by_process);

        // Clear all shards
        for shard in &self.shards {
            shard.lock().unwrap().clear();
        }

        *last_log = Instant::now();
    }

    /// Collect and merge stats from all shards
    fn collect_all_shards(&self) -> (LockContentionStats, HashMap<u32, ProcessContention>) {
        let mut combined_stats = LockContentionStats::default();
        let mut combined_procs: HashMap<u32, ProcessContention> = HashMap::new();

        for shard in &self.shards {
            let shard = shard.lock().unwrap();
            combined_stats.merge(&shard.stats);

            for (pid, proc) in &shard.by_process {
                combined_procs
                    .entry(*pid)
                    .and_modify(|existing| {
                        existing.contention_count += proc.contention_count;
                        existing.total_wait_ns += proc.total_wait_ns;
                        if proc.max_wait_ns > existing.max_wait_ns {
                            existing.max_wait_ns = proc.max_wait_ns;
                        }
                    })
                    .or_insert_with(|| proc.clone());
            }
        }

        (combined_stats, combined_procs)
    }

    /// Get current stats snapshot with top processes
    pub fn get_stats(&self) -> LockContentionStats {
        let (mut stats, by_process) = self.collect_all_shards();
        stats.top_processes = get_top_processes(&by_process, MAX_TOP_PROCESSES);
        stats
    }

    /// Check if the collector is enabled
    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    fn log_stats(&self, stats: &LockContentionStats, by_process: &HashMap<u32, ProcessContention>) {
        let total_events = stats.total_events();

        if total_events == 0 {
            return;
        }

        info!(
            "[lock-contention] summary: {} total contentions",
            total_events
        );

        // Log non-zero lock types
        if stats.spinlock.contention_count > 0 {
            info!(
                "[lock-contention]   spinlock: {} events, {}us total, {}us max",
                stats.spinlock.contention_count,
                stats.spinlock.total_wait_ns / 1000,
                stats.spinlock.max_wait_ns / 1000
            );
        }
        if stats.mutex.contention_count > 0 {
            info!(
                "[lock-contention]   mutex: {} events, {}us total, {}us max",
                stats.mutex.contention_count,
                stats.mutex.total_wait_ns / 1000,
                stats.mutex.max_wait_ns / 1000
            );
        }
        if stats.rwlock_read.contention_count > 0 {
            info!(
                "[lock-contention]   rwlock_read: {} events, {}us total, {}us max",
                stats.rwlock_read.contention_count,
                stats.rwlock_read.total_wait_ns / 1000,
                stats.rwlock_read.max_wait_ns / 1000
            );
        }
        if stats.rwlock_write.contention_count > 0 {
            info!(
                "[lock-contention]   rwlock_write: {} events, {}us total, {}us max",
                stats.rwlock_write.contention_count,
                stats.rwlock_write.total_wait_ns / 1000,
                stats.rwlock_write.max_wait_ns / 1000
            );
        }
        if stats.rtmutex.contention_count > 0 {
            info!(
                "[lock-contention]   rtmutex: {} events, {}us total, {}us max",
                stats.rtmutex.contention_count,
                stats.rtmutex.total_wait_ns / 1000,
                stats.rtmutex.max_wait_ns / 1000
            );
        }
        if stats.percpu.contention_count > 0 {
            info!(
                "[lock-contention]   percpu: {} events, {}us total, {}us max",
                stats.percpu.contention_count,
                stats.percpu.total_wait_ns / 1000,
                stats.percpu.max_wait_ns / 1000
            );
        }
        if stats.other.contention_count > 0 {
            info!(
                "[lock-contention]   other: {} events, {}us total, {}us max",
                stats.other.contention_count,
                stats.other.total_wait_ns / 1000,
                stats.other.max_wait_ns / 1000
            );
        }

        // Log top contending processes
        let top_procs = get_top_processes(by_process, 3);
        if !top_procs.is_empty() {
            let proc_summary: Vec<String> = top_procs
                .iter()
                .map(|p| {
                    format!(
                        "{}({}) {}us/{}",
                        p.comm,
                        p.pid,
                        p.total_wait_ns / 1000,
                        p.contention_count
                    )
                })
                .collect();
            info!(
                "[lock-contention]   top_processes: {}",
                proc_summary.join(", ")
            );
        }
    }
}

/// Get top N processes sorted by total wait time (descending)
fn get_top_processes(
    by_process: &HashMap<u32, ProcessContention>,
    limit: usize,
) -> Vec<ProcessContention> {
    let mut procs: Vec<ProcessContention> = by_process.values().cloned().collect();
    procs.sort_by(|a, b| b.total_wait_ns.cmp(&a.total_wait_ns));
    procs.truncate(limit);
    procs
}

/// Classify lock type from flags and return mutable reference to appropriate stats
fn classify_lock_type(flags: u32, stats: &mut LockContentionStats) -> &mut LockTypeStats {
    // Check flags in order of specificity
    if flags & lock_flags::LCB_F_PERCPU != 0 {
        return &mut stats.percpu;
    }
    if flags & lock_flags::LCB_F_RT != 0 {
        return &mut stats.rtmutex;
    }
    if flags & lock_flags::LCB_F_SPIN != 0 {
        return &mut stats.spinlock;
    }
    // Read/write locks (rwlock or rwsem)
    if flags & lock_flags::LCB_F_READ != 0 {
        return &mut stats.rwlock_read;
    }
    if flags & lock_flags::LCB_F_WRITE != 0 {
        return &mut stats.rwlock_write;
    }
    // No flags typically means mutex
    if flags == lock_flags::LCB_F_MUTEX {
        return &mut stats.mutex;
    }
    &mut stats.other
}

#[async_trait]
impl Handler for LockContentionCollector {
    fn name(&self) -> &'static str {
        "lock_contention"
    }

    async fn on_event(&self, event: &ProcessEvent) {
        if event.event_type != EventType::LockContention as u32 {
            return;
        }

        // Extract lock contention data from event fields
        let duration_ns = event.data2;
        let flags = event.aux;
        let pid = event.pid;
        let comm = std::str::from_utf8(&event.comm)
            .unwrap_or("?")
            .trim_end_matches('\0');

        self.record_contention(flags, duration_ns, pid, comm);
    }

    async fn on_snapshot(&self, _snapshot: &SystemSnapshot) {
        // No action needed on snapshots
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_classify_lock_type() {
        let mut stats = LockContentionStats::default();

        // Test spinlock
        let lock_stats = classify_lock_type(lock_flags::LCB_F_SPIN, &mut stats);
        lock_stats.contention_count = 1;
        assert_eq!(stats.spinlock.contention_count, 1);

        // Test mutex (no flags)
        let lock_stats = classify_lock_type(lock_flags::LCB_F_MUTEX, &mut stats);
        lock_stats.contention_count = 2;
        assert_eq!(stats.mutex.contention_count, 2);

        // Test read lock
        let lock_stats = classify_lock_type(lock_flags::LCB_F_READ, &mut stats);
        lock_stats.contention_count = 3;
        assert_eq!(stats.rwlock_read.contention_count, 3);

        // Test write lock
        let lock_stats = classify_lock_type(lock_flags::LCB_F_WRITE, &mut stats);
        lock_stats.contention_count = 4;
        assert_eq!(stats.rwlock_write.contention_count, 4);

        // Test RT mutex
        let lock_stats = classify_lock_type(lock_flags::LCB_F_RT, &mut stats);
        lock_stats.contention_count = 5;
        assert_eq!(stats.rtmutex.contention_count, 5);

        // Test percpu
        let lock_stats = classify_lock_type(lock_flags::LCB_F_PERCPU, &mut stats);
        lock_stats.contention_count = 6;
        assert_eq!(stats.percpu.contention_count, 6);
    }

    #[test]
    fn test_record_contention() {
        let config = LockContentionConfig {
            enabled: true,
            log_summary: false,
            log_interval_secs: 3600,
        };
        let collector = LockContentionCollector::new(&config);

        // Record some contentions from different processes
        collector.record_contention(lock_flags::LCB_F_SPIN, 1000, 1234, "stress-ng");
        collector.record_contention(lock_flags::LCB_F_SPIN, 2000, 1234, "stress-ng");
        collector.record_contention(lock_flags::LCB_F_MUTEX, 500, 5678, "postgres");

        let stats = collector.get_stats();
        assert_eq!(stats.spinlock.contention_count, 2);
        assert_eq!(stats.spinlock.total_wait_ns, 3000);
        assert_eq!(stats.spinlock.max_wait_ns, 2000);
        assert_eq!(stats.mutex.contention_count, 1);
        assert_eq!(stats.mutex.total_wait_ns, 500);

        // Check per-process stats
        assert_eq!(stats.top_processes.len(), 2);
        assert_eq!(stats.top_processes[0].comm, "stress-ng");
        assert_eq!(stats.top_processes[0].total_wait_ns, 3000);
        assert_eq!(stats.top_processes[1].comm, "postgres");
        assert_eq!(stats.top_processes[1].total_wait_ns, 500);
    }

    #[test]
    fn test_disabled_collector() {
        let config = LockContentionConfig {
            enabled: false,
            log_summary: false,
            log_interval_secs: 60,
        };
        let collector = LockContentionCollector::new(&config);

        // Recording should be a no-op when disabled
        collector.record_contention(lock_flags::LCB_F_SPIN, 1000, 1234, "test");

        let stats = collector.get_stats();
        assert_eq!(stats.spinlock.contention_count, 0);
    }

    #[test]
    fn test_top_processes_sorted_by_wait_time() {
        let config = LockContentionConfig {
            enabled: true,
            log_summary: false,
            log_interval_secs: 3600,
        };
        let collector = LockContentionCollector::new(&config);

        // Record contentions with different wait times
        collector.record_contention(lock_flags::LCB_F_SPIN, 100, 1, "low");
        collector.record_contention(lock_flags::LCB_F_SPIN, 5000, 2, "high");
        collector.record_contention(lock_flags::LCB_F_SPIN, 1000, 3, "medium");

        let stats = collector.get_stats();
        assert_eq!(stats.top_processes.len(), 3);
        // Should be sorted by total_wait_ns descending
        assert_eq!(stats.top_processes[0].comm, "high");
        assert_eq!(stats.top_processes[1].comm, "medium");
        assert_eq!(stats.top_processes[2].comm, "low");
    }

    #[test]
    fn test_sharding_distributes_by_pid() {
        // Verify shard index calculation
        assert_eq!(LockContentionCollector::shard_index(0), 0);
        assert_eq!(LockContentionCollector::shard_index(1), 1);
        assert_eq!(LockContentionCollector::shard_index(15), 15);
        assert_eq!(LockContentionCollector::shard_index(16), 0); // Wraps
        assert_eq!(LockContentionCollector::shard_index(17), 1);
        assert_eq!(LockContentionCollector::shard_index(1000), 1000 % 16);
    }

    #[test]
    fn test_bounded_process_tracking() {
        let config = LockContentionConfig {
            enabled: true,
            log_summary: false,
            log_interval_secs: 3600,
        };
        let collector = LockContentionCollector::new(&config);

        // Fill up one shard beyond capacity
        // All PIDs with same shard index (pid % 16 == 0)
        for i in 0..(MAX_PROCESSES_PER_SHARD + 10) {
            let pid = (i * NUM_SHARDS) as u32; // All go to shard 0
            collector.record_contention(lock_flags::LCB_F_SPIN, 100, pid, &format!("proc{}", i));
        }

        // Verify shard doesn't exceed capacity
        let shard = collector.shards[0].lock().unwrap();
        assert!(shard.by_process.len() <= MAX_PROCESSES_PER_SHARD);
    }
}
