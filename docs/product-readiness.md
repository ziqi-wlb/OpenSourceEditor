# Product readiness and development stages

Source Editor is an independent editor. Familiar workflows from Sublime Text and VS Code guide interaction design; their code and assets are not part of the application. macOS and Windows have separate native implementations and separate validation status.

For concrete daily development and note-taking gaps, implementation priorities and scenario acceptance, see [the daily-use analysis](daily-use-gap-analysis.md).

## Acceptance criteria

A stable release requires recoverable file operations, Unicode/IME correctness, reliable undo, bounded background work, clear coverage when limits are reached, keyboard and accessibility support, portable builds, documented configuration, actual GUI regression tests and resource measurements. Feature presence alone is not industrial readiness.

| Area | Current capability | Required additional acceptance |
| --- | --- | --- |
| File lifecycle | Strict decode, atomic save, disk-conflict checks, save/close cancellation, metadata restart, default independent drafts, normal restart recovery, explicit discard and external-change protection | Native chooser acceptance, long sessions, OS/hardware interruption and power-loss recovery |
| Editing | Native TextKit, multi-selection, undo, indentation, line/comment commands, split storage | Real IME, rectangular selection, large-file edit engine, richer grammars |
| Markdown | Edit/preview/side-by-side, templates, list/task editing, image paste, headings, HTML export | Prolonged editing, broader Markdown conformance, real wheel/inertia and accessibility |
| Project | Lazy tree, file create/move/trash, FSEvents refresh, Quick Open, background literal search | Ignore settings, project regex/replace, dirty-buffer search, external diff view |
| Extensions | Explicit one-shot Python commands/builds | LSP lifecycle, snippets and extension API/version policy |
| Distribution | macOS universal source/binary packages, local installer, Markdown association | Signed/notarized macOS releases and physical Intel validation |
| Windows | Smaller experimental Win32 implementation | Native platform UI/performance tests and feature parity |
| Accessibility | Native controls, named preview/search controls | VoiceOver, keyboard-only and high-contrast manual acceptance |

## Current implementation stage

macOS 0.9.0 adds retained draft backups on normal close, automatic restart recovery, explicit discard-and-reload, failed-write cancellation and persisted installed-font choices. Local Universal acceptance passed 598 checks with 13 explicit skips, including real two-window quit/restart. [Architecture](architecture.md), [feature matrix](features.md) and [current resource measurements](release-090-performance.md) describe the implementation and limits. Multi-file main-thread stalls and the broader industrial acceptance gaps remain.

macOS 0.8.0 adds preferences/workspace metadata persistence, recovery snapshot discovery, native file-event monitoring, scoped sidebar file management, Markdown note entry and bounded asynchronous single-file search. Clean disk updates reload; modified buffers remain intact. Search refuses incomplete replacement and obsolete revisions. [Implementation and validation](daily-use-implementation.md) documents capacities and remaining acceptance.

macOS 0.7.0 introduces a native Markdown document workspace and project-wide search. Markdown parsing is owned by Foundation: block identities, inline attributes and source positions flow into an escaped HTML adapter. WebKit is created only when requested. A serial operation queue debounces edits and rejects obsolete generations. Preview/export use the current unsaved buffer; switching views does not change text or undo history.

Project indexing and searching share one file traversal owner. Background requests are cancellable, cannot update a later project generation, and report capacity or unreadable data rather than claiming complete coverage. Search opens an exact source match only if it still exists in the current document. Build/test/preview helpers remain separate from user installations.

## Subsequent stages

1. Broaden keyboard, IME and prolonged recovery acceptance; test real system interruptions and power loss.
2. Add grammar/snippet/LSP support with versioned contracts, service cancellation and diagnostics; validate on real languages.
3. Extend the measured Markdown/WebKit workloads to large projects, recovery overhead and prolonged editing; profile before optimizing.
4. Run manual native IME, file-panel, accessibility, fullscreen/multiscreen and physical Intel acceptance; execute Windows GUI tests separately.
5. Prepare signed/notarized builds and a supported release/update policy after functional and reliability checks pass.

Each stage must record actual executed evidence and remaining gaps. This document does not certify industrial readiness or complete Sublime/VS Code compatibility.
