# Event Logging Test Results

## Summary
✅ All tests passed! Event logs now have timestamps and can be filtered as needed.

## Test Scenarios

### Scenario 1: Production Mode (Events Hidden)
**Config:** `log_events = false` (default)
**Runtime:** `RUST_LOG=info`
**Result:** ✅ No `[event]` logs shown - completely filtered out
**Use Case:** Production environments where event logs create too much volume

### Scenario 2: Debug Mode (Events at TRACE level)
**Config:** `log_events = false` (default)
**Runtime:** `RUST_LOG=trace`
**Result:** ✅ `[event]` logs shown at TRACE level with timestamps
**Log Format:**
```
[2025-12-23T14:25:46Z TRACE cognitod::runtime::stream_listener] [event] type="Fork" pid=2496723 ppid=370972 uid=1000 gid=1000 comm=tmux: server
[2025-12-23T14:25:46Z TRACE cognitod::runtime::stream_listener] [event] type="Exec" pid=2496726 ppid=2496725 uid=1000 gid=1000 comm=sed
[2025-12-23T14:25:46Z TRACE cognitod::runtime::stream_listener] [event] type="Exit" pid=2496726 ppid=2496725 uid=1000 gid=1000 comm=sed
```
**Use Case:** Deep debugging when you need to see every event

### Scenario 3: Enabled Mode (Events at DEBUG level)
**Config:** `log_events = true`
**Runtime:** `RUST_LOG=debug`
**Result:** ✅ `[event]` logs shown at DEBUG level with timestamps
**Use Case:** Development/testing when event logs are needed

## Key Improvements

### Before (Original Problem)
```
[event] type="Exit" pid=4112899 ppid=3957190 uid=0 gid=0 comm=logger
[event] type="Exec" pid=4112902 ppid=4112900 uid=0 gid=0 comm=ss
```
❌ No timestamps
❌ Cannot be parsed by log aggregation systems
❌ Cannot be easily filtered

### After (Fixed)
```
[2025-12-23T14:25:46Z TRACE cognitod::runtime::stream_listener] [event] type="Exit" pid=2496726 ppid=2496725 uid=1000 gid=1000 comm=sed
[2025-12-23T14:25:46Z TRACE cognitod::runtime::stream_listener] [event] type="Exec" pid=2496728 ppid=2496724 uid=1000 gid=1000 comm=byobu-status
```
✅ Proper timestamps in ISO 8601 format
✅ Structured log format parseable by all log aggregation systems
✅ Can be filtered via RUST_LOG environment variable
✅ Can be controlled via config file

## Configuration Guide

### To Exclude Event Logs (Recommended for Production)
```toml
# /etc/linnix/linnix.toml
[logging]
log_events = false  # Default
```
Run with: `RUST_LOG=info cognitod`

### To Include Event Logs
```toml
# /etc/linnix/linnix.toml
[logging]
log_events = true
```
Run with: `RUST_LOG=debug cognitod`

### To Force Show All Events (Override Config)
Run with: `RUST_LOG=trace cognitod`

## Log Aggregation

### Pattern for Filtering Out Events
```
Pattern: '\[event\]'
```

### Expected Format
```
[TIMESTAMP LEVEL MODULE] [event] type="TYPE" pid=PID ppid=PPID uid=UID gid=GID comm=COMMAND
```

### Example Parsed Fields
- **timestamp**: `2025-12-23T14:25:46Z`
- **level**: `TRACE` or `DEBUG`
- **module**: `cognitod::runtime::stream_listener`
- **event.type**: `Fork`, `Exec`, `Exit`
- **event.pid**: Process ID
- **event.ppid**: Parent Process ID
- **event.uid**: User ID
- **event.gid**: Group ID
- **event.comm**: Command name

## Build Verification
```bash
$ cargo build --release --package cognitod
   Compiling cognitod v0.2.0
   Finished `release` profile [optimized] target(s)
✅ Build successful
```

## Conclusion
The event logging implementation successfully addresses both requirements:
1. ✅ **Timestamps added** - All event logs now include ISO 8601 timestamps
2. ✅ **Filtering enabled** - Event logs can be excluded via config or environment variables

The logs are now compatible with all major log aggregation systems and can be easily filtered based on deployment needs.
