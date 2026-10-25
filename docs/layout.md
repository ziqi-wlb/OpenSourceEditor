# Layout and Focus Mode (macOS 0.9.3)

[中文](layout.zh-CN.md)

Use **View** to show or hide the sidebar, file tab bar, status bar and line numbers independently. Checked menu items show their current visibility. The command palette also exposes these controls. Encoding, indentation and other menus remain available when the status bar is hidden.

| Action | Entry / shortcut |
| --- | --- |
| Sidebar | View → Toggle Sidebar · ⌃⌘B |
| File tabs | View → Toggle Tab Bar |
| Status controls | View → Toggle Status Bar |
| Line numbers | View → Toggle Line Numbers |
| Native full screen | View → Toggle Full Screen · ⌃⌘F |
| Focus Mode | View → Toggle Focus Mode · ⌥⌘Z |
| Restore from Focus Mode | Escape in source editing, or repeat ⌥⌘Z |

Focus Mode captures the current layout, hides the sidebar, file tabs, status, gutter, Markdown toolbar, search and output, then enters native full screen if needed. Editing fills the available area without empty header/footer slots. Notifications remain available; an explicitly requested search or build can show its own controls. Source editing, selection, undo, shortcuts and context menus retain their normal behavior.

Full screen automatically hides the system menu bar and Dock. Move to the top/bottom screen edge to access them. The system owns their presentation; the editor does not change global macOS preferences. Native workspace tabs are temporarily hidden when present; workspaces are retained. Window animation temporarily disables another fullscreen/focus toggle.

Exit restores the previous visibility and split proportions. If Focus Mode entered full screen, it exits that full screen too; if you entered Focus Mode while already fullscreen, it retains that previous fullscreen state. Native fullscreen exit also restores the focused layout. Escape during marked-text input stays with the IME.

Normal sidebar, tab, status and gutter choices are recorded in workspace metadata and restored on restart. Older workspace files without the new optional keys use visible tabs/status/gutter. While focused, persistence records the original layout and normal window frame; startup does not unexpectedly reopen a hidden fullscreen layout. This metadata does not change text or overwrite source files.

The workspace owns visibility and one transient Focus Mode snapshot. Its frame-layout owner uses zero height for hidden controls, and existing split geometry handles hidden panes. Fullscreen delegate completion/failure callbacks own transitions; no global menu-hiding timer or always-running worker is added. Each pane consumes the workspace's gutter state when created. See [architecture](architecture.md), [workspace behavior](document-workspace.md) and [release notes](../RELEASE_NOTES.md).

Native acceptance includes independent toggles, actual fullscreen entry/exit, menu/Dock presentation options, restored layouts, editor focus and unchanged text. Screenshots and final check counts are recorded with the matching release gate. These checks do not establish cross-Space, multi-monitor, physical Intel or Windows parity.

The final `bilingual-focus-093-verified` gate passed 646 checks with 13 explicit contract skips. Its 79 document-workspace UI checks include the scenarios above; production digests and the Focus Mode screenshot match macOS 0.9.3. Universal slices compiled and the Intel version entry passed under Rosetta. No new runtime memory or latency measurement is claimed.

Preferences → Remember Previous Workspace defaults on and restores folders as well as file tabs. Turning it off starts blank while retaining backups for manual recovery and independent recent folder history. See [workspace restoration](workspace-restoration.md).
