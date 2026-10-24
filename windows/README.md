# Native Windows editor (experimental)

[中文](README.zh-CN.md)

Uses C++17, Win32 and the system RichEdit control. The produced x64 EXE requires no Python, Node or third-party GUI framework. Windows 10/11 is the intended target; native GUI execution remains to be verified.

## Build and install

Install Visual Studio Build Tools with **Desktop development with C++**, including a Windows SDK. Open **x64 Native Tools Command Prompt for Visual Studio**, enter the repository directory, then:

```powershell
powershell -ExecutionPolicy Bypass -File editor/windows/build.ps1
```

The result is `editor/windows/.build/SourceEditor.exe`. Copy it into any directory and run it. This is a portable program, without registry registration, an installer, file associations or a background service. Windows may ask for normal confirmation because the EXE is unsigned.

For cross-compilation with an explicitly installed Zig 0.13.0:

```sh
ZIG_BIN=/path/to/zig bash editor/windows/build.sh
```

The script does not download a compiler. GitHub Actions also has a Windows/MSVC build job. A PE binary and correct imports establish a build result; actual Windows execution and GUI checks are separate.

## Current scope

Includes Unicode text editing, file tabs, lazy folder-tree expansion, literal forward search (F3), save/save-as/save-all, external-disk-conflict protection and atomic replacement, UTF-8/UTF-8 BOM/UTF-16 LE BOM, LF/CRLF, tab/space width controls and dark/light text appearance. Right-click file tabs for path/name/relative-path copying, Explorer reveal, saving and closing other/right tabs; text and project rows also have context menus. Right-click the status bar to choose encoding, line endings and indentation.

It does not yet have macOS multi-cursor, regex replacement, split views, session restore, syntax highlighting, Python extensions or full settings parity. Undo history currently resets when changing tabs. RichEdit/Win32 UI, long paths, IME, high-DPI, clipboard and file-dialog acceptance need native platform validation before treating it as a stable release.
