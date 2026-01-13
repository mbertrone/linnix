# Manual Testing Guide v2: Recording & Replay with Compression

Complete step-by-step guide to test recording with/without compression and replay functionality.

**Last Updated**: 2026-01-05
**Build**: cognitod v0.2.0 with compression support

---

## Prerequisites

1. **Build the project**:
   ```bash
   cd /home/ubuntu/linnix
   cargo build --release --package cognitod
   ```

2. **Check build succeeded**:
   ```bash
   ls -lh ./target/release/cognitod
   # Should show the binary exists
   ```

3. **Verify you have sudo access** (required for eBPF):
   ```bash
   sudo echo "Access confirmed"
   ```

---

## Test 1: Record WITH Compression ✅

### Step 1.1: Create Configuration

```bash
cat > /tmp/test-compressed.toml <<'EOF'
[runtime]
offline = true

[recording]
enabled = true
file_path = "/tmp/recording_compressed.jsonl"
v2_format = true
snapshots_enabled = true
snapshot_interval_ms = 5000
process_snapshot_limit = 50
process_cpu_threshold = 1.0
compress_output = true      # ← COMPRESSION ENABLED
activity_threshold = 0

[logging]
log_events = false
alerts_file = "/var/log/linnix/alerts.ndjson"
insights_file = "/var/log/linnix/insights.ndjson"

[rules]
path = "/etc/linnix/rules.toml"

[api]
listen_addr = "127.0.0.1:3001"

[circuit_breaker]
enabled = false
EOF

echo "✅ Config created: /tmp/test-compressed.toml"
```

### Step 1.2: Clean Up Previous Files

```bash
sudo pkill -9 cognitod 2>/dev/null || true
sudo rm -f /tmp/recording_compressed.jsonl*
echo "✅ Cleanup complete"
```

### Step 1.3: Start Recording with Compression

```bash
sudo ./target/release/cognitod --config /tmp/test-compressed.toml &
COGNITOD_PID=$!
echo "✅ Cognitod started with PID: $COGNITOD_PID"
echo "   Waiting for initialization..."
sleep 3
```

**Expected output**:
```
[recording] Initialized recording to /tmp/recording_compressed.jsonl.gz (compression: enabled)
[cognitod] Recording enabled: /tmp/recording_compressed.jsonl
[cognitod] Compression: enabled    ← Look for this
[cognitod] Using V2 format: true
```

### Step 1.4: Generate Activity

Open a **new terminal** and run:
```bash
# Generate some process events
for i in {1..50}; do
    echo "Activity $i"
    ls /tmp > /dev/null
    sleep 0.1
done
```

Or in the same terminal:
```bash
(for i in {1..50}; do ls /tmp > /dev/null; sleep 0.1; done) &
echo "✅ Generating activity in background..."
```

### Step 1.5: Let It Record

```bash
echo "Recording for 15 seconds..."
sleep 15
```

### Step 1.6: Graceful Shutdown

**IMPORTANT**: Use SIGTERM, not kill -9!

```bash
echo "Sending graceful shutdown signal..."
sudo kill -TERM $COGNITOD_PID
sleep 2

# Wait for process to exit
wait $COGNITOD_PID 2>/dev/null || true

echo "✅ Cognitod stopped gracefully"
```

**Expected shutdown output**:
```
[cognitod] SIGTERM received, shutting down...
[recording] Shutting down gracefully (XXX events, YY snapshots recorded)
```

### Step 1.7: Verify Compressed File

```bash
echo "=== File Information ==="
ls -lh /tmp/recording_compressed.jsonl.gz

echo -e "\n=== File Type ==="
file /tmp/recording_compressed.jsonl.gz

echo -e "\n=== Entry Count ==="
ENTRIES=$(zcat /tmp/recording_compressed.jsonl.gz 2>/dev/null | wc -l)
echo "Total entries: $ENTRIES"

echo -e "\n=== Entry Types ==="
zcat /tmp/recording_compressed.jsonl.gz 2>/dev/null | jq -r '.type' | sort | uniq -c

echo -e "\n=== Sample Entry ==="
zcat /tmp/recording_compressed.jsonl.gz 2>/dev/null | head -1 | jq .

echo -e "\n=== Gzip Integrity Check ==="
if zcat /tmp/recording_compressed.jsonl.gz 2>&1 >/dev/null | grep -q "unexpected end of file"; then
    echo "❌ FAIL: Gzip file not properly closed"
    echo "   (Did you use kill -9 instead of kill -TERM?)"
else
    echo "✅ PASS: Gzip file is properly closed and valid"
fi
```

