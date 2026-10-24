# Document workspace performance and resources

[中文](document-workspace-performance.zh-CN.md)

This report covers the macOS 0.7.0 Markdown/search/recovery work. Earlier text-engine measurements remain in [performance optimization](performance-optimization.md) and the historical [package report](package-and-memory.md). New preview capabilities have no equivalent pre-0.7.0 baseline.

## Work ownership and avoided costs

Ordinary editing creates no WKWebView. Requesting Preview creates one view with a serial queue; switching back to Edit or closing the document/window cancels requests and detaches it. Worker operations retain text snapshots rather than documents, pane owners or undo managers. Generation/revision checks prevent obsolete output from replacing current text.

Initial preview requests start immediately. Repeated edits of the same document retain a 250 ms debounce so typing does not enqueue a render per keystroke. This removes a fixed wait for explicit preview requests; it does not reduce Foundation parsing, DOM construction or TextKit/WebKit rendering work. Foundation's parser itself cannot be interrupted mid-call.

Project Quick Open and search share a traversal owner, with cancellation, canonical file identities and examined-coverage summaries. File reads are bounded at FileHandle, not only by a preceding size check. A growing file cannot cause an unbounded allocation after metadata inspection. Each search decodes one file at a time inside an autorelease pool and retains only bounded hit records.

Recovery captures only changed unsaved documents. A workspace permits one write at a time and serializes final removal after pending writes. JSON serialization and disk writing run at utility priority. Saving removes stale snapshot content; clean files are excluded. Line commands still use the existing whole-buffer undo transaction and are not a new large-file editing engine.

## Representation bounds

| Work | Bound |
| --- | --- |
| Markdown input | 2 million UTF-16 units |
| Markdown blocks / styled runs | 100,000 each |
| Local images | 4 MiB individual, 12 MiB unique input total, 40 million pixels |
| Embedded image output | 16 MiB, including repeated references to cached images |
| Rendered HTML | 32 MiB, checked before combining large block output |
| Project scan | 50,000 files |
| Project search | 2 MiB/file, 128 MiB total reads, 2,000 matches |
| Automatic recovery | 128 modified documents, 4 million UTF-16 units |
| Serialized session | 32 MiB |

The image cache does not exempt repeated references from the output budget. Base64 expansion is charged per embedded occurrence. Capacity, cancellation and unreadable inputs are reported rather than presented as complete results; editable source remains available when preview is rejected.

## Divider and clipping correction

The prior splitter assigned pane frames manually while inheriting NSSplitView's divider drawing and drag state. A light-theme preview screenshot exposed an extra vertical line. The split container now owns one geometry for layout, divider drawing, cursor regions and mouse hit testing. It removes the conflicting native divider representation. A real NSWindow mouse-event test drags the visible divider and verifies the source pane changes width.

The macOS 14 AppKit SDK also documents a changed NSView default: `clipsToBounds` is false on macOS 14 and later, versus true previously. Split, editor and scroll containers now explicitly clip their bounded content; divider painting clips to its own bounds. Native menus and sheets remain separate windows. Light/dark screenshots are inspected alongside lifecycle and drag checks.

## Measurement method and limits

The native performance workload opens representative Markdown with Chinese/emoji text, headings, task lists, tables and fenced code. Each fresh process performs six cycles of opening, preview, ten programmatic scrolls, an edit/refresh and closure. Weak probes verify preview/document destruction; native task information records main-process footprint and CPU time.

WebKit's XPC helpers have launchd parents, so parent-PID traversal misses them. The diagnostic launches a copied test bundle through LaunchServices with a unique identity and attributes system WebKit processes by the OS responsibility PID. The optional responsibility symbol is used only by the Python diagnostic. It is never linked into the editor. If attribution is unavailable, the report marks incomplete scope rather than counting other applications' helpers.

Main-process and aggregate family RSS are sampled separately, about every 0.1 seconds. Family RSS includes shared mappings more than once and is not unique physical memory consumption. Sampled maxima are not continuous peaks. Native footprint/CPU rows cover the main process; WebKit CPU and unique physical family memory remain unmeasured.

First preview includes WebKit startup and any pending file-open layout; warm values are medians of cycles 2–6. File-system/font/system caches are not flushed. Preview timing ends when WebKit reports the page loaded and excludes WindowServer compositing. Edit timing ends when the new parsed page is available and includes typing debounce. Programmatic scrolling does not establish wheel/inertia or GPU frame performance. Tests use the same production sources with test-only fixture/measurement code; release idle workloads use an unchanged release executable.

## Preview timings and measured effect

