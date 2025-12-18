# Known Issues and Limitations

This document tracks identified issues, limitations, and areas for improvement in Linnix.

## Critical Issues

### 1. RSS Memory Tracking Always Returns 0% (High Priority)

**Status**: 🔴 Active Issue  
**Impact**: Memory leak detection rules never trigger  
**Severity**: High - Core functionality broken  

**Root Cause Analysis**:
RSS (Resident Set Size) tracking consistently returns 0.00% for all processes due to a combination of timing and configuration issues:

1. **eBPF Measurement Timing**:
   - RSS is only measured on process events (`exec`, `fork`, `exit`)
   - At `exec` time, processes haven't allocated memory yet → RSS = 0
   - No continuous monitoring of running processes

2. **Hardcoded Activity Threshold**:
   - Background RSS updates only run when `events_per_sec >= 20`
   - Threshold is hardcoded in `cognitod/src/main.rs:914`
   - Most systems operate below this threshold → updates never occur
   - No configuration option to adjust threshold

3. **Process Lifecycle Mismatch**:
   - Short-lived processes: Measured at startup (RSS=0) then exit
   - Long-running processes: Never get periodic updates due to activity gate

**Technical Details**:
```rust
// cognitod/src/main.rs:914
let is_active = eps >= 20; // Hardcoded default (YAGNI cleanup)
if is_active {
    ctx_clone.update_process_stats(); // This rarely runs!
}
```

**Evidence**:
- All debug logs show: `mem_pct=0.00% approx_mb=0`
- eBPF successfully reads kernel RSS structures but values are legitimately 0
- Manual verification: `update_process_stats()` uses sysinfo which should work
- Activity threshold prevents periodic RSS updates on typical workloads

**Affected Components**:
- Memory leak detection rules (`subtree_rss_mb` detector)
- Process memory monitoring
- Circuit breaker memory thresholds
- Dashboard memory statistics

**Workarounds**:
1. Generate artificial process activity (>20 events/sec)
2. Run memory-intensive workloads during testing
3. Temporarily modify code to remove activity gate

**Proposed Fixes**:
1. **Immediate**: Make activity threshold configurable
2. **Short-term**: Lower default threshold or remove gate for RSS updates
3. **Long-term**: Implement dedicated RSS sampling independent of process events

**Files to Modify**:
- `cognitod/src/main.rs` - Remove or configure activity threshold
- `cognitod/src/config.rs` - Add activity threshold configuration
- `cognitod/src/context.rs` - Ensure RSS updates work correctly

---

## Architecture Limitations

### 2. ARM64 Support Missing

**Status**: 🟡 Planned  
**Timeline**: v0.2.0 release  
**Impact**: Cannot deploy on ARM64 nodes  

ARM64 architecture is not currently supported and will fail to build with bpf-linker LLVM errors.

---

### 3. DaemonSet Deployment Issues

**Status**: 🔴 Under Investigation  
**Impact**: Limited to single-pod deployments  
**Workaround**: Deploy as individual pods on specific nodes  

Unable to deploy as Kubernetes DaemonSet. Root cause under investigation.

---

## Configuration Issues

### 4. No RBAC Configuration in Staging Pod

**Status**: 🟡 By Design  
**Impact**: K8s API access warnings  

ServiceAccount and ClusterRole are commented out in staging pod YAML, causing:
```
WARN cognitod::k8s failed to refresh pods: API error: 403 Forbidden
```

**Workaround**: Acceptable for staging - K8s integration not required for core eBPF functionality.

---

### 5. Missing API Authentication

**Status**: 🟡 Security Warning  
**Impact**: Unprotected API endpoints  

```
WARN API listening on 0.0.0.0:3000 with NO AUTHENTICATION
```

**Fix**: Set `LINNIX_API_TOKEN` environment variable.

---

## Testing and Development

### 6. Manual Testing Required for Memory Rules

**Status**: 🟡 Process Issue  
**Impact**: Cannot easily validate memory leak detection  

Due to RSS tracking issue (#1), memory leak rules require manual testing with:
- Long-running memory-consuming processes
- Artificial activity generation
- Modified thresholds

---

## Documentation

### 7. Activity Threshold Not Documented

**Status**: 🟡 Documentation Gap  
**Impact**: Unclear system behavior  

The hardcoded 20 events/sec activity threshold that gates RSS updates is:
- Not mentioned in configuration documentation
- Not exposed as a tunable parameter
- Critical for understanding system behavior

---

## Fixed Issues

*None yet - this is the initial version of this document.*

---

## Contributing

When adding issues to this document:

1. Use clear, descriptive titles
2. Include status emoji: 🔴 Critical, 🟡 Medium, 🟢 Low, ✅ Fixed
3. Provide technical details and evidence
4. Suggest workarounds and fixes
5. Update status as issues are resolved

Last Updated: Dec 15, 2024