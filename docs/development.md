# Building, contributing and validation

[中文](development.zh-CN.md)

The application builds independently from `editor/`. Installation and execution do not require investigation data, personal machine paths or another tool workspace.

## macOS

Requires macOS 13+ and Xcode Command Line Tools. Developers install missing tools with `xcode-select --install`; scripts do not install or upgrade toolchains. Python 3 is needed only for extensions and some tests/reports.

Run from `editor/`:

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

For Windows 10/11 x64, install Visual Studio Build Tools with Desktop development with C++ and the Windows SDK. From `editor/` in an x64 developer terminal:

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
python3 scripts/generate_release_notes.py --check
```

Native UI tests require a logged-in macOS desktop. `--ui` includes menus, sheets, tabs, preview, draft close and real restart. Release/test applications are separate. Artifacts/fixtures stay in ignored `.build/`; test bundles do not register user document types.

Performance validation uses [existing workloads](../PERFORMANCE.md) and records elapsed time, CPU, RSS/footprint, main-queue heartbeat and object lifetime. RSS retention alone does not prove leaks; programmatic scrolling is not GPU frame timing. Compare equivalent workloads, documenting cold/warm state, sizes and unmeasured scope.

## Source and documentation distribution

```sh
python3 scripts/export_source.py .build/SourceEditor-source.tar.gz --with-tests
```

Exports include production source, resources, build scripts, tests and bilingual documentation, excluding `.build`, personal paths, proprietary editor binaries, investigation output and Python caches. See [documentation](README.md). The full repository has top-level `CONTRIBUTING.md`; standalone maintenance follows these rules:

1. Documents own text, disk identity and settings. UI consumes these facts rather than reinterpreting encoding or dirty state.
2. Preserve Unicode boundaries, disk conflicts, undo transactions and selections. Validate background document identities/revisions.
3. Windows/applications own their tasks/snapshots. Close waits for owned work; cancellation or failed cleanup retains ownership.
4. Run relevant native UI regressions and capture affected windows. Windows changes need native builds/execution; state missing verification.
5. Update both language versions of features, architecture and related guides. Report executed checks, use Conventional Commits and exclude caches, user files and personal paths.

`Resources/project-information.json` owns author contact and bilingual release history. Run `python3 scripts/generate_release_notes.py` after changing it; `--check` verifies both generated documents. Keep release metadata aligned with `Info.plist`. Application introductions/releases are read offline; contact drafts require an explicit user action.

GitHub Actions is configured for Universal macOS and Windows MSVC builds/encoding checks. Local success does not establish cloud execution. No LICENSE has been selected; the maintainer must select and include one before claiming formal open-source licensing.

Preferences → Remember Previous Workspace defaults on and restores folders as well as file tabs. Turning it off starts blank while retaining backups for manual recovery and independent recent folder history. See [workspace restoration](workspace-restoration.md).