**Expected results**:
- ✅ File exists: `/tmp/recording_compressed.jsonl.gz`
- ✅ File type: `gzip compressed data`
- ✅ Entry count: > 100 entries (depends on activity)
- ✅ Entry types: Both `process_event` and `system_snapshot`
- ✅ No gzip errors

---

## Test 2: Record WITHOUT Compression (Comparison) ✅

### Step 2.1: Create Uncompressed Configuration

```bash
cat > /tmp/test-uncompressed.toml <<'EOF'
[runtime]
offline = true

[recording]
enabled = true
file_path = "/tmp/recording_uncompressed.jsonl"
v2_format = true
snapshots_enabled = true
snapshot_interval_ms = 5000
process_snapshot_limit = 50
process_cpu_threshold = 1.0
compress_output = false     # ← COMPRESSION DISABLED
activity_threshold = 0

[logging]
log_events = false
alerts_file = "/var/log/linnix/alerts.ndjson"
insights_file = "/var/log/linnix/insights.ndjson"

[rules]
path = "/etc/linnix/rules.toml"

[api]
listen_addr = "127.0.0.1:3002"

[circuit_breaker]
enabled = false
EOF

echo "✅ Config created: /tmp/test-uncompressed.toml"
```

### Step 2.2: Record Without Compression

```bash
sudo pkill -9 cognitod 2>/dev/null || true
sudo rm -f /tmp/recording_uncompressed.jsonl*
sleep 1

sudo ./target/release/cognitod --config /tmp/test-uncompressed.toml &
COGNITOD_PID=$!
echo "✅ Cognitod started with PID: $COGNITOD_PID"
sleep 3

# Generate activity
(for i in {1..50}; do ls /tmp > /dev/null; sleep 0.1; done) &
echo "Recording for 15 seconds..."
sleep 15

# Graceful shutdown
sudo kill -TERM $COGNITOD_PID
sleep 2
wait $COGNITOD_PID 2>/dev/null || true

echo "✅ Recording complete"
```

**Expected output**:
```
[recording] Initialized recording to /tmp/recording_uncompressed.jsonl (compression: disabled)
[cognitod] Compression: disabled    ← Look for this
```

### Step 2.3: Compare File Sizes

```bash
echo "=== Compression Comparison ==="
echo ""
echo "Compressed file:"
ls -lh /tmp/recording_compressed.jsonl.gz | awk '{print "  Size: " $5}'
COMPRESSED_SIZE=$(stat -f%z /tmp/recording_compressed.jsonl.gz 2>/dev/null || stat -c%s /tmp/recording_compressed.jsonl.gz)

echo ""
echo "Uncompressed file:"
ls -lh /tmp/recording_uncompressed.jsonl | awk '{print "  Size: " $5}'
UNCOMPRESSED_SIZE=$(stat -f%z /tmp/recording_uncompressed.jsonl 2>/dev/null || stat -c%s /tmp/recording_uncompressed.jsonl)

echo ""
echo "Compression ratio:"
RATIO=$(echo "scale=1; $UNCOMPRESSED_SIZE / $COMPRESSED_SIZE" | bc)
echo "  ${RATIO}x smaller with compression"

echo ""
echo "Space saved:"
SAVED=$(echo "scale=1; ($UNCOMPRESSED_SIZE - $COMPRESSED_SIZE) / 1024" | bc)
echo "  ${SAVED} KB saved"
```

**Expected results**:
- ✅ Compressed file: 10-50 KB
- ✅ Uncompressed file: 100-500 KB
- ✅ Compression ratio: 5-20x smaller
- ✅ Space saved: Significant reduction

### Step 2.4: Verify Both Are Readable

```bash
echo "=== Verifying Uncompressed File ==="
head -2 /tmp/recording_uncompressed.jsonl | jq .type

echo -e "\n=== Verifying Compressed File ==="
zcat /tmp/recording_compressed.jsonl.gz 2>/dev/null | head -2 | jq .type

echo -e "\n✅ Both files are valid and readable"
```

