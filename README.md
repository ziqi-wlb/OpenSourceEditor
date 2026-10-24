# Source Editor

An independently implemented macOS text editor. Build and run this directory on its own: no Sublime Text installation, REA, npm, network, or investigation files are required. The native Windows implementation is in [windows](windows/README.md).

[Documentation](docs/README.md) · [Architecture and principles](docs/architecture.md) · [Feature matrix](docs/features.md) · [Development and contribution](docs/development.md)

## Build and install on macOS

Requires macOS 13 or later and Xcode Command Line Tools (`xcode-select --install`). Python 3 is optional for extensions. From this directory:

```sh
bash scripts/install_macos.sh universal  # Build, install in ~/Applications, register and launch
# Or build without installing:
bash build.sh --arch universal  # Intel x86_64 + Apple Silicon arm64
open '.build/Source Editor.app'
# Alternatively: --arch arm64 or --arch x86_64
bash package.sh universal      # ZIP containing the standalone application
```

To install, unzip the package and drag **Source Editor.app** into Applications. A per-user installation needs no administrator permission:

```sh
mkdir -p "$HOME/Applications"
cp -R '.build/Source Editor.app' "$HOME/Applications/"
open "$HOME/Applications/Source Editor.app"
```

The application is currently unsigned and unnotarized. For a downloaded build, use Finder's **Open** action and the macOS approval dialog if needed. Packaging does not change security settings or the default editor.

The installer preserves an existing Source Editor installation under ignored `.build/install-backups/` and asks you to save and quit any running copy before updating. It registers the installed application with macOS Launch Services. Markdown (`.md`, `.markdown`, `.mdown`, `.mkd`) and text files can then choose **Source Editor** in Finder's **Open With** menu. The installer does not select a default application. If an already-open Finder menu is stale, close it and reopen it; **Open With → Other…** can also select the installed application.

```sh
'.build/Source Editor.app/Contents/MacOS/source-editor' --project . README.md
'.build/Source Editor.app/Contents/MacOS/source-editor' --help
'.build/Source Editor.app/Contents/MacOS/source-editor' --version
```

## Multiple windows on macOS

**File → New Window** (`⌘⇧N`) creates a workspace inside the running application. New windows fold into native window tabs by default, with one Dock application icon. Each workspace keeps its own documents, project, selections and undo history. The menu bar follows the selected workspace; theme and font preferences apply across windows.

Use **Window → Move Window Tab to New Window** to detach a workspace, and **Window → Merge All Windows** to fold them together again. Detached windows still share the same Dock icon. **File → Close Window** (`⌘⇧W`) closes a workspace after checking unsaved files; **Close Tab** (`⌘W`) closes a file. Quit checks unsaved documents in every workspace and waits for build/plugin cancellation. Closing the last window keeps the application running; clicking its Dock icon opens a new workspace.

Finder, normal `open`, and direct CLI relaunches reuse the running application. Files already open in another workspace select that workspace. Avoid `open -n`, which requests a separate application instance. Windows from older versions or applications with a different bundle identity must be saved and quit normally before their old Dock icons disappear.

## Features and implementation

Swift and AppKit provide native windows, text layout, tabs, project trees, shared-document split views, find/replace and regex search, multiple selections, undo/redo, file lifecycle and session restore. Status controls change encoding/BOM, line endings, syntax and tabs/spaces. Dark/light themes, configurable fonts, and native context menus on file tabs, text and project rows are included. Saving checks external disk changes and uses atomic replacement. Explicitly chosen build commands and a one-shot Python SDK support extensions; see [plugins](plugins.md) and [configuration examples](Resources/examples).

Choose **Preferences → Editor Font** for System Monospaced, Menlo, Monaco or Courier New when installed. **View → Font** adjusts size; custom installed fonts can also be set through `font_face` in settings. Font preferences apply across workspaces and persist after restart. System fonts are used directly, without bundled font assets. The generated icon simplifies its orbit/grid at small sizes so the terminal mark remains legible.

