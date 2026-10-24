#!/bin/bash
set -eu
cd "$(dirname "$0")"
editor_arch="${1:-universal}"
bash build.sh --arch "$editor_arch"
editor_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' '.build/Source Editor.app/Contents/Info.plist')
editor_archive=".build/SourceEditor-$editor_version-macos-$editor_arch.zip"
ditto -c -k --sequesterRsrc --keepParent '.build/Source Editor.app' "$editor_archive"
printf '%s\n' "Package: $editor_archive"
