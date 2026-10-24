# Daily development and work notes: gaps and acceptance plan

[中文](daily-use-gap-analysis.zh-CN.md)

> This retains the 0.7.0 analysis baseline. 0.8.0 delivers stage-one preferences/workspace recovery, snapshot discovery, file monitoring, sidebar operations, note input, unified language rules and bounded background search. See [implementation](daily-use-implementation.md). Missing below describes the old baseline, not current behavior.

Analysis date: 2026-10-24, macOS 0.7.0 commit `9c719a9`, production entry points and earlier validation. Windows is separate and experimental. This is a plan, with no new runtime implementation in that investigation.

Basic code/config editing and Markdown writing/reading work. Daily use prioritizes persistence, external changes, input reliability, note efficiency and developer assistance. Debuggers, marketplaces, remote development and minimaps can follow. Implemented means a production entry; verified means its recorded scenarios. Source reasoning is not a current GUI reproduction, and keyword absence alone does not prove missing behavior.

## Baseline scope

| Scenario | Available in 0.7.0 | Limits |
| --- | --- | --- |
| Code/scripts/config | Files, multi-selection, literal/regex replacement, undo, indent, comments/line edits, encoding/endings | Basic regex highlighting; no semantic completion/navigation/diagnostics/formatter |
| Projects | Lazy sidebar, Quick Open, literal project search, explicit refresh, path copy | One root; no create/rename/delete or automatic monitoring |
| Commands | Explicit builds/output/cancel and one-shot Python | No PTY, error navigation, named task list/debugger |
| Markdown | Edit/preview/split, themes, headings, tables/code, task display, local images, HTML | No list continuation/image paste/task editing; no math/Mermaid/PDF |
| Continuity | Recent/reopen files, manual sessions, optional crash snapshots | Incomplete automatic settings/workspace restore, manual snapshot discovery, no version history |

Refresh, sessions, multi-selection, recovery, replacement and images already exist; the gap is their complete workflows.

## Confirmed producing-boundary gaps

1. Preferences are runtime objects with manual JSON import/export; startup does not restore complete default settings/workspaces. Recent files/recovery switches in UserDefaults do not imply all preferences persist. Separate global/project/file encoding/layout ownership.
2. Recovery writes exist, but startup discovery/visible failure/catalog is missing. Normal close cleans snapshots, so crash recovery is not previous-workspace or durable version history. Add time/digests/restore/ignore/status.
3. Newline indent copies existing indent and adds after braces, not Python block colons. Bracket/quote pairing is missing. Markdown lists require separate rules.
4. Syntax menus/highlighting have separate support sets: SQL is declared without matching highlighting; Java/Ruby/TOML have patterns but no default enum recognition. Generic regex does not model multiline/fenced/mixed syntax. Unify recognition/comments/indent/lexical ownership.
5. Explicit Refresh/Revert/conflict checks exist, but external create/change/move/delete workflows are incomplete. Preserve tree state and dirty content; show diffs rather than overwrite.
6. Project search is cancellable/bounded/rechecked but disk-only. No dirty-buffer search, project regex/replacement, .gitignore/configurable exclusions; document hidden-file policy for .env/.github.
7. Single-file search recomputes synchronously, collecting all matches without debounce/cancel/capacity. Large/complex regex responsiveness is a source-derived risk, not a reproduced GUI stall. Project background search does not prove every query is nonblocking; edits/undo still update whole text.
8. Build logs are not interactive terminals: no compiler location parsing, PTY/input/debug protocols. Builds/plugins can run tools but are not integrated formatting/LSP/Git.

| Evidence | Boundary |
| --- | --- |
| [Startup](../Sources/main.swift), [application](../Sources/EditorApplication.swift) | Runtime workspaces/preferences and missing default startup state in the baseline |
| [Editor UI](../Sources/EditorUI.swift): start/makeMenus/saveConfiguration/updateRecoverySnapshot | Menus, manual settings, recovery switches and startup |
| [Settings](../Sources/DocumentSettings.swift): EditorSyntax/insertNewline | SQL, extension detection and generic indent |
| [Highlights](../Sources/SyntaxHighlights.swift) | Separate support, regex and 2 million UTF-16 threshold |
| [Editor UI](../Sources/EditorUI.swift): sidebarContextMenu/setProject/revertCurrentDocument | Explicit refresh/index/disk reload |
| [Project search](../Sources/ProjectSearch.swift), [panel](../Sources/ProjectSearchPanel.swift) | Disk scanning, limits and cancellation |
| [Core](../Sources/EditorCore.swift), [UI](../Sources/EditorUI.swift): SearchEngine/controlTextDidChange/searchMatches | Baseline synchronous file-search chain |
| [Services](../Sources/EditorServices.swift), [extensions](../plugins.md) | Explicit processes/snapshots, not resident LSP/terminal |
| [Markdown](document-workspace.md) | Read-only tasks, local images, export and limits |

## Priorities

P0 is reliability/continuity before primary-tool use; P1 closes daily workflows; P2 adds efficiency/distribution. Existing native capabilities may need acceptance rather than rewriting.

