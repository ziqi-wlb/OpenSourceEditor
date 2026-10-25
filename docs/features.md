# Features and support scope

[中文](features.zh-CN.md)

This matrix describes current source capabilities. macOS 0.9.3 uses Swift/AppKit; Windows x64 is a separate experimental implementation. They do not fully share UI, editing core or extension host. macOS tests do not establish Windows stability or features.

| Everyday capability | macOS | Windows |
| --- | --- | --- |
| Open/save/save-as/save-all | Strict encoding, disk conflicts, atomic replacement | Separate Win32 implementation |
| Tabs/context menus | Copy path/name/relative path, Finder reveal, save/close | Tab/text/tree context menus and Explorer reveal |
| Multiple windows | Native window tabs, detach/merge, active-window menus | No equivalent macOS workspace model |
| Layout and Focus Mode | Hide sidebar/tabs/status/gutter; native fullscreen/menu auto-hide; restore/persist normal layout | No equivalent Focus Mode |
| Text/undo/repeated edits | Native TextKit; selection-preserving transactions | RichEdit; tab changes reset undo history |
| Multi-cursor/next selection/split | Shared document storage | No equivalent implementation |
| Find/replace | Literal/regex, background scans, completeness checks | Literal forward search and F3 |
| Projects | Lazy tree, active-file expand/select/scroll, Quick Open, literal search, create/move/trash, event refresh | Lazy file tree |
| Lines/indentation | Duplicate/delete/move, comments, tab/space conversion/detection | Basic tab/space width |
| Encoding/line endings | Encoding/BOM menus, reopen encoding, LF/CRLF/CR | UTF-8/BOM, UTF-16 LE BOM, LF/CRLF |
| Themes/fonts | Dark/light, size, installed monospace menu/custom font, SF Symbols buttons | Dark/light text appearance; fewer features |
| Markdown reading | Edit/Preview/Side by Side, one-click Outline, direct body, fragment links, HTML export | Not implemented |
| Work notes | Meeting/daily/task templates, formatting, timestamp, list continuation, tasks, image paste | Not implemented |
| Recent files/workspaces | Files, preferences, projects, order, layout and selections | No equivalent session recovery |
| Unsaved drafts | Independent default backups, final close write, restart, discard and changed-original protection | Not implemented |
| Builds/extensions | Selected builds, one-shot Python SDK, cancellation/timeouts | No Python host |
| Introduction/releases | Author email, English/Chinese, offline native release notes | No equivalent native window |
| Distribution | Intel/ARM Universal, user-directory installer, Finder Markdown association | Portable x64 EXE, no association installer |

## Common entry points

| Task | Entry |
| --- | --- |
| Open project folder | File → Open Folder |
| Quick Open | ⌘P |
| Command palette | ⇧⌘P |
| File/project find | ⌘F / ⇧⌘F |
| Save all | File → Save All |
| Restore disk contents | File → Revert File… |
| Retain work for next launch | Close/Quit → Keep Drafts |
| Discover abandoned drafts | File → Recovery → Find Recovery Snapshots |
| Markdown preview/side-by-side | ⇧⌘V / ⌥⌘V |
| Render Markdown | Outline or ⌘B |
| Comment/duplicate/delete lines | ⌘/ / ⇧⌘D / ⇧⌘K |
| Move lines | ⌥↑ / ⌥↓ |
| Toggle task | ⇧⌘Return |
| Fonts/themes | Preferences → Editor Font / Theme; View → Font size |
| Encoding/indentation/syntax/endings | Status controls |
| Introduction/contact/releases | Source Editor → About Source Editor / Contact Author… / Release Notes… |
| Focus / full screen | View → Toggle Focus Mode (⌥⌘Z) / Toggle Full Screen (⌃⌘F) |

See [document workspace](document-workspace.md), [draft recovery](draft-recovery.md), [notes](daily-use-implementation.md) and [extensions](../plugins.md).

## Incomplete support

Full TextMate/Sublime grammars, snippets, LSP completion/diagnostics, rectangular selection, minimap, project regex replacement/dirty-buffer search, Git diff, terminal, Markdown math/Mermaid/PDF, interactive preview tasks, general plugin compatibility, notarization and automatic updates remain incomplete.

Real Chinese/Japanese IME, VoiceOver, prolonged editing, multiscreen/fullscreen/sleep, physical Intel and native Windows GUI need dedicated acceptance. Test success and feature presence do not certify industrial readiness or complete feature parity. See [readiness](product-readiness.md).

Preferences → Remember Previous Workspace defaults on and restores folders as well as file tabs. Turning it off starts blank while retaining backups for manual recovery and independent recent folder history. See [workspace restoration](workspace-restoration.md).

New windows and folder-only projects show a native home with quick actions and recent entries. Close the last file tab to return home. Use the sidebar icons in the project header/titlebar or ⌃⌘B to expand the main area. See [workspace home](workspace-home.md).

macOS 0.9.6 supports left/right and top/bottom editor splits with independent file selectors, cursors and scrolling. Use the titlebar split icon or ⌥⌘2; ⌥⌘3 focuses the other pane and ⌥⌘1 keeps the active single editor. Workspace/session restoration retains pane state. See [editor splits](editor-splits.md).
