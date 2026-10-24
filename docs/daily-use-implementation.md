# 0.8.0 daily editing and work notes

[中文](daily-use-implementation.zh-CN.md)

**0.9.0 update:** independent draft backups are enabled by default and restore after normal close. Keep Drafts / Save All / Discard Drafts / Cancel are available. See [draft recovery](draft-recovery.md). All 0.8.0 validation figures below are historical.

This implements the first stage of [0.7.0 gap analysis](daily-use-gap-analysis.md): sustained editing, reliable external-file handling and efficient notes. macOS/Windows are separate implementations; this report covers macOS. See [readiness](product-readiness.md).

## Entry points

| Workflow | Behavior |
| --- | --- |
| Resume work | Argument-free normal restart restores projects, file order, selected tab/ranges, splits, sidebar, window, source scroll and Markdown mode; explicit file/project arguments take precedence |
| Preferences | Fonts, themes, default indentation and configured key bindings persist in support storage; file settings/disk encoding are separate |
| Abnormal-exit notes | Enable Auto Recovery; startup offers abandoned snapshots; Find Recovery Snapshots lists dates/sizes for selection |
| External save/delete | Monitor events; clean files reload; dirty/missing files retain buffers with Review; saving still rechecks digests |
| Manage project files | Row context menu New File/Folder, Rename, Move to Folder, Move to Trash; no destructive root actions |
| Markdown | Notes/palette templates, formatting, links, fences, timestamps; Enter continues lists/tasks/quotes; empty items end them |
| Tasks | ⇧⌘Return sets selected task lines together, skipping fences |
| Paste images | PNG/TIFF in Markdown source; untitled notes first choose a path; create sibling assets/image-UUID.png and a relative link |
| Find/replace | Debounced background scanning; counts or Partial limits; replacement requires complete current-revision scanning |

0.8.0 restart stores saved-file identities/display only; 0.9.0 adds unsaved/untitled drafts. Discarded text does not reappear. Manual Save Session remains independent.

## Ownership and implementation

`DesktopState.swift` owns versioned disk structures. The app loads preferences and reconstructs windows on argument-free launch; workspaces capture files/selections/layout. Quit confirms unsaved windows, records state and completes cleanup. Quit-time close callbacks do not replace final state with an empty list. Writes atomically replace and retain `.previous`; errors preserve originals and notify.

`FileMonitoring.swift` owns one FSEvents stream per workspace, recursively monitoring projects and external-file parents. Redundant descendant roots are removed. System latency and notification coalescing are each 0.3 s; there is no timed full-file polling. Event loss/overflow rechecks roots. Background bounded indexing remains, with expanded/selected tree state restored when possible.

A serial background queue reads, hashes and decodes disk content. Main-thread callbacks recheck closed state, ownership, path/operation identity and document revision. Unchanged clean buffers accept a new baseline and clear undo, matching Revert; dirty buffers preserve text/undo. Events do not authorize writing. Review offers retain/reload, while saves still enforce conflict checks.

`ProjectFileOperations.swift` owns path/name validation. Parent resolution bounds the project; final entries retain entry identity, so removing a symlink cannot remove its target. Moves reject overwrite/self-nesting. Case-only renames use a unique sibling temporary path only for the same parent/device/inode, with rollback on failure. Directory moves update all workspaces' document/recent paths by components, preserving dirty text, digests and undo. Trashed open text becomes untitled rather than being deleted.

`LanguageRules.swift` makes `EditorSyntax` own language recognition, support, comments, keywords and indentation. SQL rules and Java/Ruby/TOML extensions were added. Python block colons such as def/if/for indent while excluding strings/comments. Highlighting is basic regex lexical behavior, not an AST or full semantics.

`NoteEditing.swift` produces one UTF-16 transaction. Multiple cursors share fence context scanning, retaining needed line contexts only. Closing fences require the same symbol, sufficient length and no trailing content. Continued tasks reset to incomplete; task toggles skip fences; formatting preserves selected content. Marked IME Enter stays with AppKit. Source commands/preview share storage; one undo restores text and selections.

`NoteAssets.swift` uses ImageIO to decode/output uniquely named PNG and insert relative paths. Escaping assets symlinks are rejected; failed text transactions remove their newly created image. Undo removes the link but retains the image to avoid deleting an attachment another note may use. No orphan cleanup is provided.

`SearchEngine.swift` uses ICU progress callbacks to check deadlines/cancellation, checking matches each time and empty progress every 64 calls to reduce clock reads. This interrupts failed-match backtracking. One active search and one latest request are retained; text capture follows a 150 ms debounce. Query/options/document/revision own applicability; obsolete callbacks cannot change new documents. Cached offsets apply only to the current revision.

