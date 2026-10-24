#!/bin/bash
set -eu
cd "$(dirname "$0")"
editor_bundle='.build/Source Editor.app'
editor_sources=(Sources/*.swift)
editor_flags=(-O)
editor_testing=false
editor_arch="$(uname -m)"
while [ "$#" -gt 0 ]; do
case "$1" in
    --tests)
        editor_bundle='.build/Source Editor Tests.app'
        editor_testing=true
        editor_sources+=(tests/Swift/*.swift)
        editor_flags+=(-D EDITOR_TESTS)
        ;;
    --arch)
        shift
        editor_arch="${1:?--arch requires arm64, x86_64 or universal}"
        ;;
    *) printf '%s\n' 'Usage: bash build.sh [--tests] [--arch arm64|x86_64|universal]' >&2; exit 2 ;;
esac
shift
done
mkdir -p "$editor_bundle/Contents/MacOS" .build/icons
case "$editor_arch" in
    arm64|x86_64) editor_arches=("$editor_arch") ;;
    universal) editor_arches=(arm64 x86_64) ;;
    *) printf '%s\n' 'Architecture must be arm64, x86_64 or universal.' >&2; exit 2 ;;
esac
editor_outputs=()
for editor_cpu in "${editor_arches[@]}"; do
    editor_output=".build/source-editor-$editor_cpu"
    xcrun swiftc "${editor_flags[@]}" -target "${editor_cpu}-apple-macosx13.0" "${editor_sources[@]}" -o "$editor_output" -framework AppKit -framework CryptoKit
    editor_outputs+=("$editor_output")
done
# Replace the executable inode. Overwriting a running Mach-O can leave macOS
# using its previous cached code signature and cause a SIGKILL on the next run.
rm -f "$editor_bundle/Contents/MacOS/source-editor"
if [ "${#editor_outputs[@]}" -gt 1 ]; then
    xcrun lipo -create "${editor_outputs[@]}" -output "$editor_bundle/Contents/MacOS/source-editor"
else
    cp "${editor_outputs[0]}" "$editor_bundle/Contents/MacOS/source-editor"
fi
cp Info.plist "$editor_bundle/Contents/Info.plist"
if [ "$editor_testing" = true ]; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier org.sourceeditor.SourceEditor.tests' "$editor_bundle/Contents/Info.plist"
fi
# Rebuild this owned resource directory from supported source files only.
rm -rf "$editor_bundle/Contents/Resources"
mkdir -p "$editor_bundle/Contents/Resources"
while IFS= read -r -d '' editor_resource; do
    editor_relative="${editor_resource#Resources/}"
    mkdir -p "$editor_bundle/Contents/Resources/$(dirname "$editor_relative")"
    cp "$editor_resource" "$editor_bundle/Contents/Resources/$editor_relative"
done < <(find Resources -type f \( -name '*.py' -o -name '*.json' \) -print0)
if [ ! -f .build/icons/SourceEditor.icns ] || [ scripts/generate_icon.swift -nt .build/icons/SourceEditor.icns ]; then
    xcrun swift scripts/generate_icon.swift .build/icons/SourceEditor.iconset
    iconutil -c icns -o .build/icons/SourceEditor.icns .build/icons/SourceEditor.iconset
fi
cp .build/icons/SourceEditor.icns "$editor_bundle/Contents/Resources/SourceEditor.icns"
printf '%s\n' "Built: $editor_bundle"
