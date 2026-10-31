# Current gaps and improvement plan

[中文](current-gap-analysis.zh-CN.md)

Reviewed on 2026-10-31 against macOS **0.9.10 build 23**, production source and retained acceptance records. The initial independent GitHub revision is `40eae77`; its source tree matches the parent checkout's `editor/` tree at `c744ddc`. Windows has a separate implementation and acceptance scope.

The editor supports daily text and Markdown work, but the current evidence does not support a stable-release claim. First resolve the reproducible UI acceptance failures, then close input/recovery acceptance and project-search workflows. Developer assistance and broader platform support follow those foundations.

## Evidence and completed capabilities

| Area | Current evidence | Practical limit |
| --- | --- | --- |
| Files and continuity | Strict encoding, disk-conflict checks, atomic saves, independent drafts, workspace restoration and FSEvents already exist | Real chooser success, actual IME, long sessions and interruption durability need dedicated acceptance |
| Editing and layout | Multi-selection, undo, list continuation, independent split panes, Focus Mode, title/path input and images exist | Focused acceptance is not a complete UI release gate |
| Current acceptance | `typing-0910-delivery` records 167 passed checks against the accepted unchanged binaries | It reuses checks from an earlier run; no new full-suite pass is implied |
| Targeted recheck on 2026-10-31 | The same test executable, SHA-256 `f8dbc92ac04aecbc61f49681ee954502b1251aaba8eb05bc7e2c8bb65709607f`, passed 77 product UI checks and failed two | Divider dragging and rendered heading-fragment navigation still fail; product behavior versus fixture assumptions needs diagnosis |
| Source identity | Every production input recorded by focused acceptance matched the current files before the recheck | Reused builds are identified explicitly; this is not a fresh compiler run |
| Fresh local headless gate | `readiness-20261031-headless` rebuilt Universal release and native test programs; 280 passed and 13 explicitly skipped | No full native UI pass is implied |
| Standalone source export | The exported application compiled arm64 independently; its 28 bilingual guide pairs and post-build portability checks passed | This does not verify Windows compilation or physical Intel execution |
| Distribution | Universal packages, standalone source export, local installer and Windows build entry points exist | Signing, notarization, release/update policy, physical Intel and native Windows GUI acceptance remain open |
| Initial GitHub Actions run | [Run 41196358177](https://github.com/ziqi-wlb/OpenSourceEditor/actions/runs/41196358177) passed macOS checks/package and failed the Windows MSVC build | Codec execution was skipped; the Windows build needs a new cloud check |

The older [daily-use gap analysis](daily-use-gap-analysis.md) describes 0.7.0. Preferences, recovery discovery, file monitoring, sidebar management, language-rule unification and bounded single-file search have since shipped. They should not be listed as missing implementations again. Their untested operating conditions remain acceptance work.

## Prioritized backlog

P0 blocks a stable release. P1 closes daily workflows. P2 follows measured demand. “Acceptance gap” means functionality exists but the stated conditions have not been verified; it does not establish a defect.

| Priority | Gap and evidence | Next concrete result | Acceptance |
| --- | --- | --- | --- |
| P0 | Two reproducible product UI failures in [ProductUITests](../tests/Swift/ProductUITests.swift) | Diagnose native drag coordinates/layout timing and WebKit fragment activation; correct the producing boundary or the inaccurate fixture | Both checks pass with actual native interaction, then the full UI gate completes without suppressing assertions |
| P0 | Initial Windows MSVC build failed; [source](../windows/main.cpp) uses `std::min` after Windows SDK headers without `NOMINMAX` | Add the SDK macro guard and retain compiler diagnostics; rerun the native build | Windows release/test compilation and codec checks pass in CI; further compiler failures receive their own diagnosis |
| P0 | Real Chinese/Japanese composition is unverified | Add a manual input matrix and fix any reproduced composition/undo issue | Marked input, candidate selection, emoji/combining text, Return, undo/redo and both split panes retain text and cursor |
| P0 | File/recovery operating conditions remain unverified | Exercise successful native Open/Save As/overwrite, permission failures, external replacement, sleep and normal restart | Original files and drafts remain intact; failures are visible and cancellation leaves edits recoverable |
| P1 | Project search reads disk only; no dirty-buffer search, project regex/replace or configurable ignores | Introduce one shared traversal policy and document/revision snapshots, then scoped search and replacement preview | `.env`/`.github`, nested ignore rules, dirty text, encoding, cancellations and partial coverage are explicit; replacement rechecks each target |
| P1 | [ProjectFileScanner](../Sources/ProjectSearch.swift) skips all hidden files and uses fixed directory exclusions | Make inclusion/exclusion policy configurable for Quick Open and project search | Both consumers enumerate the same intended scope; hidden config files are selectable without scanning unwanted build/dependency trees |
| P1 | Basic syntax/builds exist; semantic completion/navigation/diagnostics and integrated formatting do not | Start with an optional external formatter: argv, snapshot identity, bounded output, cancellation, one undo; then one real LSP | Test against a real project/toolchain, reject stale edits and retain service ownership until termination |
| P1 | External-change notices lack a diff workflow; drafts are not versioned local history | Offer disk-versus-buffer review and bounded restore-to-new-buffer history | Changed originals and unsaved work remain protected; retention, capacity and write failure behavior are clear |
| P1 | [BuildRunner](../Sources/EditorServices.swift) runs selected commands without compiler-location navigation or PTY interaction | Named tasks and clickable file/line results, with an external-terminal action first | Correct project paths, Unicode names, cancellation and stale-file navigation; execution remains explicit |
| P1 | Markdown is useful but lacks PDF, math/Mermaid and source/preview synchronization | Prioritize PDF sharing and source/preview navigation before optional renderers | Unsaved source, long tables/code, local images, fragment links and cancellation work with bounded resources |
| P1 | Current-version prolonged latency/memory and large-project data are incomplete | Measure the current build with fixed workloads before choosing optimizations | Record input/open/search p50/p95, heartbeat, main/helper CPU, footprint, cancellation and settled lifetime trends |
| P1 | Native controls exist but keyboard-only/VoiceOver and multi-display acceptance is incomplete | Add a manual accessibility/display checklist and address reproduced failures | Focus order, readable labels, large fonts, contrast, fullscreen, display changes and sleep work in real sessions |
| P1 | No license selected; unsigned/unnotarized packages and no supported release/update policy | Owner selects license; establish tag-to-artifact provenance and signing/update policy | The downloadable artifact is tied to its commit, version, tests and checksum; platform claims match execution evidence |
| P2 | Windows parity and physical Intel GUI remain unverified | Validate Windows save/clipboard/undo first, then per-file undo and selected shared workflows | Native Windows execution and physical Intel GUI are recorded separately from cross-build/Rosetta results |
| P2 | UI responsibility is concentrated in one source file | Extract workspace layout, search presentation and dialogs by ownership when those areas change | Existing document identity, undo, close/quit and background ownership contracts remain intact |

## Source boundaries and measured limits

The [single-file search engine](../Sources/SearchEngine.swift) already caps queries at 4,096 UTF-16 units, documents at 8 million units and results at 50,000 matches/200,000 capture ranges. It uses ICU progress callbacks with a 0.5-second budget, cancellation and a latest-request worker. Reimplementing it as merely “background search” would repeat completed work. Broader pathological-regex acceptance is a separate question.

[Project search](../Sources/ProjectSearch.swift) uses a 50,000-file traversal cap, a 2 MiB per-file limit, 128 MiB total read budget and 2,000 hits. The engine strictly decodes disk bytes and skips binary/unreadable inputs. Partial results and skipped files must remain visible when extending the workflow. Add buffer revisions and a shared ignore policy before cross-file replacement; do not promise atomic cross-file undo.

[Opening a document](../Sources/EditorUI.swift) calls the document owner's open operation synchronously. Large-file open/edit costs need measurement before selecting asynchronous reads or a different text-storage model. Moving reads off the main queue alone does not remove decode, storage installation or layout work.

The current production Swift sources contain 9,298 lines; `EditorUI.swift` accounts for 4,472, approximately 48%. This identifies a maintenance concentration, not a measured performance defect. Changes should preserve document-owned text/disk settings, revision checks and workspace-owned tasks rather than introduce a broad rewrite.

## Work order and completion gates

1. Resolve the two current UI failures; complete the full UI gate and the real input/file-panel matrix. Install and verify every accepted runtime change using the [delivery workflow](development.md).
2. Add shared project inclusion/ignore rules and dirty-buffer search; implement project regex/replacement only after scope, completeness and revisions are trustworthy.
3. Add explicit formatter, compiler error navigation and one optional LSP. Add Git diff through the same disk/buffer review boundary.
4. Improve Markdown sharing/navigation and accessibility, guided by actual note-taking scenarios.
5. Measure sustained workloads and validate native platforms; prepare signed releases and a supported update policy after functional acceptance.

Each implementation should have a focused Conventional Commit, bilingual documentation, impact-scoped checks and retained evidence. A full gate is appropriate for cross-module/release work, not every small edit. Completed runtime changes also require normal shutdown with drafts preserved, installation backup, relaunch and installed-version/path/digest reconciliation.

## Improvements made during this review

Both parent-checkout and standalone workflows now retain macOS test evidence and Windows compiler logs even when validation fails and set finite platform job deadlines. The parent workflow also matches the standalone workflow's explicit Python version, read-only repository permissions and strict package-artifact checks. Windows defines `NOMINMAX` before including SDK headers to protect standard-library calls from SDK macros. This source-derived correction requires cloud verification; initial job annotations only establish failure at the build step. Headless CI still does not establish native desktop UI acceptance.

This review adds the current backlog and links it from development/readiness/navigation guides. No macOS production editor source changed. Local artifacts, screenshots and logs stay under `.build/test-results/readiness-20261031/`; the targeted UI recheck remains recorded as failed. GitHub cloud status is reported separately from local validation.
