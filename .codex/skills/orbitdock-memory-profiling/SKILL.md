---
name: orbitdock-memory-profiling
description: Profile OrbitDock memory and runtime behavior using macOS CLI tools. Use when investigating high memory usage, memory growth over time, Core Animation or mmap/vm_allocate-heavy stacks, leak suspicion, or regressions that need reproducible vmmap/sample/xctrace evidence.
---

# OrbitDock Memory Profiling

## Overview
Capture reproducible OrbitDock memory artifacts from the command line, then map hotspots back to likely UI or rendering causes.

## Workflow
1. Identify the target process.
2. Capture baseline snapshots.
3. Reproduce the issue.
4. Capture post-repro snapshots.
5. Compare outputs and form hypotheses.

Prefer using `scripts/capture_memory_profile.sh` for consistency.

## Run The Script
Run a full capture for the latest OrbitDock process:

```bash
scripts/capture_memory_profile.sh
```

Run a targeted capture:

```bash
scripts/capture_memory_profile.sh \
  --pid 9718 \
  --sample-seconds 5 \
  --trace-seconds 10 \
  --out-dir /tmp/orbitdock-profile
```

## Manual Commands
Use these directly when you need finer control:

```bash
pgrep -lf OrbitDock
ps -o pid,ppid,rss,vsz,%mem,etime,command -p <PID>
vmmap -summary <PID>
sample <PID> 5 1
xctrace record --template 'Allocations' --attach <PID> --time-limit 10s --output /tmp/orbitdock-alloc.trace
xctrace export --input /tmp/orbitdock-alloc.trace --toc
```

## Permission Handling
If `vmmap`, `sample`, `leaks`, or `xctrace` fails with permission errors, request elevated execution and rerun the same command.

## Interpretation Guide
Read `references/interpretation.md` for quick heuristics on:
- CoreAnimation and image-backed growth
- MALLOC_SMALL and fragmentation signals
- Peak vs current footprint interpretation
- Stack patterns that implicate rendering, focus rings, or image decode paths

## Output Expectations
The capture script writes:
- `ps.txt`
- `vmmap-summary.txt`
- `sample.txt`
- `allocations.trace` and `xctrace-toc.xml` (if tracing enabled)
- `capture-summary.txt`

Use these artifacts to compare before/after repro windows and support fixes with evidence.
