# 0.9.1 presentation and multi-file performance

[中文](presentation-performance.zh-CN.md)

This change targets tab-switch stalls, display styles and frequent small controls. Measurements use isolated GUI processes on Apple Silicon, macOS 14.2.1, Swift 5.10. Each case starts fresh with matching generated fixtures; filesystem caches are not guaranteed cold. A 20 ms timer observes the main event loop. RSS peaks are sampled, not continuous maxima.

## Cause and structural changes

An eight-file workflow opens 256 KiB UTF-8 documents, switches tabs and closes. Source review/workloads show that every new pane formerly applied font/paragraph attributes to the complete `NSTextStorage` on the main thread; switches destroyed/recreated panes. Shared storage made repeated full styling and view/layout lifetimes costly. Reads/decoding and initial layout are still synchronous.

`EditorDocument` now owns the applied font, paragraph and base foreground style. Matching styles skip full storage updates. Views still own typing attributes, backgrounds, scrolling and viewport highlighting. Reselecting the current tab retains its pane, selections and scroll. Font/tab-width/theme changes apply the required new styles.

| Matched workload phase | Before elapsed / CPU | Final source elapsed / CPU |
| --- | ---: | ---: |
| Round 1: open eight tabs | 647.94 / 578.50 ms | 555.70 / 467.58 ms |
| Round 1: switch tabs | 424.58 / 384.19 ms | 206.26 / 169.67 ms |
| Round 1: close tabs | 706.23 / 631.13 ms | 131.78 / 100.71 ms |
| Round 2: open eight tabs | 631.62 / 567.59 ms | 485.45 / 446.39 ms |
| Round 2: switch tabs | 433.57 / 380.98 ms | 203.83 / 153.35 ms |
| Round 2: close tabs | 678.31 / 623.51 ms | 150.53 / 107.35 ms |

These are matched machine/size/workflow runs, not statistical multi-machine evidence. Maximum multi-file heartbeat decreased 1,137→603 ms, about 47%. Sampled RSS peaks were 121.25/119.28 MiB, a small difference not claimed as memory savings. Switching still has roughly 0.2-second batch phases and loading is synchronous; this does not promise stall-free opening sequences.

For 1 MiB, native open was 154.58/135.50 ms elapsed/CPU before and 142.86/128.44 ms after. EOF input was 18.87/16.63 versus 18.27/17.06 ms; undo 13.64/12.70 versus 15.17/13.25 ms. These small changes do not establish faster editing generally. Settled-layout latency, actual wheel/inertia/frame timing, cold disk and larger projects were not fully remeasured.

Raw evidence is `.build/performance/style-090-before/` and `.build/performance/polish-091-release-final/`. Manifests retain workload/source hashes. Before is `84ebe43` plus the verified import preservation fix; final measurements ran serially after acceptance, without concurrent builds/probes. The test app uses the same 0.9.1 production source; measurement dispatch is excluded from release. Workload SHA-256: `7ad73134d5e0ff1e464cac022f1e02fd2268f15114b690045df0e8f3c0c744d1`. Final production aggregate: `2e25555773a68a3e3e58cd27b0212da4018084f64a47204a762714922c2503f4`. All document/storage/view/layout weak references were nil after both rounds; this does not prove all prolonged paths leak-free.

## Fonts, themes and icons

Editors use selected installed monospace fonts, with no bundled font files. Family/size are display preferences and do not alter source or encoding. Choices include system monospace, Menlo, Monaco and Courier New, with system fallback. Dark/light changes refresh base foreground and controls.

Tab close, notices, find navigation and output close use SF Symbols with stable hover descriptions and VoiceOver names. Sidebar icons also come from the system. The Dock icon is original vector drawing with simplified small grids/orbits and a recognizable terminal mark.

Draft UI checks verify unchanged text and persisted font choices; tab controls have accessible names. Light preview screenshot: `.build/test-results/polish-091-release/product-ui-artifacts/markdown-side-by-side-light.png`. Dark editor/Markdown paths have separate regressions. Real displays, scaling, VoiceOver and multilingual systems still need manual acceptance.

## Reproduction

```sh
python3 tests/run_performance.py style-090 --no-build --cases file:1048576 multiple:262144 --cycles 2
python3 tests/run_tests.py polish-091-release --ui --arch universal
```

## Release package and runtime

Universal contains arm64/x86_64. The Intel version entry passed under Rosetta; physical Intel GUI remains unverified.

| Artifact | Bytes |
| --- | ---: |
| ZIP download | 1,994,679 |
| Installed regular-file bytes | 4,359,637 |
| Allocated regular-file blocks | 4,390,912 |

Release SHA-256: `bb61028b89846c68fda85cf02ae5f740f488336241745eed99f1309800907c7c`, matching ZIP contents. Regular files total about 4.16 MiB, ZIP 1.90 MiB; directories/xattrs/APFS shared extents are excluded.

Copied bundles use the identical release Mach-O and isolated identities, wait at least five seconds and verify PID-owned windows. No editing, scrolling or preview; these rows cannot be mixed with test-app workloads above.

| Case | RSS | Physical footprint | Accumulated CPU |
| --- | ---: | ---: | ---: |
| Empty window | 45.70 MiB | 25.90 MiB | 0:00.19 |
| 64 KiB text file | 57.48 MiB | 58.90 MiB | 0:00.30 |

RSS and footprint use different accounting; shared/compressed pages and timing can change their relative sizes. Separate launches cannot establish per-byte increments or reduced memory versus older versions. No WebKit preview runs; other apps/WindowServer are excluded. Evidence: `.build/diagnostics/polish-091-release-package/` and `.build/diagnostics/polish-091-release-memory/`.

## Validation scope

Final `polish-091-release` passed **604 checks with 13 explicit skips**, including 26 draft/font/icon UI, 15 real restart and 207 integrated native UI checks. Elapsed totals about 222 seconds; source/release hashes are retained. Superseded intermediate gates were stopped and excluded. Agent tokens and complete process-family CPU/RSS attribution were not measured.

Early style-cache heartbeat was 557 ms; tab reuse samples were 603 ms, repeated about 610 ms and final 603 ms. Synchronous work/scheduling variation remains. Intermediate probes overlapping compilation are excluded; main tables and release rows use serial probes after acceptance. Filesystem caches/background load were not fully controlled.

Complete workloads include fixtures, waits, layout, edit/undo, scroll and close, rather than I/O alone. CPU is accumulated GUI process time; elapsed is complete launcher-observed time.

| Case | Complete elapsed before / after | GUI CPU before / after | Sampled RSS before / after |
| --- | ---: | ---: | ---: |
| 1 MiB native edit/scroll/reopen | 5.81 / 5.54 s | 1.87 / 1.87 s | 103.52 / 106.69 MiB |
| Two rounds: eight tabs open/switch/close | 6.25 / 4.52 s | 3.51 / 1.80 s | 121.25 / 119.28 MiB |
