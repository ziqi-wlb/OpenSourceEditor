# Markdown, project search and recovery

## Markdown workspace

Markdown extensions `.md`, `.markdown`, `.mdown` and `.mkd` share the same toolbar. **Edit**, **Preview** and **Side by Side** are remembered per open document. The source buffer, selections and native undo history remain available when switching views. Preview uses the current unsaved text. Dark/light editor themes also style the rendered document.

In 0.8.2, **Outline** always directly opens full Preview with one click. This also applies while rendering, when already in Preview, in Side by Side, and to notes without headings. There is no secondary menu, heading selection or Build step. Heading navigation remains in the rendered page's Contents section. **⌘B** and **Tools → Render Markdown** also use the same renderer for Markdown, including unsaved content: no build configuration, compiler, external command or automatic save is involved. Other syntaxes retain the configured build workflow.

Foundation's native Markdown parser owns block identities, inline attributes and source positions. An HTML adapter handles headings, paragraphs, nested lists, quotes, tables, fenced code, links, emphasis and task checkboxes. Checkboxes display task state and do not edit the source. Code fences show the supplied language and escaped code; they do not run code. Contents links navigate within the rendered page and leave source selections intact. HTML export embeds the current styling and local images into a standalone page.

The preview creates a system WKWebView only on request. Explicit preview requests start immediately; subsequent text edits use a 250 ms debounce. Each view owns a serial render queue with cancellation and revision/generation checks. Obsolete results cannot replace a newer document. Foundation's parse call cannot be interrupted mid-call; input bounds limit that work, and adaptation checks cancellation between runs and blocks. Returning to Edit, switching to a plain text document or closing the window cancels work and detaches the preview. Approximate relative scroll position is preserved across updates; source/preview scrolling is not synchronized by source line.

Rendering status in 0.8.2 remains active until WebKit finishes the matching content navigation. The preview owns that navigation together with its document revision; blank or obsolete loads cannot mark the current page ready. Parsed HTML alone does not establish displayed DOM readiness. This also keeps export disabled until the requested page is loaded. Outline no longer retains a pending heading-menu action, and the superseded source-selection navigation bridge was removed.

The view supplies a private, non-network `source-editor-preview://document/` base URL. Contents links resolve to that origin and are checked against the current page's parsed headings before scrolling. The native UI fixture reproduced ineffective `about:blank` fragment navigation; the private origin and owned navigation route pass an actual AppKit mouse-event check. HTML export keeps ordinary fragment links and does not include the private origin.

Raw HTML displays as escaped text, document scripts are disabled, and remote images are not fetched. HTTP/HTTPS/mail links open through the system; relative file links open in the editor. Local images are resolved against the document directory and confined to the project root or document directory after resolving symlinks. Images have a 4 MiB individual and 12 MiB combined input budget, with a 40 million pixel ceiling. Repeated image references also consume a 16 MiB embedded-output budget, preventing a cached image from expanding HTML without bounds. The preview rejects documents above 2 million UTF-16 units, 100,000 styled runs/blocks or 32 MiB rendered HTML; the source stays editable. Mathematical notation, Mermaid, embedded HTML and full GitHub Markdown compatibility are not implemented.

## Project search

**Find → Find in Project** (`⇧⌘F`) searches literal text in current disk files. Case matching is optional. Results show relative paths, logical line numbers and excerpts; double-click or Return opens the exact source range. The range is checked against the current buffer before selection, so a disk search cannot silently select unrelated text in an edited buffer.

Quick Open and project search share a cancellable traversal owner. It publishes absolute file identities and skips hidden files, packages, symlinks, `node_modules` and `__pycache__`. One search examines at most 50,000 files, reads at most 128 MiB total and 2 MiB per file, and returns at most 2,000 matches. Binary/undecodable files are skipped. The status reports skipped files and reached limits. Regex, project replacement, multiple project roots, `.gitignore` rules and configurable exclusions remain future work.

## Editing commands

| Action | macOS shortcut | Behavior |
| --- | --- | --- |
| Toggle Markdown preview | `⇧⌘V` | Source/rendered document |
| Toggle side-by-side | `⌥⌘V` | Native source beside preview |
| Find in Project | `⇧⌘F` | Background literal disk search |
| Toggle Comment | `⌘/` | Current syntax's supported line/block form |
| Duplicate Lines | `⇧⌘D` | Selected logical lines once; select the copies |
| Delete Lines | `⇧⌘K` | Selected logical lines |
| Move Lines | `⌥↑` / `⌥↓` | Move selected line groups one position |