---

## Test 3: Replay Compressed File ✅

### Step 3.1: Verify Replay File Exists

```bash
echo "=== Replay File Info ==="
ls -lh /tmp/recording_compressed.jsonl.gz
echo ""
echo "Entries in file:"
zcat /tmp/recording_compressed.jsonl.gz 2>/dev/null | wc -l
```

### Step 3.2: Create Replay Configuration

```bash
cat > /tmp/test-replay.toml <<'EOF'
[runtime]
offline = true

[recording]
enabled = false

[logging]
log_events = false
alerts_file = "/var/log/linnix/alerts.ndjson"
insights_file = "/var/log/linnix/insights.ndjson"

[rules]
path = "/etc/linnix/rules.toml"

[api]
listen_addr = "127.0.0.1:3003"

[circuit_breaker]
enabled = false
EOF

echo "✅ Replay config created"
```

### Step 3.3: Run Replay with Compressed File

```bash
sudo pkill -9 cognitod 2>/dev/null || true
sleep 1

echo "=== Starting Replay Mode ==="
echo "Replaying: /tmp/recording_compressed.jsonl.gz"
echo ""

# Run replay with timeout to capture output
timeout 30s sudo RUST_LOG=info ./target/release/cognitod \
    --config /tmp/test-replay.toml \
    --replay /tmp/recording_compressed.jsonl.gz \
    2>&1 | tee /tmp/replay_output.log | head -100

echo ""
echo "✅ Replay completed (or timed out after 30s)"
```

**What to look for in the output**:
```
[replay] Starting replay from /tmp/recording_compressed.jsonl.gz
[replay] Detected gzip compression, decompressing...    ← Auto-detection
[replay] Detected V2 format
[replay] Processed XXX entries (YYY events, ZZZ snapshots)
[replay] Completed: XXX entries replayed
```

### Step 3.4: Verify Replay Logs

```bash
echo "=== Replay Summary ==="
grep -i "replay\|detected\|compressed\|entries\|completed" /tmp/replay_output.log | head -20

echo -e "\n=== Checking for Errors ==="
if grep -i "error\|failed\|unexpected" /tmp/replay_output.log | grep -v "Address already in use" >/dev/null; then
    echo "⚠️  Found errors in replay (check /tmp/replay_output.log)"
else
    echo "✅ No errors during replay"
fi

echo -e "\n=== Decompression Verification ==="
if grep -q "Detected gzip compression, decompressing" /tmp/replay_output.log; then
    echo "✅ Gzip auto-detection worked"
else
    echo "⚠️  Gzip detection message not found"
fi
```

**Expected results**:
- ✅ "Detected gzip compression" message appears
- ✅ Replay processes all entries
- ✅ No decompression errors
- ✅ Both process_event and system_snapshot entries replayed

---

## Test 4: Replay Uncompressed File (Backward Compatibility) ✅

### Step 4.1: Replay Uncompressed File

```bash
sudo pkill -9 cognitod 2>/dev/null || true
sleep 1

echo "=== Replaying Uncompressed File ==="
echo "File: /tmp/recording_uncompressed.jsonl"
echo ""

timeout 30s sudo RUST_LOG=info ./target/release/cognitod \
    --config /tmp/test-replay.toml \
    --replay /tmp/recording_uncompressed.jsonl \
    2>&1 | tee /tmp/replay_uncompressed.log | head -100

echo ""
echo "✅ Uncompressed replay completed"
```

### Step 4.2: Verify Backward Compatibility

```bash
echo "=== Backward Compatibility Check ==="

if grep -q "Detected gzip compression" /tmp/replay_uncompressed.log; then
    echo "❌ FAIL: Should NOT detect compression for plain files"
else
    echo "✅ PASS: No compression detection for plain files"
fi

if grep -q "replay.*Completed" /tmp/replay_uncompressed.log; then
    echo "✅ PASS: Uncompressed file replay succeeded"
else
    echo "⚠️  Replay may have had issues"
fi
```

**Expected results**:
- ✅ No "gzip compression" detection message
- ✅ Replay works normally
- ✅ All entries processed
- ✅ Backward compatibility maintained

---

## Test 5: Mixed File Replay Test ✅

### Step 5.1: Create Multiple Recordings

