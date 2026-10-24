# Source Editor

An independently implemented macOS text editor. Build and run this directory on its own: no Sublime Text installation, REA, npm, network, or investigation files are required. The native Windows implementation is in [windows](windows/README.md).

## Build and install on macOS

Requires macOS 13 or later and Xcode Command Line Tools (`xcode-select --install`). Python 3 is optional for extensions. From this directory:

```sh
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

The release builds only `Sources/*.swift` and whitelisted Python/JSON resources. Tests, benchmarks, snapshots and test menu diagnostics compile only with `bash build.sh --tests`, into a separate **Source Editor Tests.app**. Generated icons come from the original Swift drawing source. No third-party runtime frameworks are bundled.

TextKit lays out visible text on demand. Each document shares its line index and lexical matches across split panes; text edits invalidate these caches at the storage boundary. Only visible syntax matches are painted, and dirty file labels update without recreating every tab. See [performance measurements and remaining costs](PERFORMANCE.md).

The resource reports cover [optimization principles and measured effects](docs/performance-optimization.md) and [release package size and runtime memory](docs/package-and-memory.md). Both reports are included in the standalone source archives.

This is not a complete Sublime Text replacement. Grammar/snippet engines, full plugin compatibility, LSP, minimap, rectangular selection and project-wide search remain incomplete. The Python SDK runs selected code with the current user's permissions; it is not a sandbox. Windows currently has a smaller feature set.

## Tests and source package

```sh
bash tests/run_all.sh                    # Headless production-boundary tests
bash tests/run_all.sh --ui               # Adds native UI checks; requires a GUI session
python3 scripts/export_source.py .build/SourceEditor-source.tar.gz --with-tests
# Optional native performance workloads, in a logged-in macOS GUI session:
python3 tests/run_performance.py local-performance
```

Results and screenshots stay in `.build/test-results/`. All tests use owned temporary files; native file chooser acceptance, real IME, and complete multi-screen/fullscreen behavior still need manual verification. A Windows build must also be run on Windows; cross-compilation alone does not verify its GUI.
