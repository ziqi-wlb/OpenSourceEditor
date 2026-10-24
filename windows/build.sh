#!/bin/bash
set -eu
cd "$(dirname "$0")"
editor_zig="${ZIG_BIN:-zig}"
mkdir -p .build
editor_name=SourceEditor
editor_options=(-std=c++17)
if [ "${1:-}" = --tests ]; then
    editor_name=SourceEditorTests
    editor_options+=(-D EDITOR_TESTS)
fi
"$editor_zig" c++ "${editor_options[@]}" -O2 -s -DNDEBUG -target x86_64-windows-gnu -municode -Wl,--subsystem,windows main.cpp -o ".build/$editor_name.exe" -lcomctl32 -lcomdlg32 -lshell32 -lole32 -luuid -lgdi32
printf '%s\n' "Built: .build/$editor_name.exe (Windows x64)"