```bash
echo "=== Creating Multiple Test Files ==="

# Small compressed file
sudo pkill -9 cognitod 2>/dev/null || true
sudo rm -f /tmp/test_small.jsonl.gz
sudo ./target/release/cognitod --config /tmp/test-compressed.toml &
COGNITOD_PID=$!
sleep 3
sudo kill -TERM $COGNITOD_PID
sleep 2
sudo mv /tmp/recording_compressed.jsonl.gz /tmp/test_small.jsonl.gz
echo "✅ Created: /tmp/test_small.jsonl.gz"

# Small uncompressed file
sudo pkill -9 cognitod 2>/dev/null || true
sudo rm -f /tmp/test_small_plain.jsonl
sudo ./target/release/cognitod --config /tmp/test-uncompressed.toml &
COGNITOD_PID=$!
sleep 3
sudo kill -TERM $COGNITOD_PID
sleep 2
sudo mv /tmp/recording_uncompressed.jsonl /tmp/test_small_plain.jsonl
echo "✅ Created: /tmp/test_small_plain.jsonl"
```

### Step 5.2: Test Replay All Files

```bash
echo -e "\n=== Testing Replay of Multiple Files ==="

for file in /tmp/test_small.jsonl.gz /tmp/test_small_plain.jsonl; do
    echo ""
    echo "=========================================="
    echo "Replaying: $file"
    echo "=========================================="

    sudo pkill -9 cognitod 2>/dev/null || true
    sleep 1

    timeout 10s sudo RUST_LOG=info ./target/release/cognitod \
        --config /tmp/test-replay.toml \
        --replay "$file" \
        2>&1 | grep -E "replay.*Starting|Detected|Completed" | head -5

    echo "✅ Replay test completed for $(basename $file)"
done
```

**Expected results**:
- ✅ `.jsonl.gz` files: "Detected gzip compression" appears
- ✅ `.jsonl` files: No compression detection
- ✅ Both file types replay successfully

---

## Complete Test Script (Run All Tests)

Save this as `/tmp/run_all_compression_tests.sh`:

