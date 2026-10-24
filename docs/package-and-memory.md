# Release package size and runtime memory

Current 0.9.0 package, draft-write and process memory measurements are in [the latest resource report](release-090-performance.md). The 0.7.0 document-workspace measurements are in [its resource report](document-workspace-performance.md). The results below are the historical 0.6.1 baseline.

Measured on 2026-10-24 for macOS Source Editor 0.6.1, on an Apple M1 Pro with 16 GiB RAM, macOS 14.2.1 and Swift 5.10. Units below are binary: 1 MiB = 1,048,576 bytes. These measurements cover the current independent editor, not the installed Sublime Text application.

## Package inventory

| Artifact | Bytes | Size | Scope |
| --- | ---: | ---: | --- |
| macOS universal ZIP | 1,445,426 | 1.38 MiB | Download size, including archive metadata |
| Installed application files | 2,885,029 | 2.75 MiB | Sum of uncompressed regular-file lengths |
| Allocated application file blocks | 2,916,352 | 2.78 MiB | Sum of `st_blocks × 512` on this filesystem |
| Universal executable | 2,230,480 | 2.13 MiB | Both architecture slices and alignment |
| ARM64 slice | 1,099,984 | 1.05 MiB | Actual slice size reported by `lipo` |
| Intel x86_64 slice | 1,112,624 | 1.06 MiB | Actual slice size reported by `lipo` |
| Application icon | 632,482 | 617.66 KiB | Original generated multi-resolution ICNS |
| Python SDK/host examples | 20,195 | 19.72 KiB | Four Python source files; no Python runtime bundled |
| Configuration examples and plist | 1,872 | 1.83 KiB | Three JSON files and bundle metadata |

The executable is 77.31% of installed file bytes; the icon is 21.92%. ZIP compression reduces the executable to 805,697 bytes, while the icon remains 623,350 bytes because its image payload is already compressed. The icon accounts for about 43% of this ZIP. Source reports, tests, benchmarks, compiler caches, fixture data, screenshots and historical investigation artifacts are not in the application.

Allocated file blocks exclude directory and extended-attribute metadata. APFS clones, shared extents, compression and other filesystems change actual incremental disk use. The full development `.build/` directory includes multiple versions, test bundles and workload data; its size is not the installation size.

Both the installed executable and the executable extracted from the ZIP have SHA256:

```text
28eccc1fe508df95dbf05f574b49bd68eadf3e29f06993257e349515208ca006
```

`otool -L` reports only operating-system AppKit, Foundation, CoreGraphics, CryptoKit, Objective-C, Swift and system libraries for both slices. The bundle has no private framework/runtime directory, Electron, Chromium or Node. Extensions optionally launch an externally installed Python interpreter when requested; the idle workloads here start no extension/build workers.

The ARM slice has a 655,360-byte `__TEXT` segment and 393,216-byte `__LINKEDIT`; Intel has 679,936 and 372,736 bytes respectively. These segment sizes describe mapped regions and can include zero-fill/alignment. They are not a sum of executable file bytes or live heap consumption. In particular, the 4 GiB `__PAGEZERO` segment reserves inaccessible addresses and allocates no 4 GiB buffer. No `__DWARF` debug segment is present. The OS runs only the selected architecture slice, so a universal file does not double runtime heap usage.

For the separately built **experimental Windows 0.5.0** artifacts, the x64 EXE is 470,016 bytes (459 KiB) and its ZIP is 193,426 bytes (189 KiB). That ZIP contains the matching EXE and README; the 4,263,936-byte development PDB is excluded. The smaller Windows program implements fewer features. Windows native runtime, memory and MSVC-produced package sizes remain unmeasured; these are the existing cross-built artifacts, not macOS 0.6.1 feature parity.

## Release runtime measurement

