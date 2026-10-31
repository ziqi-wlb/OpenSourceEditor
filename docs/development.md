# Building, contributing and validation

[中文](development.zh-CN.md)

The application builds independently from the repository root. Installation and execution do not require investigation data, personal machine paths or another tool workspace.

## macOS

Requires macOS 13+ and Xcode Command Line Tools. Developers install missing tools with `xcode-select --install`; scripts do not install or upgrade toolchains. Python 3 is needed only for extensions and some tests/reports.

In the parent checkout, first run `cd editor`. In the standalone OpenSourceEditor checkout or exported source archive, start at its root. The commands below run from the application directory:

```sh
bash build.sh --arch universal
open '.build/Source Editor.app'
bash scripts/install_macos.sh universal
bash package.sh universal
```

Use `--arch arm64` or `--arch x86_64` for one architecture. Universal contains two compiled slices; native GUI behavior still needs corresponding hardware validation. The installer refuses running instances, preserves the previous installation, installs to `~/Applications/Source Editor.app`, registers Launch Services and launches. Finder Open With offers Markdown/text associations without changing the default editor.

Current builds are unsigned and unnotarized. Use the normal Finder Open approval flow for downloads; scripts do not disable system security.

## Delivering a local debug build

Each completed editor debugging or feature iteration ends with local installation and a launch check. A successful build or test does not update an already running installed copy.

1. Build and run the checks relevant to the change. Keep the accepted executable and its digest with the results.
2. Quit the installed application normally. Use Keep Drafts for unfinished edits; preserve originals, and wait for owned work to finish. Never force-quit or discard content for an update.
3. Back up the previous installation, install the accepted build, register Launch Services and launch the installed copy. The installer refuses to replace a running application.
4. Verify the installed version, running bundle path and executable digest against the accepted artifact, and confirm one production instance. Save this evidence under the matching `.build/test-results/` run before reporting the fix complete.

Routine local installation and normal restart are part of the development workflow. If a save dialog or other user decision prevents safe shutdown, retain the validated build and report the remaining step explicitly.

## Windows

For Windows 10/11 x64, install Visual Studio Build Tools with Desktop development with C++ and the Windows SDK. From the application directory in an x64 developer terminal:

```powershell
powershell -ExecutionPolicy Bypass -File windows/build.ps1
```

Copy/run `windows/.build/SourceEditor.exe`. This is a portable application, with no registry installer or document associations. An installed Zig 0.13.0 can cross-build as described in [Windows](../windows/README.md); cross-building does not validate Windows GUI execution.

## Tests

```sh
bash tests/run_all.sh local-check --arch universal
bash tests/run_all.sh local-ui --ui --arch universal
python3 tests/recovery_restart_test.py '.build/Source Editor Tests.app/Contents/MacOS/source-editor'
python3 tests/workspace_restart_test.py '.build/Source Editor Tests.app/Contents/MacOS/source-editor'
python3 tests/check_portability.py
python3 tests/check_documentation.py
python3 tests/run_tests.py typing-0910-recheck --suite typing --ui --arch universal --build-timeout 420
python3 scripts/generate_release_notes.py --check
```

Native UI tests require a logged-in macOS desktop. `--ui` includes menus, sheets, tabs, preview, draft close and real restart. Release/test applications are separate. Artifacts/fixtures stay in ignored `.build/`; test bundles do not register user document types.

Performance validation uses [existing workloads](../PERFORMANCE.md) and records elapsed time, CPU, RSS/footprint, main-queue heartbeat and object lifetime. RSS retention alone does not prove leaks; programmatic scrolling is not GPU frame timing. Compare equivalent workloads, documenting cold/warm state, sizes and unmeasured scope.

## Source and documentation distribution

```sh
python3 scripts/export_source.py .build/SourceEditor-source.tar.gz --with-tests
```

Exports include production source, resources, build scripts, tests and bilingual documentation, excluding `.build`, personal paths, proprietary editor binaries, investigation output and Python caches. See [documentation](README.md). See [contribution guidelines](../CONTRIBUTING.md). Standalone maintenance follows these rules:

1. Documents own text, disk identity and settings. UI consumes these facts rather than reinterpreting encoding or dirty state.
2. Preserve Unicode boundaries, disk conflicts, undo transactions and selections. Validate background document identities/revisions.
3. Windows/applications own their tasks/snapshots. Close waits for owned work; cancellation or failed cleanup retains ownership.
4. Run relevant native UI regressions and capture affected windows. Windows changes need native builds/execution; state missing verification.
5. Update both language versions of features, architecture and related guides. Report executed checks, use Conventional Commits and exclude caches, user files and personal paths.

`Resources/project-information.json` owns author contact and bilingual release history. Run `python3 scripts/generate_release_notes.py` after changing it; `--check` verifies both generated documents. Keep release metadata aligned with `Info.plist`. Application introductions/releases are read offline; contact drafts require an explicit user action.

GitHub Actions is configured for Universal macOS and Windows MSVC builds/encoding checks. Local success does not establish cloud execution. No LICENSE has been selected; the maintainer must select and include one before claiming formal open-source licensing.

The parent and standalone workflows retain macOS validation logs/results and Windows compiler logs on both success and failure and set finite platform job deadlines. Windows compiler output also stays in `windows/.build/*-build.log`; SDK headers are included with `NOMINMAX` to preserve standard-library calls. Cloud checks are headless; native UI acceptance needs a logged-in desktop. See [current gaps and priorities](current-gap-analysis.md) for current-version evidence, remaining acceptance and implementation order.

The independent GitHub checkout uses this directory as its root. Historical reports may cite commits from the earlier parent repository; subtree extraction changes commit IDs. For the optional historical search benchmark, pass an applicable `--baseline-ref` or supply `--baseline-file` explicitly. The application and ordinary checks do not need that historical baseline.

Preferences → Remember Previous Workspace defaults on and restores folders as well as file tabs. Turning it off starts blank while retaining backups for manual recovery and independent recent folder history. See [workspace restoration](workspace-restoration.md).

New windows and folder-only projects show a native home with quick actions and recent entries. Close the last file tab to return home. Use the sidebar icons in the project header/titlebar or ⌃⌘B to expand the main area. See [workspace home](workspace-home.md).

macOS 0.9.6 supports left/right and top/bottom editor splits with independent file selectors, cursors and scrolling. Use the titlebar split icon or ⌥⌘2; ⌥⌘3 focuses the other pane and ⌥⌘1 keeps the active single editor. Workspace/session restoration retains pane state. See [editor splits](editor-splits.md).

macOS 0.9.9 reuses the top window title for transient file-path input, removing the permanent editor row. Single-click the title or use ⌥⌘O; Return/Open opens and Escape restores the title. Fullscreen uses the same input as a temporary overlay without shrinking the editor. See [file title and path input](file-location.md). Native checks include actual title clicks, unchanged editor height, preview, home, splits and Focus Mode; acceptance belongs to the current run.

Image acceptance additionally runs `--image-ui-test=` and separate-process image restart checks. Fixtures, decode/cancellation results and screenshots remain under the matching run; the unchanged production source digests identify the accepted package. See [image preview](image-preview.md).

Use checks matching the changed behavior during development. `--suite typing` runs document/core edits and native typing/splits, omitting unrelated runtime suites; `--suite full` is available for cross-module or release verification. `--typing-ui-test=` checks long-list Return, scrolling, undo and text colors. `--build-timeout` adjusts compiler deadlines on busy hosts without changing runtime-check deadlines. See [editing stability](typing-stability.md).
