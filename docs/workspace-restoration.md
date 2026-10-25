# Remembering the previous workspace (macOS 0.9.4)

[中文](workspace-restoration.zh-CN.md)

**Preferences → Remember Previous Workspace** is enabled by default. Normal startup restores the previous folders, saved file tabs, selections, Markdown view and normal window layout. A folder-only window also restores. The sidebar retains expanded folders, its selected item and scroll position. Closing the last window then reopening from the Dock restores the last closed workspace; File → New Window remains a fresh window.

| Setting or action | Behavior |
| --- | --- |
| Remember Previous Workspace on | Restore saved open windows; if all were closed, restore the last closed workspace |
| Remember Previous Workspace off | Clear ordinary restoration metadata and start blank next time |
| File → Reopen Last Folder | Open the latest successfully opened folder, independently of the setting |
| File → Open Recent Folders | Choose from up to 20 recent folders, or clear folder history |
| Startup with explicit files/folder | Open the supplied inputs; previous workspaces are available through history/recovery |
| Close/Quit → Keep Drafts | Keep final unfinished text in independent backups without overwriting originals |

The setting is also available in the command palette and when all editor windows are closed. Its canonical preferences key is `"remember_workspace": true`. Older preferences without the key default to enabled. Files and folders have separate recent histories. An unavailable recent folder reports a notice and leaves the current project intact.

Turning the setting off prevents automatic reopening of both workspaces and retained drafts. It **does not delete draft backups or recent folder history**. Use File → Recovery → Find Recovery Snapshots to review them. Periodic recovery is a separate setting; Keep Drafts captures final edits even if periodic recovery is disabled. Save and Revert retain their existing explicit semantics. See [draft recovery](draft-recovery.md).

`EditorAppDelegate` owns parsed desktop state, the setting and recent folder actions. `SavedDesktop.workspaces` describes open windows; optional `lastClosedWorkspace` retains the last closed one. This separate field prevents final-window close from erasing the project. Open windows take precedence, so a normally closed clean window does not reappear beside windows that remained open. Explicitly retained drafts remain recoverable.

`EditorWorkspace` owns project-relative sidebar state and presentation restoration. Expansion loads only recorded visible ancestors through the existing lazy tree. Draft restoration rebuilds document panes and the tree, then reapplies presentation without reopening source files. No extra timer or background worker is added. Desktop JSON is bounded to 1 MiB, 32 open windows and 256 saved file tabs; the last closed window has its own 256-tab bound. Validation rejects invalid relative paths and nonfinite geometry. Existing optional-field decoding, atomic replacement and `.previous` backup behavior are retained.

The UI gate exercises real menu actions, folder-only close/Dock reopen, Unicode expansion, hidden controls, explicit inputs, missing folders and multi-window precedence. `tests/workspace_restart_test.py` launches separate AppKit processes for final-window close, normal Keep Drafts quit and disabled restoration. It checks layout, drafts and unchanged original bytes with temporary support directories. This establishes the tested macOS behavior; undo history, physical Intel GUI, Windows parity and power-loss durability are outside these checks. No new latency or memory measurements are claimed.

See [development](development.md), [architecture](architecture.md), [layout](layout.md) and [release notes](../RELEASE_NOTES.md).

The final `workspace-094-final` gate passed 708 checks with 13 explicit contract skips, including 20 native workspace and 32 separate-process checks. The accepted Universal release and source hashes match macOS 0.9.4; the restored-workspace image is captured from the native content view.

New windows and folder-only projects show a native home with quick actions and recent entries. Close the last file tab to return home. Use the sidebar icons in the project header/titlebar or ⌃⌘B to expand the main area. See [workspace home](workspace-home.md).