The diagnostic copies the release bundle to an ignored directory and assigns it a fresh diagnostic bundle ID. The Mach-O digest remains unchanged. Direct execution starts an owned GUI process instead of forwarding files to a user's existing editor. The bundle identity isolates preferences and recent-file entries. Generated files are passed through the normal release CLI/native file-open path; no performance-test code is compiled into this binary, and fixture text is retained by the external Python runner rather than by a test driver inside the editor.

Each case starts a fresh process with one default 1220 × 810 content window, does no editing or scrolling, and samples at approximately 5, 15 and 30 seconds; the empty case instead ends at 60 seconds. A small external CoreGraphics probe verifies the owned bundle identity and window bounds, and checks the selected filename when the OS exposes the window title. Titles were available and verified in all reported runs. `vmmap -summary` reports physical footprint and its cumulative peak; `ps` supplies current RSS and cumulative CPU time. Snapshot collection adds about 0.6–2 seconds to the displayed timestamps. The runner terminates only its own generated workload after recording it and removes its generated preference domain and saved window state, retaining any cleanup error in the manifest.

| Release workload | Final sample | Current RSS | Current physical footprint | Footprint high water | Cumulative CPU |
| --- | ---: | ---: | ---: | ---: | ---: |
| Empty untitled window | 60.61 s | 39.38 MiB | 30.4 MiB | 45.5 MiB | 0.24 s |
| One 1 MiB source file | 30.61 s | 51.73 MiB | 63.2 MiB | 91.5 MiB | 0.53 s |
| Eight distinct 256 KiB source files | 30.59 s | 73.59 MiB | 74.7 MiB | 100.5 MiB | 1.33 s |
| One 4 MiB source file | 30.60 s | 65.36 MiB | 74.2 MiB | 109.1 MiB | 0.63 s |

The empty process rose from 23.7 to 34.3 MiB footprint during initial warming and finished at 30.4 MiB. Its cumulative CPU increased by about 0.04 seconds between the first and final snapshots, averaging about 0.08% of one core during that interval. One-file CPU rose by 0.01–0.02 seconds after the first snapshot; the eight-file CPU counter stayed at 1.33 seconds. This short idle observation shows little continuing CPU work in these cases; it does not establish responsiveness while editing or guarantee long-session memory stability.

Files repeat a Swift source line containing ASCII, Chinese and an emoji. Actual lengths are 1,048,560 and 4,194,291 bytes, and 262,140 bytes per small file. The 1 MiB fixture has 925,200 UTF16 units; the 4 MiB fixture has 3,700,845. The existing lexical threshold is 2,000,000 UTF16 units, so the 4 MiB case opens with plain presentation. Its costs and memory therefore do not scale as a fourfold version of the highlighted 1 MiB case. Filesystem caches were not flushed, ambient memory pressure was not controlled, and each row is one completed run rather than a percentile distribution.

## How to interpret the memory

RSS, physical footprint and virtual mappings answer different questions. RSS reports currently resident pages under the process accounting used by `ps`. Physical footprint is the macOS task ledger, accounting for chargeable private/dirty, compressed and graphics-related memory. It is not interchangeable with RSS. macOS can compress or reclaim pages while an idle process still owns them; a lower RSS does not imply that document data was freed. The `vmmap` SWAPPED column should not be read as proof of disk paging alone.

The full `vmmap` region totals include shared system-library mappings. The empty process maps about 3.0 GiB of virtual regions and its region table shows 229.1 MiB resident, including shared mappings, while process RSS is 39.38 MiB and chargeable footprint is 30.4 MiB. Summing library mappings would charge this app for shared OS memory and misstate its cost. About 1.4 GiB of malloc-zone address space is reserved; actual malloc bytes allocated are only 9.8 MiB at the final empty snapshot.

| Final `vmmap` breakdown | Empty | 1 MiB file | Eight files | 4 MiB file |
| --- | ---: | ---: | ---: | ---: |
| Malloc-zone bytes allocated | 9.8 MiB | 17.2 MiB | 27.3 MiB | 29.7 MiB |
| IOSurface virtual allocation | 4.67 MiB | 23.4 MiB | 23.4 MiB | 23.4 MiB |
| IOSurface resident pages | 3.23 MiB | 23.3 MiB | 23.3 MiB | 23.3 MiB |