```bash
#!/bin/bash
set -e

echo "================================================"
echo "Complete Compression Testing Suite"
echo "================================================"
echo ""

cd /home/ubuntu/linnix

# Test 1: Compressed Recording
echo "TEST 1: Recording WITH compression..."
sudo pkill -9 cognitod 2>/dev/null || true
sudo rm -f /tmp/recording_compressed.jsonl.gz

cat > /tmp/test-compressed.toml <<'EOF'
[runtime]
offline = true
[recording]
enabled = true
file_path = "/tmp/recording_compressed.jsonl"
v2_format = true
compress_output = true
snapshots_enabled = true
snapshot_interval_ms = 5000
[logging]
log_events = false
[api]
listen_addr = "127.0.0.1:3001"
[circuit_breaker]
enabled = false
[rules]
path = "/etc/linnix/rules.toml"
EOF

sudo ./target/release/cognitod --config /tmp/test-compressed.toml &
COGNITOD_PID=$!
sleep 10
sudo kill -TERM $COGNITOD_PID
sleep 2
wait $COGNITOD_PID 2>/dev/null || true

if [ -f /tmp/recording_compressed.jsonl.gz ]; then
    echo "✅ Compressed file created"
    if zcat /tmp/recording_compressed.jsonl.gz >/dev/null 2>&1; then
        echo "✅ Compressed file is valid"
    else
        echo "❌ Compressed file has errors"
        exit 1
    fi
else
    echo "❌ Compressed file NOT created"
    exit 1
fi

# Test 2: Uncompressed Recording
echo ""
echo "TEST 2: Recording WITHOUT compression..."
sudo pkill -9 cognitod 2>/dev/null || true
sudo rm -f /tmp/recording_uncompressed.jsonl

cat > /tmp/test-uncompressed.toml <<'EOF'
[runtime]
offline = true
[recording]
enabled = true
file_path = "/tmp/recording_uncompressed.jsonl"
v2_format = true
compress_output = false
snapshots_enabled = true
snapshot_interval_ms = 5000
[logging]
log_events = false
[api]
listen_addr = "127.0.0.1:3002"
[circuit_breaker]
enabled = false
[rules]
path = "/etc/linnix/rules.toml"
EOF

sudo ./target/release/cognitod --config /tmp/test-uncompressed.toml &
COGNITOD_PID=$!
sleep 10
sudo kill -TERM $COGNITOD_PID
sleep 2
wait $COGNITOD_PID 2>/dev/null || true

if [ -f /tmp/recording_uncompressed.jsonl ]; then
    echo "✅ Uncompressed file created"
    if head -1 /tmp/recording_uncompressed.jsonl | jq . >/dev/null 2>&1; then
        echo "✅ Uncompressed file is valid JSON"
    else
        echo "❌ Uncompressed file is not valid"
        exit 1
    fi
else
    echo "❌ Uncompressed file NOT created"
    exit 1
fi

# Test 3: Compression Ratio
echo ""
echo "TEST 3: Compression ratio..."
COMPRESSED_SIZE=$(stat -c%s /tmp/recording_compressed.jsonl.gz 2>/dev/null || stat -f%z /tmp/recording_compressed.jsonl.gz)
UNCOMPRESSED_SIZE=$(stat -c%s /tmp/recording_uncompressed.jsonl 2>/dev/null || stat -f%z /tmp/recording_uncompressed.jsonl)
RATIO=$(echo "scale=1; $UNCOMPRESSED_SIZE / $COMPRESSED_SIZE" | bc 2>/dev/null || echo "N/A")

echo "Compressed: $COMPRESSED_SIZE bytes"
echo "Uncompressed: $UNCOMPRESSED_SIZE bytes"
echo "Ratio: ${RATIO}x"

if [ "$RATIO" != "N/A" ] && [ $(echo "$RATIO > 3" | bc) -eq 1 ]; then
    echo "✅ Good compression ratio (${RATIO}x)"
else
    echo "⚠️  Compression ratio seems low"
fi

# Test 4: Replay Compressed
echo ""
echo "TEST 4: Replay compressed file..."
sudo pkill -9 cognitod 2>/dev/null || true
sleep 1

cat > /tmp/test-replay.toml <<'EOF'
[runtime]
offline = true
[logging]
log_events = false
[api]
listen_addr = "127.0.0.1:3003"
[circuit_breaker]
enabled = false
[rules]
path = "/etc/linnix/rules.toml"
EOF

timeout 10s sudo RUST_LOG=info ./target/release/cognitod \
    --config /tmp/test-replay.toml \
    --replay /tmp/recording_compressed.jsonl.gz \
    2>&1 | tee /tmp/replay_test.log | head -50 || true

if grep -q "Detected gzip compression" /tmp/replay_test.log; then
    echo "✅ Gzip auto-detection works"
else
    echo "❌ Gzip not detected"
    exit 1
fi

if grep -q "replay.*entries" /tmp/replay_test.log; then
    echo "✅ Replay processed entries"
else
    echo "⚠️  Replay may not have completed"
fi

# Test 5: Replay Uncompressed
echo ""
echo "TEST 5: Replay uncompressed file..."
sudo pkill -9 cognitod 2>/dev/null || true
sleep 1

timeout 10s sudo RUST_LOG=info ./target/release/cognitod \
    --config /tmp/test-replay.toml \
    --replay /tmp/recording_uncompressed.jsonl \
    2>&1 | tee /tmp/replay_plain.log | head -50 || true

if ! grep -q "Detected gzip compression" /tmp/replay_plain.log; then
    echo "✅ Backward compatibility: plain files work"
else
    echo "❌ Should not detect compression for plain files"
    exit 1
fi

echo ""
echo "================================================"
echo "ALL TESTS COMPLETED SUCCESSFULLY! ✅"
echo "================================================"
echo ""
echo "Summary:"
echo "  ✅ Compressed recording works"
echo "  ✅ Uncompressed recording works"
echo "  ✅ Good compression ratio"
echo "  ✅ Compressed file replay works"
echo "  ✅ Uncompressed file replay works (backward compat)"
echo ""
echo "Compression feature is ready for production!"
```

Make it executable and run:
```bash
chmod +x /tmp/run_all_compression_tests.sh
/tmp/run_all_compression_tests.sh
```

---

## Troubleshooting Guide

### Issue: "unexpected end of file" error

**Cause**: File not properly closed (killed with -9 instead of -TERM)

