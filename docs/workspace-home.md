# Workspace home and sidebar controls (macOS 0.9.5)

[中文](workspace-home.zh-CN.md)

New windows and folder-only workspaces open on a native home page. Opening a folder does not create an empty Untitled file. Select a file in the sidebar, use a recent entry, or choose a quick action to start. Closing the final file tab returns home; New File (`⌘N`) explicitly creates an editing buffer. Opening another folder while files are open preserves those files and the current editor.

| Home action | Result |
| --- | --- |
| New File | Create one untitled file and focus source editing |
| Open File… | Use the normal file chooser and document-opening workflow |
| Open Folder… | Choose a project folder; keep home if no files are open |
| Markdown Note | Create a Markdown document with the existing preview and note tools |
| Quick Open | Find a file in the current project (`⌘P`) |
| Find in Folder… | Open project content search (`⇧⌘F`) |
| Recent Files / Recent Folders | Open one of the five most recent entries in each category |

Project-only actions are disabled before choosing a folder. File menus retain the complete recent histories. Home displays the project name, supports dark/light themes, and switches from two columns to one at narrow widths. Vertical scrolling keeps all actions and histories reachable in small windows. Encoding, indentation and syntax controls appear when a real document is selected. Home itself has no document text, dirty flag, save prompt or draft; Save Session is unavailable until a document exists.

Click the sidebar icon beside the project heading to hide the directory. The matching icon in the window titlebar remains available to show it again. Both use the existing **View → Toggle Sidebar** action and **⌃⌘B** shortcut. Hidden sidebar space is returned to the main page; the titlebar icon remains available when file tabs or the status bar are hidden. Native fullscreen owns titlebar presentation; move to the top edge to access window controls. Visibility still follows [workspace restoration](workspace-restoration.md).

`EditorWorkspace.documents` contains only actual documents. Its empty state presents `WorkspaceHomeView` and releases editing panes and any Markdown preview. The home uses AppKit labels, SF Symbols, buttons and a scroll view; it creates no WebKit instance or new timer. A typed presentation key covers project identity, the bounded recent lists and theme, avoiding redundant rebuilds. The application owns recent history, and the workspace owns actions, file choosing and focus. Buttons reuse existing workflows instead of interpreting file paths or writing files independently.

Native checks cover folder launch, explicit new/open/note actions, recent entries, menu behavior, button-driven sidebar hiding/restoration, expanded main width, hidden editor chrome, themes, narrow scrolling and restart. Successful chooser selection uses an injected URL fixture, then the production open path; native successful picker selection remains a separate manual acceptance item. Original fixture bytes are checked. Screenshots are captured from native content views under the matching `.build/test-results/` directory. Physical Intel GUI and Windows parity are not established by these checks; no new memory or latency comparison is claimed.

See [layout](layout.md), [development](development.md), [architecture](architecture.md) and [release notes](../RELEASE_NOTES.md).

The final `home-sidebar-095-verified` gate passed **741 checks with 13 explicit contract skips**, including 33 home UI checks and 32 separate-process workspace checks. Both Universal slices compiled and the x86_64 version entry passed under Rosetta; GUI checks ran on Apple Silicon. All 25 bilingual guide pairs passed. UI fixtures establish their viewport and restore the narrow probe's frame to avoid shared native frame-autosave interference. The accepted binary and source digests are retained with the gate.