Markdown files have an **Edit / Preview / Side by Side** toolbar. Use **⇧⌘V** to toggle rendered preview and **⌥⌘V** for side-by-side. **Outline** always opens full rendered Preview in one click, including from Side by Side or during rendering; it never opens a second menu or requires Build. Preview and HTML export start with the document body, without an automatically inserted Contents section; links written in the document can still navigate to headings. For Markdown, **⌘B** and **Tools → Render Markdown** also render the current unsaved buffer without saving or running a build command. **Export HTML…** saves it as a styled page. **⇧⌘F** searches the project in a cancellable native sheet. **⌘/** toggles comments; **⇧⌘D** duplicates lines, **⇧⌘K** deletes lines, and **⌥↑ / ⌥↓** moves lines. These actions also appear in menus and the command palette.

Opening or switching to a file inside the current project expands its ancestor folders, selects its sidebar row and scrolls it into view while retaining editor focus and other expanded folders. A hidden sidebar stays hidden and follows the current file when shown again. Untitled notes and files outside the project leave the project tree unchanged.

**Notes** adds blank/meeting/daily/task templates, list/task/quote continuation, task toggling (`⇧⌘Return`), bold (`⇧⌘B`), italic (`⌘I`), links/code blocks and timestamps. Paste a PNG/TIFF image into a saved Markdown note to create a unique PNG in its adjacent `assets/` directory and insert a relative link. Undo removes the link; it preserves the attachment for reuse.

Preferences and file/workspace metadata restore after a normal quit. Draft backup is enabled by default. Close or quit with **Keep Drafts** to restore unfinished files and untitled notes next time without changing source files; **Save All**, **Discard Drafts** and **Cancel** remain explicit choices. External file events refresh the project; clean files reload, while modified/missing files keep their buffers and show a review notice. Project row menus create, rename, move and trash files/folders. Open buffers and recent paths follow moves across windows; trashing an open file preserves its text as an untitled buffer.

Single-file search runs in the background with debounce, cancellation and revision checks. Partial results are labelled, and replacement requires a complete scan. See [daily-use implementation, limits and verification](docs/daily-use-implementation.md).

**File → Recovery → Enable Auto Recovery** backs up unsaved buffers every five seconds, enabled by default. Normal close with **Keep Drafts** flushes the final edit and automatically restores it next time. After restore, **File → Revert File…** reloads the original; **Find Recovery Snapshots** also offers restore, discard-and-open-originals, and later. Changed or missing originals recover as untitled buffers. Backup failures cancel closing and preserve edits. See [draft backup and restart recovery](docs/draft-recovery.md), [Markdown and search](docs/document-workspace.md) and [remaining work](docs/product-readiness.md).

The release builds only `Sources/*.swift` and whitelisted Python/JSON resources. Tests, benchmarks, snapshots and test menu diagnostics compile only with `bash build.sh --tests`, into a separate **Source Editor Tests.app**, which declares no document associations. Generated icons come from the original Swift drawing source. Foundation parses Markdown and the system WebKit displays it on demand; no third-party runtime frameworks are bundled.

TextKit lays out visible text on demand. Each document shares its line index and lexical matches across split panes; text edits invalidate these caches at the storage boundary. Only visible syntax matches are painted, and dirty file labels update without recreating every tab. Repeated tab selection now reuses the current editor view, and document-owned display styles avoid redundant full-buffer restyling. A matched multi-file sample reduced its maximum event-loop delay; open/close batches still have measurable stalls. See [performance measurements and remaining costs](docs/presentation-performance.md) and [historical reports](PERFORMANCE.md).

The resource reports cover [optimization principles and measured effects](docs/performance-optimization.md) and [release package size and runtime memory](docs/package-and-memory.md). Both reports are included in the standalone source archives.

For 0.7.0, see [Markdown, search, recovery and resource measurements](docs/document-workspace-performance.md), including WebKit helper attribution and preview timing limits.

This is not a complete Sublime Text replacement. Grammar/snippet engines, full plugin compatibility, LSP, minimap, rectangular selection and project regex/replace remain incomplete. The Python SDK runs selected code with the current user's permissions; it is not a sandbox. Windows currently has a smaller feature set.

For daily development and work notes, see [the detailed gap analysis and acceptance plan](docs/daily-use-gap-analysis.md).

## Tests and source package

```sh
bash tests/run_all.sh                    # Headless production-boundary tests
bash tests/run_all.sh --ui               # Adds native UI checks; requires a GUI session
python3 scripts/export_source.py .build/SourceEditor-source.tar.gz --with-tests
# Optional native performance workloads, in a logged-in macOS GUI session:
python3 tests/run_performance.py local-performance
python3 tests/measure_search.py local-search  # matched replacement vs pinned baseline
```

Results and screenshots stay in `.build/test-results/`. All tests use owned temporary files; native file chooser acceptance, real IME, and complete multi-screen/fullscreen behavior still need manual verification. A Windows build must also be run on Windows; cross-compilation alone does not verify its GUI.