These are observed allocator/region categories, not a complete additive partition of footprint. Malloc includes both editor and framework allocations; IOSurface/CoreAnimation/IOAccelerator reflect native drawing resources. WindowServer's separate process cost is outside this measurement. This is why multiplying file bytes by a constant cannot predict total application memory.

From the source ownership rules, each open document retains attributed text storage, a saved-text baseline, undo history and lazily populated offset caches. Disk bytes are read/decoded/hashed during open and are not retained as a full raw-data cache; the persistent disk digest is small. NSString/Swift bridging, encoding and copy-on-write determine physical text-copy costs, so saved text and storage should not be assumed to have a fixed sharing ratio. Split panes share document storage and text facts; each visible pane adds its own view/layout presentation state. The line index grows with logical line count and lexical ranges with match count. Edits invalidate text caches; whole-document commands can retain full previous text in undo history. Scrolling can retain additional glyph/layout and drawing allocations even after previously visited text goes offscreen.

## File closure and leak checks

The separate AppKit performance workload already tested twelve open/switch/close cycles of eight files: **96 distinct documents per process**, once normally and once with retained undo history. Every cycle ended with zero live weak probes for closed documents, storage, initial views and layout managers. Inactive documents had no attached layout managers. Normal closed footprint ranged from 82.22–92.92 MiB in cycles 7–12, ending at 82.22 MiB and then 67.75 MiB after window close. The undo tail ranged from 64.11–68.82 MiB. Neither tail grew persistently.

Those are test-build lifecycle results, with their own fixture allocation and scripted edits/scrolls; they must not be substituted for release idle numbers above. The probes establish destruction of the tracked objects in the tested paths, not a complete heap census. Allocator pools, font fallback, TextKit and graphics caches can remain warm after closing documents. Persistent process memory alone does not establish a retained document leak. See [optimization results](performance-optimization.md) for operation timing, scroll tradeoffs and exact test limits.

## Evidence and reproduction

From the editor root, after a release build, use fresh output names:

```sh
bash package.sh universal
python3 scripts/inspect_package.py '.build/Source Editor.app' \
  .build/diagnostics/package-local --zip .build/SourceEditor-0.6.1-macos-universal.zip
# Requires a logged-in macOS GUI session and a checkout/source package with tests:
python3 tests/measure_release_memory.py idle-local --cases empty --duration 60
python3 tests/measure_release_memory.py files-local --cases file multiple --duration 30
python3 tests/measure_release_memory.py large-local --cases file --bytes 4194304 --duration 30
python3 tests/run_performance.py lifecycle-local --cycles 12 --cases multiple:262144 undo:262144
```

The retained package evidence is `.build/diagnostics/resources-061-package/`: `inventory.json`, slice sizes, linked dependencies, Mach-O sections and a Windows ZIP inventory. Release runtime manifests and per-snapshot `vmmap` reports are in `resources-061-empty`, `resources-061-files` and `resources-061-four-mib` under that diagnostics parent. Native optimization/lifetime results remain in `.build/performance/final/` and `.build/performance/lifetime-final/`. Raw local diagnostics and binaries are ignored; this report and the reproducible scripts are included in source control. Both reports are included in minimal and test-enabled standalone source archives; runtime/lifecycle drivers require the test-enabled archive.

There is no bundled third-party runtime to remove. Smaller single-architecture distributions could save about 1.05 MiB uncompressed by omitting the other slice, while the universal package serves both Intel and ARM. Icon compression/resolution changes could reduce download size, but would require visual verification. Symbol stripping and a rope/piece-table text engine have not been implemented or benchmarked. The currently observed remaining costs are synchronous file decoding and whole-text edit/cache/undo work, first visits to unlaid regions, drawing caches and plugin/build workers when explicitly started. Native Windows, physical Intel GUI, real wheel/IME latency, much larger files and prolonged sessions remain additional measurement work.
