# macOS 0.9.11 memory investigation

[中文](memory-investigation.zh-CN.md)

On November 10, 2026, the installed 0.9.10 process had run for about six days. Its physical footprint was **3.6 GiB** although the initial `ps` RSS was only **126 MiB**. `heap` counted **27,396,411 allocations occupying 3,287,755,456 bytes**, including 53,301 table rows, 53,361 table cells, 106,666 layout engines and hundreds of thousands of constraints. Only five editor documents and one editor pane were live. Graphics regions and text/undo objects do not explain the dominant allocation volume.

The retained UI objects are the actionable cause. Tracing an old sidebar cell showed strong references through `NSToolTipManager._toolTipsByView` and notification blocks, which retain its surrounding view/layout graph. The sidebar assigned a path tooltip to a newly created cell on every request, without a reuse identifier or explicit removal cleanup. File events rebuild the project tree, restore expanded folders and reveal the active file, repeatedly exercising this code. `leaks` reported only ten unreachable allocations totaling 560 bytes; its definition excludes these reachable retained objects. Autorelease-pool content accounted for about 10.4 MiB, also insufficient to explain the total.

0.9.11 creates each cell's labels, icons and constraints once, assigns stable identifiers and uses AppKit's `makeView(withIdentifier:owner:)` reuse. Sidebar row removal and direct cell detachment unregister path tooltips; row views also have stable reuse identifiers. Cell reuse supplies the current label, icon, color and path. Command-palette and project-search result cells use the same bounded construction pattern. Text, encoding, undo and recovery behavior remain owned by their existing modules.

An additional tooltip-removal check deliberately retains removed cells, so cleanup cannot pass merely because the objects have been destroyed.

The native workload creates 80 files, repeatedly rebuilds/restores the sidebar, moves its viewport, leaves the mouse over it and avoids synthetic input between refreshes. It records physical footprint plus weak row/cell lifetimes and checks removed-cell tooltip cleanup, current path/label agreement and unchanged subview counts. The final run completed **1,000 refreshes**, retaining **26 tracked rows and 26 tracked cells** at every checkpoint. Its final eight checkpoints rose from **72.32 to 73.30 MiB**, with sampled peak RSS **106.70 MiB**. This is bounded tracked UI lifetime with some remaining allocator/framework growth, not a claim of constant total memory.

The shorter old-build workloads also retained 26 tracked rows/cells; they did **not** reproduce the complete six-day accumulation. The live heap/reference chain identifies the retained ownership problem, while these short probes establish functional and lifetime checks. There is no matched before/after speedup or long-session memory-reduction claim.

The accepted Universal 0.9.11 executable was installed locally after normal application termination; the previous bundle and support-state snapshot were preserved. The installed executable digest and running bundle path match the accepted artifact, with one production application. Its initial footprint was **102.4 MiB** (peak 141.6 MiB), heap allocation about **42.9 MiB**, and 78 sidebar cells/rows. The reopened process has two documents, compared with five in the old process: the reset measurement is a current observation, not a matched optimization A/B. Subsequent snapshots approximately 45 seconds apart measured 112.2 and 112.3 MiB; row/cell counts warmed from 78 to 115, then stayed at 115. These short observations do not establish multi-day stability.

The accepted build passed 20 core checks, 66 daily-feature checks, 33 home UI checks and 37 daily UI checks, including real FSEvents and project search, plus documentation/portability validation. Universal ARM64/Intel slices compiled; native Intel and Windows execution were not tested. Long runs with many expanded folders, tooltip interactions, changing projects and external file activity still need observation. Workspace indexing still rebuilds on file events; finer incremental refresh is a separate performance task.

Evidence stays in ignored `.build/test-results/memory-20261110/` (live `vmmap`, heap, leak/pool/ownership traces, builds, UI checks, accepted digests and installation), and `.build/performance/memory-final-tooltip/` (pinned test bundle, raw output and metrics). Reproduce from the application directory:

```sh
python3 tests/run_performance.py sidebar-memory --cycles 20 --cases sidebar:65536 --timeout 120
```

Use [development](development.md) for installation and verification rules. RSS omits compressed or reclaimed resident pages; footprint and RSS must be interpreted separately.
