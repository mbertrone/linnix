# Event Logging Configuration Guide

## Problem

When ingesting cognitod logs into log aggregation systems, event logs (Fork/Exec/Exit events) were:

1. **Missing timestamps** - They used `println!` instead of proper logging macros
2. **Too verbose** - Created excessive log volume
3. **Unparseable** - All events were treated as a single log line

## Solution

We've updated cognitod to use proper structured logging with timestamps for event logs. You now have two options:

### Option 1: Disable Event Logs (Recommended for Production)

Event logs are now **disabled by default**. When disabled, they're logged at `TRACE` level, which is filtered out by most logging configurations.

**No configuration needed** - just use the default settings.

### Option 2: Enable Event Logs with Timestamps

If you want to see event logs with proper timestamps, add this to your `/etc/linnix/linnix.toml`:

```toml
[logging]
log_events = true
```

With this configuration:
- Event logs are logged at `DEBUG` level
- Each log has a timestamp: `[2025-12-23T14:01:46Z DEBUG cognitod::runtime::stream_listener] [event] type="Exit" pid=4112899...`
- Logs are properly parsed by log aggregation systems

### Option 3: Control via Environment Variable

You can also control log verbosity at runtime using the `RUST_LOG` environment variable:

```bash
# Hide all event logs (recommended for production)
RUST_LOG=cognitod=info ./cognitod

# Show event logs regardless of config (useful for debugging)
RUST_LOG=cognitod=debug ./cognitod

# Show ALL logs including trace-level events
RUST_LOG=cognitod=trace ./cognitod
```

## Log Format Comparison

### Before (no timestamps, unparseable):
```
[event] type="Exit" pid=4112899 ppid=3957190 uid=0 gid=0 comm=logger
[event] type="Exec" pid=4112902 ppid=4112900 uid=0 gid=0 comm=ss
```

### After (with timestamps, structured):
```
[2025-12-23T14:01:46Z DEBUG cognitod::runtime::stream_listener] [event] type="Exit" pid=4112899 ppid=3957190 uid=0 gid=0 comm=logger
[2025-12-23T14:01:46Z DEBUG cognitod::runtime::stream_listener] [event] type="Exec" pid=4112902 ppid=4112900 uid=0 gid=0 comm=ss
```

## Log Aggregation Configuration

### Filtering Event Logs

If you want to completely exclude event logs from your log aggregation system, you can configure filtering rules. Example pattern to exclude:

```
Pattern: '\[event\]'
```

This will filter out any log line containing `[event]`.

### Parsing Event Logs

If you want to parse structured event logs, the format follows this pattern:

```
[TIMESTAMP LEVEL MODULE] [event] type="TYPE" pid=PID ppid=PPID uid=UID gid=GID comm=COMMAND
```

Example:
```
[2025-12-23T14:01:46Z DEBUG cognitod::runtime::stream_listener] [event] type="Exit" pid=4112899 ppid=3957190 uid=0 gid=0 comm=logger
```

## Performance Impact

- **Disabled (default)**: Minimal overhead - events are logged at TRACE level and immediately filtered
- **Enabled**: Slightly higher overhead due to structured logging, but timestamps are essential for proper log aggregation

## Summary

| Configuration | Log Level | Use Case |
|--------------|-----------|----------|
| Default (log_events = false) | TRACE | Production - event logs hidden |
| log_events = true | DEBUG | Development - event logs visible |
| RUST_LOG=trace | TRACE | Deep debugging - all events shown |

**Recommendation**: Keep `log_events = false` (default) for production to reduce log volume. Enable only when debugging specific issues.
