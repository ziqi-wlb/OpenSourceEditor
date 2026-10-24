# 0.9.0 resource and performance validation

[中文](release-090-performance.zh-CN.md)

Measured production source is commit `84ebe43`, the initial draft implementation. Later style-cache, native icon and imported-session changes are measured in [presentation performance](presentation-performance.md); these digests/memory figures do not describe later builds.

Environment: Apple Silicon, macOS 14.2.1, Swift 5.10, real local processes. No physical Intel or Windows native performance run. This report measures drafts, packaging and small file workloads, not prolonged leak freedom or complete performance acceptance.

## Draft writes

`RecoveryPerformanceTests` creates fixed-size documents in separate processes and times actual `EditorSession.Document` capture, background JSON encoding, atomic writing and main-queue completion. JSON verification follows timing. No GUI/subprocess is created; filesystem caches are not flushed. First means first write in a new process, repeated means second write in the same process.

| UTF-16 content | First elapsed | Repeated elapsed | First CPU | Repeated CPU | Process RSS high water after repeat |
| --- | ---: | ---: | ---: | ---: | ---: |
| 64 Ki units | 7.20 ms | 2.72 ms | 4.49 ms | 2.51 ms | 11.25 MiB |
| 1 Mi units | 56.39 ms | 34.21 ms | 36.42 ms | 33.69 ms | 22.94 MiB |
| 4 Mi units, limit | 139.71 ms | 139.88 ms | 133.07 ms | 134.06 ms | 47.69 MiB |

RSS is cumulative high water including fixtures, documents, encoding and verification, not GUI total memory or a single allocation. JSON bytes differ from UTF-16 units; primarily ASCII plus Chinese/emoji does not represent every Unicode or worst-case escape expansion.

The queue permits one active write and one latest pending state per window. Periodic requests coalesce; final close replaces a periodic request that has not started; discard follows active writing. This prevents omitted final input and stale-write resurrection. Restart tests verify final text. No equivalent old-version A/B was measured, so no percentage speedup is claimed.

## Release package

Universal contains actually compiled x86_64 and arm64 slices.

| Artifact | Bytes | Size |
| --- | ---: | ---: |
| ZIP download | 1,988,488 | 1.90 MiB |
| Regular-file logical bytes | 4,356,789 | 4.15 MiB |
| Allocated file blocks | 4,386,816 | 4.18 MiB |
| Universal Mach-O | 3,701,472 | 3.53 MiB |
| Original multi-size icon | 632,266 | 617.45 KiB |

ZIP/release digests match: `6d718c6786ceb3a929f267442494a8b212de184e9d9300a16d17fa50f1597996`. Regular-file totals exclude directories, xattrs and APFS shared extents; historical apps/tests/logs/fixtures are development data, not installation size.

Small icons omit fine grids/orbits and thicken the center for 16/32-pixel recognition; large sizes retain the technical design. System fonts are not bundled. Font menus change presentation rather than text/encoding/indentation; persistence is tested.

## Release runtime memory

The same release Mach-O is copied to isolated identities with document associations removed. PID-owned windows/filenames are checked. Cases start separately and wait 5 seconds for RSS/vmmap footprint. No edits, preview or scrolling; user applications remain untouched.

| Case | RSS | Physical footprint | Accumulated process CPU |
| --- | ---: | ---: | ---: |
| Empty window | 40.83 MiB | 25.50 MiB | 0.19 s |
| 64 KiB file | 75.42 MiB | 60.30 MiB | 0.34 s |

An earlier independent 1 MiB probe recorded RSS 80.52 MiB, footprint 65.40 MiB, CPU 0.54 s. It is a separate launch, not a matched size A/B. RSS and footprint differ. System caches, WindowServer and filesystem caches are not attributed to the application. Copied identities do not load users' actual workspaces.

## Opening, editing, scrolling and lifetimes

`run_performance.py` uses production edit paths in isolated test bundles. The 1 MiB case opens, visits EOF, edits, undoes, programmatically scrolls, closes and reopens. The multiple-file case opens/switches/closes two rounds of eight 256 KiB files.

| Case | Sampled peak RSS | Maximum main-queue heartbeat | Result |
| --- | ---: | ---: | --- |
| 1 MiB edit/undo/scroll/reopen | 109.30 MiB | 205.55 ms | Semantics and cleanup passed |
| Two rounds: 16 files open/switch/close | 121.27 MiB | 1,141.17 ms | Closed document/storage/view/layout weak references nil |

The 1 MiB native open returned in 147.08 ms; the predefined settled-layout check took about 575.41 ms. EOF edit took 20.09 ms, undo 14.43 ms. Timing includes production work and warm filesystem state. Multi-file batches remain synchronous and cause a roughly 1.14-second heartbeat stall, consistent with earlier reports. Asynchronous reads and staged UI commits remain future work requiring matched workloads.

Nil weak references establish destruction of probed objects, not leak freedom for all extension/preview/prolonged paths. Programmatic scrolling does not measure real wheel/inertia, GPU frames or input latency. WebKit family peaks were not remeasured.

## Reproduction and evidence

```sh
# Run from editor/:
bash tests/run_all.sh draft-final --ui --arch universal
'.build/Source Editor Tests.app/Contents/MacOS/source-editor' --recovery-measure=1048576
python3 tests/measure_release_memory.py memory-run --duration 5 --cases empty file --bytes 65536
python3 tests/run_performance.py performance-run --no-build --cases file:1048576 multiple:262144 --cycles 2
python3 scripts/inspect_package.py '.build/Source Editor.app' .build/diagnostics/package-run --zip .build/SourceEditor-0.9.0-macos-universal.zip
```

Evidence: `.build/test-results/draft-final`, `.build/diagnostics/draft-090-write`, `.build/diagnostics/draft-090-package-zip`, `.build/diagnostics/draft-090-memory-final`, `.build/performance/draft-090-performance`. Historical acceptance: **598 passed, 13 explicitly skipped**, including 23 draft/font UI and 15 real quit/restart checks. Check elapsed time totals about 221 seconds. Agent tokens and whole-task CPU savings were not measured.
