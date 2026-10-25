# Open a file by name or path

[中文](file-location.zh-CN.md)

The macOS editor reuses the **file title at the very top of the window** for path input. Normally it displays the file name and unsaved marker. **Single-click the title** to edit its full path, enter a file name or path, then press **Return** or click **Open**. The editor has no permanent path row; path entry does not reduce its viewport height. **File → Open File by Name or Path…** and **⌥⌘O** focus and select the input. The existing **⌘L** Go to Line shortcut is unchanged.

Accepted input:

| Input | Resolution |
| --- | --- |
| `README.md` | Exact complete name among open files and indexed project files; duplicate names show a chooser with full paths. |
| `src/main.swift` | Relative to the open project folder; without a project, relative to the current saved file's folder. |
| `/tmp/notes.md` | Absolute local file path. |
| `~/Documents/notes.md` | Path under the current user's home directory. |
| `file:///tmp/meeting%20notes.md` | Local file URL, including percent-encoded spaces and Unicode. |

Type paths as text, without shell quotes. Shell variables and expressions are not expanded. Name matching uses the exact spelling; partial searches remain available through **Quick Open (⌘P)**. The existing background project index is reused; the input does not scan the filesystem on every keystroke. Its index limits also apply to name lookup. An explicit path can open a file outside the project index.

Files already open are selected without reloading their buffer, preserving unsaved changes. In a split layout the active pane receives the file and the companion pane retains its view. The input follows active tabs/panes, Save As and the return to home. Project files opened here use the existing sidebar-follow behavior. Missing or invalid paths keep the attempted input available for correction and show a notification; folder paths direct users to Open Folder. File decoding/read errors retain the normal error dialog. No file is created or saved by this input.

**Escape** cancels input and restores the file title and editor focus. Clicking back into the editor also restores the title. The title entry remains available with file tabs hidden and during Markdown preview. Fullscreen/Focus Mode hides the native titlebar; **⌥⌘O** temporarily overlays the same input at the top of the content, and Escape or returning to the editor removes it without changing the editor layout. Dark/light themes and narrow layouts share native AppKit controls.

`FileLocationResolver` owns path parsing, exact-name lookup and candidate deduplication. `FileLocationTitle` owns title/text-entry state, and `FileLocationTitlebarController` owns native titlebar placement and the temporary fullscreen overlay; `EditorWorkspace` routes resolved URLs to the existing document owner and activates the selected pane. The input owns strings, not document references or file storage.

Native acceptance uses isolated files and a separate test application to exercise real single-click title activation, Return/Open, unchanged viewport height, shortcut routing, Unicode/URL paths, duplicate choice, dirty-buffer reuse, invalid input, sidebar following, splits, preview, fullscreen overlay restoration, centered narrow titles, themes and window isolation. This feature is implemented for macOS; Windows parity and new latency/RSS measurements are not claimed. See [development](development.md) and [editor splits](editor-splits.md).
