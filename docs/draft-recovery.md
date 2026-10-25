# Draft backups and restart recovery (macOS 0.9.0+)

[中文](draft-recovery.zh-CN.md)

Automatic backups go to the application's recovery directory and **do not overwrite original files**. Only explicit Save/Save All writes source files. Workspace metadata records saved files, projects and layouts; independent drafts own unsaved text.

## Everyday use

| Action | Result |
| --- | --- |
| Default editing | Recovery is enabled; every 5 seconds checks unsaved documents and writes text, encoding, indentation and selections to independent JSON |
| Close/Quit → Keep Drafts | Capture final edits, wait for writing, then close; originals remain unchanged |
| Next normal launch (workspace restoration enabled) | Restore retained drafts, untitled notes and saved tabs, without requiring notes to be named first |
| Dock reopen after last window closes (workspace restoration enabled) | Restore the last closed folder, layout and retained drafts; File → New Window creates a fresh workspace |
| Close → Save All | Save files; untitled files use a chooser; cancellation/failure cancels close |
| Close → Discard Drafts | Delete this workspace's recovery data without writing originals; next launch reads disk files |
| Close → Cancel | Keep the editor and its buffers editable |
| Recovery → File → Revert File… | Confirm discard, reload disk and remove that file's draft content |
| File → Recovery → Find Recovery Snapshots | Restore Drafts, Discard Drafts and Open Originals, or Later; Later retains the backup |
| Close one tab | Existing Save / Don't Save / Cancel semantics; Don't Save explicitly discards that tab and updates recovery |

Keep Drafts also works with periodic recovery disabled. Disabling periodic recovery cleans that window's automatic snapshot; retain current work using Keep Drafts or manual Save Session.

## Storage and ownership

The default is `~/Library/Application Support/Source Editor/Recovery/`, with one randomly named JSON per workspace. Directory permissions are `0700`, snapshots `0600`. Preferences/workspace metadata live one level above and retain `.previous`; JSON replacement is atomic.

`EditorRecovery` owns a serial background queue. Requests arriving during a write coalesce into the latest pending state. Close stops the timer, freezes editing and captures the final snapshot, replacing a periodic request that has not started. It waits for an active write before persisting. Final completion deregisters the live snapshot; the app waits for all windows before quitting. Retain/delete use the same queue, preventing an old write from resurrecting discarded data.

Optional `EditorSession.closedNormally` distinguishes explicitly retained normal-close drafts from abnormal-exit snapshots. Startup restores the former; notices/Recovery offer the latter for user selection. Optional workspace metadata carries project/tab/display state; older sessions remain readable. `SavedWorkspace.recoveryFileName` permits one JSON filename linking the workspace and independent draft.

Recovery checks originals' SHA-256. Unchanged originals retain paths and unsaved status; changed/missing originals become untitled documents. Recovered text is backed up to a new owned file before deleting the old owned backup. Imported external sessions retain their original bytes; subsequent automatic backups use the owned recovery directory, not the imported file's parent.

Discard-and-open-originals reads every named source first. Read failure retains the backup and reports an error. Untitled drafts have no original and their content is discarded. Corrupt backups are retained. Write failure cancels close, enables editing and retains ownership for retry.

## Limits

- Per window: at most 128 modified documents, 4 Mi UTF-16 units combined, and 32 MiB encoded session. Clean large files are not copied into drafts.
- Capacity/write errors notify and preserve the previous successful snapshot. Close cannot treat it as final; choose Save All, manual Save Session or explicit discard.
- The 5-second interval leaves a crash-recovery gap. Normal close writes final state; atomic replacement is not a power-loss hardware durability guarantee.
- Text, selections, encoding and settings recover. Native undo history is not persisted across processes.
- This is a macOS feature; Windows does not have equivalent draft quit/restart recovery.

## Validation

```sh
bash tests/run_all.sh draft-recovery --ui --arch universal
python3 tests/recovery_restart_test.py '.build/Source Editor Tests.app/Contents/MacOS/source-editor'
```

`DraftRecoveryUITests` uses real windows/sheets and isolated support directories to cover final edits, untitled documents, normal recovery, cancellation, Revert, discard, external changes, corruption, disk failure and retry. Python starts a real AppKit process, quits through `NSApplication.terminate`, then verifies two windows' text, clean tabs, selections and untouched originals in a new process. Abrupt-exit tests remain.

Logs stay in `.build/test-results/`. Universal compiles Intel/Apple Silicon slices; GUI tests here run on Apple Silicon, not physical Intel or Windows.

Historical 0.9.0 `draft-final` passed 598 checks with 13 explicit skips, including 23 draft/font UI and 15 real normal quit/restart checks. See [resource report](release-090-performance.md). In 0.9.1, imported external sessions remain unchanged; native checks verify exact source bytes while automatic backups use owned storage.

Preferences → Remember Previous Workspace defaults on and restores folders as well as file tabs. Turning it off starts blank while retaining backups for manual recovery and independent recent folder history. See [workspace restoration](workspace-restoration.md).