Measured on 2026-10-24 on an Apple M1 Pro with 16 GiB RAM, macOS 14.2.1 and Apple Swift 5.10. All rows use the same six-cycle workload and fixture hashes. Baseline v2 includes the 250 ms wait for explicit preview requests; v3/v4 remove that wait; final v5 also includes the divider and clipping correction. There is no pre-0.7.0 preview implementation to compare.

| Run | Actual input bytes | First page ms | Warm page median ms | Edit median ms | Completed task s | Main-process CPU s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Baseline v2 | 65,474 | 615.5 | 469.9 | 398.0 | 16.82 | 3.16 |
| Intermediate v3 | 65,474 | 1,255.9 | 441.4 | 406.6 | 17.78 | 3.41 |
| Intermediate v4 | 65,474 | 737.3 | 360.0 | 398.0 | 16.28 | 3.24 |
| Final v5 | 65,474 | 989.6 | 317.2 | 397.4 | 16.11 | 3.30 |
| Baseline v2 | 262,132 | 1,067.6 | 1,015.5 | 790.4 | 21.61 | 8.27 |
| Intermediate v3 | 262,132 | 836.1 | 773.0 | 791.2 | 20.28 | 8.44 |
| Intermediate v4 | 262,132 | 869.9 | 782.6 | 792.3 | 20.20 | 8.39 |
| Final v5 | 262,132 | 850.7 | 778.9 | 791.3 | 20.21 | 8.35 |

Final warm medians are 32.5% and 23.3% lower than the respective baseline. The fixed-wait removal explains part of this; the splitter changed too, and scheduling/font/WebKit variation prevents assigning the full difference to one change. Completed tasks are only 4.2% and 6.5% shorter. Edit latency is essentially unchanged because typing still debounces. Main-process CPU did not improve. No cold-start improvement is claimed: the small document's first page was slower in all later runs. These are completed runs with five warm samples each, not application-wide percentile guarantees.

| Run | Input | Main peak RSS MiB | Attributed family peak RSS MiB | Largest event-loop heartbeat delay ms |
| --- | --- | ---: | ---: | ---: |
| Baseline v2 | 64 KiB | 128.19 | 230.77 | 263.4 |
| Intermediate v3 | 64 KiB | 123.94 | 227.28 | 665.9 |
| Intermediate v4 | 64 KiB | 138.77 | 241.89 | 404.9 |
| Final v5 | 64 KiB | 128.70 | 239.59 | 538.6 |
| Baseline v2 | 256 KiB | 152.05 | 337.45 | 155.2 |
| Intermediate v3 | 256 KiB | 156.73 | 339.81 | 173.7 |
| Intermediate v4 | 256 KiB | 165.94 | 348.75 | 172.2 |
| Final v5 | 256 KiB | 168.31 | 348.33 | 158.8 |

Up to four attributed processes were observed: editor, WebContent, Networking and GPU. Ordinary editing has no preview helper cost. The final 64 KiB run's last sample caught an exiting editor with responsibility PID -1 and marked attribution unavailable; active preview samples were attributed. Its family maximum is an observed attributed maximum, not a claim of complete exit-time coverage. The first diagnostic run v1 launched without application responsibility and is excluded from all family comparisons.

The heartbeat includes fixture/window/startup work as well as editing/rendering. In final v5, the 64 KiB maximum was already recorded at the empty-window phase; it is not evidence of a 539 ms typing pause. Nonetheless, neither run establishes a sub-100 ms responsiveness guarantee. Profiling startup and actual input/wheel events remains necessary. Background parsing avoids blocking on the parser itself but does not remove synchronous TextKit layout or WebKit view creation costs.

## Preview closure and retained objects

Every final preview closure left zero live tracked preview objects; after all six cycles, tracked documents were also zero. Main-process footprint after each document closure was:

| Input | Cycles 1–6, MiB | After window close, MiB |
| --- | --- | ---: |
| 64 KiB | 83.97, 85.36, 82.61, 81.75, 80.11, 80.19 | 57.64 |
| 256 KiB | 79.25, 77.68, 77.14, 79.66, 95.82, 82.83 | 69.83 |

These tracked lifetimes passed and the closed tails did not grow monotonically. This does not prove absence of all leaks or long-session stability. Native allocator/font/layout/graphics caches can remain resident. The existing 96-document normal/undo lifecycle workloads remain separate evidence in [the earlier report](performance-optimization.md).

## Unchanged release runtime

Each workload launches an unchanged universal release executable in a copied bundle with a unique preference identity, one default 1220 × 810 content window, and files passed through the normal CLI open path. There is no editing, scrolling, preview or test code inside this release. External `vmmap -summary` and `ps` snapshots are collected near five and fifteen seconds; snapshot collection shifts the observed timestamps. Native window bounds were verified in all three cases. This is a short idle sample per case, not a sustained workload or a percentile distribution.