| Priority | Work | Minimum acceptance |
| --- | --- | --- |
| P0 | Preferences/workspace restart | Restore fonts/theme/default indent/project/files/order/tab/ranges/layout; corrupt files retained with fallback |
| P0 | Recovery discovery | List time/count/limits on restart; restore separately; protect live snapshots; visible failures |
| P0 | External changes | Write/Git switch/move/delete notices; retain dirty text; valid clean reload ranges/tree state |
| P0 | Input/undo | Real Chinese/Japanese marked input, emoji/combining text, multi-input/paste, split and undo/redo |
| P0 | Search/large files | Debounce, revisions, result/memory bounds, incomplete coverage, workable regex interruption; measure edits/undo |
| P1 shared | Sidebar management | Create/rename/move/trash; dirty content, conflicts, permissions; update document/index identities |
| P1 notes | Markdown entry | Continue/end unordered/ordered/tasks/quotes, indent lists, insert headings/links/fences, single undo/IME correctness |
| P1 notes | Images/attachments | Paste/drop, scoped assets/relative links, unique names, no dangling failed links, capacity checks |
| P1 notes | Tasks/templates | Source task commands, revision-mapped preview tasks, timestamp/meeting/daily/to-do templates |
| P1 notes | Reading/sharing | Print/PDF/styles, paged code/tables and source-location sync; retain HTML |
| P1 development | Unified languages | Python/Swift/JS/TS/JSON/YAML/Shell/Markdown, actual comments/strings/indent/brackets/basic snippets |
| P1 development | Formatting/config | Explicit external formatter, file/range, one undo, stale-result rejection, global/project/.editorconfig; no bundled toolchain |
| P1 development | LSP/navigation | Optional real completion/hover/definitions/references/diagnostics/symbols/history; service timeout/cancel/isolation |
| P1 shared | Search workflow | File/range scopes, includes/excludes/dirty buffers, preview/recheck project replacement, explicit failures; no cross-file atomic undo claim |
| P1 development | Builds/terminal | Named tasks, error navigation, explicit disk-text builds; external project terminal before embedded PTY |
| P1 development | Git basics | Status/diff/line changes/conflicts, refresh after external Git; commits/push explicit, optional external client |
| P1 shared | Local history | Bounded versions/diffs/restore-to-new-buffer/capacity/days; independent crash snapshots and user-selected scope |
| P2 | UI/advanced notes | Pin/order tabs, breadcrumbs, rectangular selection, folding, focus reading; math/Mermaid/links/tags/tasks by real demand |
| P2 | Distribution/platforms | Signing/notarization/update policy/Intel; Windows per-file undo, Markdown/search/session parity and native validation |

## Order and scenarios

1. Reliability/continuity plus sidebar basics: restart the work scene and protect text from external changes/IME.
2. Notes: lists/tasks/images/templates/PDF/search, from meeting to shareable archive without requiring a knowledge-base database.
3. Development: language rules/format/LSP/navigation/tasks/Git, alongside external terminals/clients before full debugger/marketplace.
4. Prolonged work/projects/accessibility/screens and Intel/Windows acceptance, then signing/updates.

The following are planned checks, not recorded passes.

Notes: folder→Markdown template→Chinese input→lists/tasks→screenshot paste→split preview→task toggle→cross-note search→save/PDF→quit/restart. Include untitled/external changes/write failures/image conflicts/limits/cancel/crash; ordinary Markdown tools must read files/assets.

Development: real project→search including dirty files→Quick Open→definition/back→edit/indent/format→diagnostics→build/test→error click→Git diff→external branch switch→retain dirty text/resolve conflict. Languages are recommendations, accepted against actual repositories/toolchains; simulated LSP is insufficient.

Reliability/performance:

- Eight-hour sessions with windows, save/recovery/preview/project switches/cancel and quit/restart choices.
- Fixed machine/window/data, real input-to-display/query/open/wheel, cold/warm, main/helpers, CPU/memory. Initial goals p95 input <50 ms and 1 MiB open <500 ms remain unverified.
- Large/long-line/many/no-match/pathological/capacity inputs, cancellation/degradation rather than small-file averages.
- At least 100 repeated document lifetimes; tracked release, task completion and settled memory trends plus heap diagnosis. RSS need not return to cold baseline each time.
- Real Chinese/Japanese IME, keyboard, VoiceOver, large fonts, themes, multiscreen/fullscreen/sleep.

## Evidence and scope

Historical `product-070-final-v4`: 450 passed/13 skipped, matching source digests, 34 Markdown UI and six abrupt recovery checks. Successful chooser selection and eight-hour use remain unverified. This does not establish the planned features.

Six-cycle preview and earlier 96-document lifetime results are in [workspace performance](document-workspace-performance.md) and [text performance](performance-optimization.md). Tracked release is not all-path leak freedom; WebKit startup/real input/wheel have remaining scope.

The investigation reviewed source/retained summaries only, with no new GUI/performance reproduction, build/install or user-window operation. See [readiness](product-readiness.md) for later release acceptance.