Replacement completes a bounded scan, then appends unchanged/replacement slices into one Foundation string instead of repeatedly moving the entire text. Conservative template/capture expansion bounds are checked before capture replacement allocation; total output is bounded. Commit rechecks revision; partial, expired, excessive or stale results reject replacement. Final TextKit/undo work remains on the main thread.

### Observed undo failure and fix

A native Unicode-bold/undo test restored `中文😀` but later commands stopped working. Sampling showed idle CPU. LLDB, after excluding layout diagnostics, captured an `NSTextStorage(NSUndo)` / `NSUndoReplaceCharacters` exception: `Range {0, 8} out of bounds; string length 4`.

Whole-buffer commands had registered `NSTextView.insertText` undo and separately changed selections, duplicating document transactions. Notes, tasks, images, search replacement and extensions now use `EditorTextView.applyEditorResult`: obtain native edit permission, disable native registration while updating the owned document and register one inverse transaction with original text/full selections. One owner restores both, avoiding stale native ranges.

## Bounds and compatibility

| Boundary | Behavior |
| --- | --- |
| Preferences/workspaces | JSON ≤ 1 MiB; ≤ 32 windows/256 files; ≤ 4,096 ranges per file; directory 0700/file 0600 |
| Recovery catalog | Metadata-only discovery up to 128 candidates; parse on selection; exclude active owners; listing does not promise all history |
| Automatic disk check | ≤ 32 MiB/file; report larger files; use previous disk encoding, with explicit reopen for encoding changes |
| Markdown edits | Fence scan ≤ 2 million UTF-16 units; larger Enter uses basic indent, task commands report capacity |
| Images | Input ≤ 16 MiB/16 million pixels; PNG ≤ 4 MiB; encoding/capacity errors distinguished |
| Search | Text ≤ 8 million UTF-16 units; query ≤ 4,096; ≤ 50,000 matches/200,000 capture ranges; 0.5 s budget, interruption depends on ICU callbacks |
| Replacement | Template ≤ 4,096; conservative capture/output bound ≤ 16 million UTF-16 units; partial scans reject single/all replacement |

Hidden/dependency exclusions remain; no .gitignore/configurable policy. Project search reads disk, excluding dirty buffers. Monitoring provides notices; save digests prevent overwrite conflicts.

## Validation and performance

Generated temporary projects/isolated identities are used; artifacts stay in `.build/`. User applications/clipboard are preserved. Figures describe their machines/datasets, not all languages/files or prolonged workloads.

### Final functional gate

`product-080-final-v2` builds matching Universal production and separate ARM test apps: **542 passed, 13 explicitly skipped**. Includes 55 new production-boundary checks, 37 new native UI, 204 earlier UI, 34 Markdown UI and real multi-window NSApplication termination.

New checks cover injected-store restart, discard exclusion, selection/Markdown restoration, Unicode bold undo/redo, Enter/tasks, actual PNG output, dirty-file rename/cross-window directory moves, target conflicts, symlink-trash target preservation, real FSEvents atomic save/delete/create, monitoring after projectless restore, stale-search rejection and late callbacks after close. Six existing abrupt-exit recovery checks pass. Restart uses a new app owner/real disk state, not a new OS login or power-loss experiment.

Pathological `(a+)+$` on 10,000 a characters plus ! stopped in **0.512 s**. Complete 40,000-match replacement took **15.8 ms**. Atomic external save→clean reload took **0.683 s**, including notifications/debounce. An 80 ms scheduled main-queue interval during regex execution was **84.8 ms**; this is scheduling, not key-to-screen latency distribution.

An isolated editor Git-subtree archive built identical release SHA-256 and passed nine service checks, without REA, Sublime, investigation files or outside source.

### Matched search/replacement measurements

`tests/measure_search.py` compares `9c719a9` search/edit code against final `SearchEngine.swift` at the same Foundation boundary: 1 million UTF-16 units, 1,000 matches, identical output and all 1,000 cursor ranges. Separate processes measure first and next two calls; OS caches remain warm.

| Metric | 0.7.0 | 0.8.0 |
| --- | ---: | ---: |
| First replacement | 20.59 ms | 10.65 ms |
| Mean of next two | 17.49 ms | 9.69 ms |
| Process user CPU, three calls/startup | 0.06 s | 0.03 s |
| Process RSS high water | 16.25 MiB | 14.50 MiB |

Warm calls are about **1.81×** faster for this dataset. Sequential Foundation appending avoids repeated movement and intermediate UTF-16-array encoding. Progress checks remain. An earlier array approach regressed and was replaced. TextKit commit, native undo, drawing and 150 ms query debounce are outside these timings; they are not GUI speedups. Process startup varies and is not an algorithm comparison.

