# Editor splits (macOS 0.9.6)

[中文](editor-splits.zh-CN.md)

Click the split icon in the window titlebar or use **View → Split Editor** (`⌥⌘2`) to show the current file in two editors. **Split Right** uses columns; **Split Down** uses rows. Drag the divider to change their proportions. Each editor has its own selection and scroll position. Edits and undo share the document when both views show the same file.

The split toolbar provides a file selector for each side and buttons for orientation and **Single Pane**. Choose an open file independently in each selector. Clicking an editor makes it active; the global file tabs, project sidebar, Save, Find and document settings follow that editor. Opening a file or selecting a global file tab replaces only the active pane. **View → Open in Other Pane** selects the next open file in the other pane, creating a split if necessary. With one open file it shows that file in both panes.

| Action | Entry |
| --- | --- |
| Toggle split / single editor | Titlebar icon or `⌥⌘2` |
| Left / right editors | View → Split Right, file-tab context menu, or split toolbar |
| Top / bottom editors | View → Split Down, file-tab context menu, or split toolbar |
| Focus the other editor | Click its text or `⌥⌘3` |
| Return to one editor | Single Pane button or `⌥⌘1` |
| Open another existing file beside the active file | View → Open in Other Pane |

Single Pane retains the active editor, its cursor and the open document list; it does not save or close files. Closing a file removes its document from both views. The retained document replaces a removed pane's file, and closing the final document returns to the workspace home. Split controls are disabled on home. The toolbar adapts to narrow windows and follows dark/light themes; Focus Mode hides it with the other editor chrome. Markdown full preview renders the active file across the content area. Returning to Edit restores the split source views; creating/changing a split selects source editing.

When Remember Previous Workspace is enabled, restored workspaces include split direction, proportions, active side, pane files, selections and scroll positions. Save Session and draft recovery also retain pane state, including unsaved documents. Existing session/workspace JSON remains readable: the original `split` flag without optional layout metadata opens two views of the selected file. Unavailable files follow the existing missing-file and draft-recovery rules.

`EditorWorkspace` owns the active document, companion document and split geometry. Each `EditorPane` owns a TextKit layout manager and viewport; the document owns storage, undo and disk identity. Focus updates the active document at one boundary, so menus and settings use the same owner as editing. Unchanged panes are reused when the other pane's file or split orientation changes. Collapsing removes the inactive layout manager without copying text. The native toolbar holds only bounded file choices; it adds no worker or timer. `SavedEditorLayout` is shared by session and desktop serialization, validates two panes and finite geometry, and keeps document indices separate from file paths for draft recovery.

Native acceptance exercises titlebar/menu/toolbar actions, two different files, shared-file typing and undo, independent scrolling, active-pane routing, cursor/view preservation, actual divider dragging, narrow layouts, theme changes, JSON session/workspace restoration, malformed metadata, resource release and final-tab home. Automated checks use their own files and an isolated test bundle. Physical Intel GUI and Windows parity remain unverified; this iteration does not claim a new memory or latency benchmark.

File selectors refresh their document references even while the split toolbar is hidden, and clear them when splitting ends. Closing the final file releases its document while the workspace home stays open. A weak-reference lifecycle check covers this ownership rule; it does not quantify process RSS.

See [workspace home](workspace-home.md), [layout](layout.md), [workspace restoration](workspace-restoration.md), [architecture](architecture.md) and [development](development.md).

The final `editor-splits-096-verified` acceptance passed **795 checks with 13 explicit contract skips**, including 43 split UI and 11 separate-process restoration checks. One synthetic divider-drag failure was retained and not reproduced in two subsequent runs; remaining acceptance continued with identical release/test binaries and frozen production-source digests. Universal slices and the Rosetta Intel version entry passed; native GUI ran on Apple Silicon. All 26 bilingual guide pairs passed.