| Release workload | Final sample s | Current RSS MiB | Current physical footprint MiB | Main cumulative CPU s |
| --- | ---: | ---: | ---: | ---: |
| Empty untitled window | 15.56 | 36.98 | 25.0 | 0.17 |
| One 1 MiB source file | 15.61 | 82.16 | 60.5 | 0.51 |
| Eight 256 KiB source files | 15.67 | 62.69 | 74.8 | 1.34 |

The source fixtures repeat a Swift line containing Chinese and an emoji. Actual sizes are 1,048,560 bytes and 262,140 bytes per small file. Between the two samples, empty and eight-file cumulative CPU stayed unchanged at the counter's precision; the one-file case added 0.01 s. This shows little continuing idle CPU work over that interval. It does not establish editing latency, an absence of all leaks, or zero background cost when recovery/build/extensions are enabled.

Physical footprint uses the macOS task ledger, including chargeable/compressed/graphics allocations. RSS is resident-page accounting and can fall as pages are reclaimed or compressed while the process still owns data. The eight-file case consequently has a lower RSS but a larger footprint than the single-file case. Do not add these two metrics together or infer document release from RSS alone. WebKit preview rows above use a different workload and test executable and are not substitutes for these release idle values.

## Universal package

| Artifact | Bytes | MiB |
| --- | ---: | ---: |
| Universal ZIP | 1,699,109 | 1.62 |
| Application regular files | 3,621,148 | 3.45 |
| Allocated regular-file blocks | 3,653,632 | 3.48 |
| Universal executable | 2,965,616 | 2.83 |
| ARM64 slice | 1,474,672 | 1.41 |
| Intel x86_64 slice | 1,472,208 | 1.40 |
| Generated application icon | 632,482 | 0.60 |

The ZIP executable matches the release executable digest below. Both slices link system frameworks, including WebKit and ImageIO; no private framework/runtime is bundled. The OS runs one architecture slice, so universal packaging does not double the text heap. Directory/xattr metadata and APFS shared extents are outside the file-block sum. Compared with the historical 0.6.1 package, installed regular-file bytes increased 25.5% and ZIP bytes increased 17.6%, principally from added native features. The small package does not imply small preview runtime cost: WebKit helpers use system binaries outside the application bundle.

## Evidence and reproduction

The final regression gate `product-070-final-v4` passed 450 checks with 13 separately skipped text-contract vectors. The independent editor-only archive check passed and rebuilt identical universal release bytes. Release and test programs share production sources; these measurements execute the ARM slice. Physical Intel, Windows GUI, IME/VoiceOver, prolonged editing and power-loss acceptance remain unverified.

Release executable SHA256:

```text
2af7bc8a3f37eb839eb1108927a37aabf047dbc0b86c2ff9890808df77d59c33
```

Final performance-test executable SHA256:

```text
90a016f0fc580e2badaed655661e39572bc4da75e5f9f0d93c19437eff05d72c
```

Final production-source aggregate SHA256 (sorted Swift filename bytes followed by file contents):

```text
ccf9b1219b0d89de090137ad35b17d710158a7d86a74c22606e02f5e8438cc85
```

Baseline v2 test digest is `abc4ec977fc95afc0abd9ee2954dbfe97e422c0450d044e33472b54a23281eb4`; intermediate v3/v4 share `835cb6c0442f641e70e46084eabe3c4bffc924e30675b13ae53df45921e91def`. Raw manifests retain source/workload/fixture hashes. The recorded pre-commit HEAD is not the modified working source identity; use those hashes when comparing runs.

From an editor checkout or a test-enabled standalone source package, use fresh run names:

```sh
bash build.sh --arch universal
bash build.sh --tests
python3 tests/run_performance.py preview-local --no-build --cycles 6 \
  --cases markdown:65536 markdown:262144
python3 tests/measure_release_memory.py idle-local \
  --cases empty file multiple --duration 15
ditto -c -k --sequesterRsrc --keepParent '.build/Source Editor.app' \
  .build/SourceEditor-0.7.0-macos-universal.zip
python3 scripts/inspect_package.py '.build/Source Editor.app' \
  .build/diagnostics/package-local \
  --zip .build/SourceEditor-0.7.0-macos-universal.zip
```

Retained local evidence: `.build/performance/markdown-070-v2` through `markdown-070-v5`, `.build/diagnostics/package-070-v4`, `.build/diagnostics/release-070-idle-v2` and `.build/test-results/product-070-final-v4`. Binaries, raw local paths, fixtures and screenshots remain ignored. Public reports and rerunnable scripts ship in the standalone source archive. Project-search/recovery CPU and peak memory have bounds and functional tests, but have not been separately benchmarked; no measured speedup or low-overhead claim is made for them.