Line operations merge overlapping selected lines, retain Unicode boundaries and handle LF, CRLF, CR and an unterminated final line. Move operations preserve each position's line terminator. Each command is one native undo transaction, including cursor restoration. Comments keep indentation and skip blank lines. JSON/plain text have no comment command; block-comment delimiter conflicts report an error and keep the text intact. These commands are basic syntax operations, not a grammar-aware refactoring engine.

## Optional recovery

Enable **File → Recovery → Enable Auto Recovery** for a workspace. The preference controls future windows after restart. Every five seconds, changed unsaved buffers are captured on the main thread and encoded/written on a serial utility queue. Clean buffers are excluded. At most one snapshot write runs per workspace; edits during a write are picked up at a later timer interval. No file is automatically saved over its source.

Snapshots live in `~/Library/Application Support/Source Editor/Recovery/`. Each workspace owns one random JSON filename, with private file permissions. Automatic capture has a 128 modified-document and 4 million UTF-16 unit source budget. Encoded sessions have the shared 32 MiB session ceiling. Capacity/write errors appear in the location status tooltip and preserve the last successful snapshot; that snapshot may be older. Use Save or Save Session for buffers outside these bounds.

After an unexpected exit, choose **Recover Snapshot in New Window…**. The saved disk digest is checked: unchanged originals retain their path and baseline; changed/missing files recover into modified untitled buffers. Live window snapshots cannot be restored through this command. The original recovered snapshot remains available until manually removed through **Show Recovery Folder**. Corrupt snapshots are retained for inspection.

Saving all modified buffers clears stale snapshot content. Disabling recovery, closing its window or quitting normally queues removal after any pending write, and the application's existing completion path waits for it. A late write cannot recreate a cleaned snapshot. The timer interval and an in-flight write create a recovery gap; atomic file replacement is not a guarantee against hardware/power-loss failure. Recovery does not preserve native undo history.

## Verification

macOS 0.8.2 passed **560 checks**, with **13 explicitly skipped** contract vectors, in `markdown-render-082-verified`. Its 52 document-workspace UI checks cover Outline in Edit, Preview, Side by Side, during rendering and on notes without headings; repeated clicks retain the same preview and preserve source selection. Native mouse events verify Contents scrolling. Current-page loading, theme changes, HTML export, cancellation, source edits and undo also pass. Universal release slices compiled; native UI checks ran on Apple Silicon. The following 0.8.1 record is historical.

macOS 0.8.1 passed **557 checks**, with **13 explicitly skipped** contract vectors, in `markdown-render-081-v2`. Its 49 document-workspace UI checks include clicking the actual Outline button, rendering unsaved text without a chooser or save, preserving undo, rendering instead of executing a configured command for Markdown, and executing that same command for another syntax. Menu labels follow the current syntax. The test uses the current text view after tab changes and waits for rendered DOM content; `isLoading == false` alone does not establish that a requested page has loaded. Both macOS architecture slices compiled; native UI checks ran on Apple Silicon.

```sh
bash tests/run_all.sh markdown-render-verification --ui --arch universal
```

Production-boundary checks cover parser behavior, local resource rules, project coverage/cancellation and Unicode line/comment semantics. Native UI checks exercise source/preview transitions, current-buffer export, stale render generations, selection navigation, single-undo commands, separate recovery windows and ordered cleanup. A separate process writes through the real recovery queue and exits abruptly; a fresh process validates recovery with changed disk content and corrupt snapshots. Results remain in ignored `.build/test-results/`.

The final macOS 0.7.0 universal gate passed 450 checks, including 34 document-workspace UI checks and six abrupt-exit/restart recovery checks. The older text-contract runner separately marked 13 vectors skipped: some require other production boundaries, while swap/title case and shipped loader compatibility remain unsupported. Skipped vectors are not counted as passes. A fresh editor-only source archive rebuilt the same universal release bytes and passed nine service checks.

See [product acceptance](product-readiness.md), [current resource measurements](document-workspace-performance.md) and [earlier text-engine measurements](performance-optimization.md). These checks do not replace manual IME, VoiceOver, prolonged editing, physical Intel or Windows GUI acceptance.