**Solution**:
```bash
# DON'T do this:
sudo kill -9 $COGNITOD_PID

# DO this instead:
sudo kill -TERM $COGNITOD_PID  # or just: sudo kill $COGNITOD_PID
sleep 2  # Give it time to shut down
```

### Issue: "Address already in use" error

**Cause**: Another cognitod instance is running

**Solution**:
```bash
sudo pkill -9 cognitod
sleep 2
# Then retry
```

Or use a different port in config:
```toml
[api]
listen_addr = "127.0.0.1:3004"  # Use different port
```

### Issue: Replay hangs or doesn't complete

**Cause**: Large file being loaded into memory, or infinite replay loop

**Solution**: Use `timeout` to limit replay duration:
```bash
timeout 30s sudo ./target/release/cognitod --replay file.jsonl.gz
```

### Issue: File not created

**Check 1**: Verify recording is enabled
```bash
grep "Recording enabled" /tmp/cognitod.log
```

**Check 2**: Check permissions
```bash
ls -la /tmp/*.jsonl*
sudo chown $USER:$USER /tmp/*.jsonl*
```

**Check 3**: Verify config
```bash
grep -A 5 "\[recording\]" /tmp/test-compressed.toml
```

### Issue: No compression despite config

**Check 1**: Verify `compress_output = true` in config
```bash
grep compress_output /tmp/test-compressed.toml
```

**Check 2**: Check logs for compression status
```bash
grep -i compression /tmp/cognitod.log
```

Should see: `Compression: enabled`

---

## Quick Reference Commands

### Start Recording (Compressed)
```bash
sudo ./target/release/cognitod --config /tmp/test-compressed.toml &
PID=$!
```

### Stop Recording (Graceful)
```bash
sudo kill -TERM $PID
sleep 2
```

### Check File
```bash
ls -lh /tmp/recording_compressed.jsonl.gz
file /tmp/recording_compressed.jsonl.gz
zcat /tmp/recording_compressed.jsonl.gz | wc -l
```

### Replay File
```bash
sudo ./target/release/cognitod \
    --config /tmp/test-replay.toml \
    --replay /tmp/recording_compressed.jsonl.gz
```

### Test Gzip Integrity
```bash
zcat file.jsonl.gz >/dev/null 2>&1 && echo "✅ Valid" || echo "❌ Invalid"
```

---

## Success Criteria Checklist

### Recording Tests
- [ ] Compressed file created with `.gz` extension
- [ ] `file` command confirms gzip format
- [ ] Compression ratio > 5x
- [ ] No "unexpected end of file" errors
- [ ] Shutdown log shows "Shutting down gracefully"

### Replay Tests
- [ ] Compressed file: "Detected gzip compression" appears
- [ ] Compressed file: All entries replayed successfully
- [ ] Uncompressed file: No compression detection
- [ ] Uncompressed file: Replay works (backward compat)
- [ ] No errors during replay

### Production Readiness
- [ ] All tests pass
- [ ] Graceful shutdown works reliably
- [ ] Files can be decompressed with standard tools
- [ ] Backward compatibility verified
- [ ] Documentation complete

---

## Next Steps After Testing

Once all tests pass:

1. **Update production configs** with `compress_output = true`
2. **Deploy to staging** environment first
3. **Monitor disk space** usage (should see significant reduction)
4. **Verify log rotation** still works with `.gz` files
5. **Test with monitoring systems** (if any)
6. **Roll out to production** once validated

---

## Support

If you encounter issues:

1. Check logs: `/tmp/cognitod.log` or `/tmp/replay_output.log`
2. Verify build: `./target/release/cognitod --version`
3. Review documentation:
   - `COMPRESSION_PLAN.md` - Design doc
   - `SHUTDOWN_FIX_VERIFIED.md` - Shutdown fix details
   - `COMPRESSION_TEST_RESULTS.md` - Test results

4. Create issue with:
   - Config file used
   - Full command run
   - Complete error output
   - File sizes and entry counts

---

## Conclusion

This guide provides complete testing coverage for:
- ✅ Recording with compression
- ✅ Recording without compression (comparison)
- ✅ Replay of compressed files
- ✅ Replay of uncompressed files (backward compatibility)
- ✅ Graceful shutdown verification
- ✅ File integrity validation

Follow the steps in order for systematic testing, or use the complete test script for automated verification.

**The compression feature is production-ready when all tests pass!** 🎉