### Package and release memory

Final regular files: **4,230,221 bytes (4.03 MiB)**; ZIP **1,935,428 (1.85 MiB)**, with identical executable hashes. Executable **3,574,688**, Intel slice 1,784,104, ARM 1,772,448 bytes. Relative to identically inventoried 0.7.0: regular files +16.8%, ZIP +13.9%. Only system frameworks are linked; Universal does not run both slices.

`measure_release_memory.py` copies the unchanged release, changes diagnostic identity and removes associations. Production state is enabled only for the official identity, isolating user workspaces. Fresh default-window cases sample vmmap/ps near 5/15 seconds without editing/scrolling/preview.

| Release workload | Physical footprint | RSS | Cumulative CPU |
| --- | ---: | ---: | ---: |
| Empty | 26.3 MiB | 35.67 MiB | 0.19 s |
| One ~1 MiB Swift file | 64.8 MiB | 47.11 MiB | 0.59 s |
| Eight ~256 KiB Swift files | 76.0 MiB | 69.27 MiB | 1.36 s |

RSS/footprint cannot be added or equated to object destruction. CPU did not increase at ps's 0.01 s precision between samples, showing little idle polling for these unchanged cases, not zero active-monitoring cost. No WebKit helpers were used.

### Editing, scrolling and repeated closure

`daily-080-final-v2` runs separate 1 MiB, four-round eight-file and four-round eight-file edit/undo cases, totaling **64 multi-file lifetimes**. Each cycle leaves nil document/storage/view/layout weak references, with no resource stop/failure. The multi-file cases are separate processes, not one sustained session.

| Workload | Sampled peak RSS | CPU through final window close | Maximum heartbeat |
| --- | ---: | ---: | ---: |
| 1 MiB edit/undo/scroll/reopen | 108.61 MiB | 1.89 s | 209 ms |
| 32 file opens/closes | 130.34 MiB | 6.74 s | 1,146 ms |
| 32 edit/undo/closes | 130.67 MiB | 6.42 s | 1,115 ms |

Native open returned **147.8 ms**, first settled layout **576 ms**, reopen **144.0 ms**, EOF edit **22.4 ms**, undo **15.4 ms**. First programmatic visits to eight positions took **14–23 ms**, revisits **0.23–3.30 ms**; this is not wheel/inertia/GPU timing.

Closed footprints: normal **54.3→50.3→51.3→48.2 MiB**, undo **51.0→57.8→55.7→58.8 MiB**. Framework/allocator caches may remain after tracked objects disappear; neither retained RSS nor weak references alone establish whole-app leak conclusions.

**Remaining cost:** eight consecutive synchronous main-queue opens/closes still stall heartbeat about 1.1 s. File search moved off-thread, but opens/layout/whole-text commits need further work. Input p95, eight-hour use and large active projects are unmeasured.

### Reproduction/evidence

```sh
bash tests/run_all.sh daily-acceptance --ui --arch universal
python3 tests/measure_search.py daily-search
python3 tests/measure_release_memory.py daily-idle --duration 15
python3 tests/run_performance.py daily-performance --no-build --cases file:1048576 multiple:262144 undo:262144 --cycles 4
python3 scripts/inspect_package.py '.build/Source Editor.app' .build/diagnostics/daily-package --zip .build/SourceEditor-0.8.0-macos-universal.zip
```

Without historical Git, supply `--baseline-file /path/to/baseline/EditorCore.swift` for search comparison. Environment: macOS 14.2.1, Apple Silicon, Swift 5.10; ARM execution and Intel compilation do not establish physical Intel acceptance.

Evidence: `.build/test-results/product-080-final-v2`, `.build/diagnostics/search-080-final-v2`, `.build/diagnostics/release-080-idle-v2`, `.build/diagnostics/package-080-final-v2`, `.build/performance/daily-080-final-v2`. Local output is excluded from Git/public source.

## Remaining work

1. Async multi-file opens/staged layout, main-thread whole-text commits, external diffs and bounded local history; Review currently offers retain/reload.
2. Image drag/drop, preview task editing, print/PDF, math/Mermaid, cross-note links/tasks.
3. Rich grammars, bracket pairing, snippets, external formatters, .editorconfig and optional LSP.
4. Dirty-buffer/project scoped search, ignore policy, replacement previews, build-error navigation, Git and terminal integration.
5. Real Chinese/Japanese IME/VoiceOver/multiscreen/fullscreen/sleep, eight-hour sessions, Intel/Windows, signing/notarization and updates.

Small regressions do not establish these capabilities. This is a usability/reliability milestone, not complete Sublime/VS Code parity or industrial certification.
