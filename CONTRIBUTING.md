# Contributing to OpenSourceEditor

[中文](CONTRIBUTING.zh-CN.md)

Please open an issue or pull request at [OpenSourceEditor](https://github.com/ziqi-wlb/OpenSourceEditor). Bug reports should include app version, OS/architecture, steps, expected/actual behavior and a minimal sample without private content. Distinguish observed failures from untested explanations.

## Development

Build from this repository's root. See [development](docs/development.md) for macOS/Windows toolchains and commands. Use checks matching the change: documentation checks for prose, document/core checks for editing semantics, and affected native UI checks for focus, preview or layout. Broader `--suite full` validation is useful for cross-module changes and releases; report the commands actually run and remaining gaps.

Preserve document-owned text, encoding, paths, dirty state and undo. Validate UTF-16 selections and background identity/revision before applying results. Keep draft backups separate from original files; cancellation and failed writes must retain user content. Native GUI behavior requires native platform execution, including for Windows.

During local application debugging, quit normally and keep drafts before updating an installation. Back up the previous app, install the accepted build and verify version/path/digest. README and build-script changes alone do not require rebuilding or restarting a running editor.

## Pull requests

- Describe the concrete problem, resulting behavior and executed validation.
- Use Conventional Commit subjects such as `fix(editor): preserve selection` or `docs: clarify installation`.
- Update relevant English/Chinese guides together and keep release metadata in `Resources/project-information.json` consistent with `Info.plist`.
- Exclude generated applications, logs, test screenshots, compiler caches, personal paths, credentials and third-party editor binaries. Curated documentation images belong in `docs/images/`.
- Retain evidence of failed checks and explain limitations; do not report a focused pass as complete platform validation.

Performance work should compare equivalent workloads and identify cold/warm conditions, file sizes, time, CPU and memory where relevant. Fewer allocations or a lower RSS snapshot alone do not establish faster editing or leak freedom.
