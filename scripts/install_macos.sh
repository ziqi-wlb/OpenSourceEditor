#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
editor_arch="${1:-universal}"
if [ "$#" -gt 1 ]; then
    printf '%s\n' 'Usage: bash scripts/install_macos.sh [universal|arm64|x86_64]' >&2
    exit 2
fi
editor_running_count=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); Number($.NSRunningApplication.runningApplicationsWithBundleIdentifier("org.sourceeditor.SourceEditor").count);')
if [ "$editor_running_count" -gt 0 ]; then
    printf '%s\n' 'Save your documents and quit Source Editor before installing an update.' >&2
    exit 1
fi
bash build.sh --arch "$editor_arch"
editor_destination="$HOME/Applications/Source Editor.app"
mkdir -p "$HOME/Applications"
editor_staging=$(mktemp -d "$HOME/Applications/.source-editor-install.XXXXXX")
editor_backup=''
cleanup_install() {
    if [ -n "$editor_backup" ] && [ ! -e "$editor_destination" ]; then
        mv "$editor_backup/Source Editor.app" "$editor_destination"
    fi
    rm -rf "$editor_staging"
}
trap cleanup_install EXIT
ditto '.build/Source Editor.app' "$editor_staging/Source Editor.app"
editor_running_count=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); Number($.NSRunningApplication.runningApplicationsWithBundleIdentifier("org.sourceeditor.SourceEditor").count);')
if [ "$editor_running_count" -gt 0 ]; then
    printf '%s\n' 'Source Editor was opened during compilation. Save and quit it, then run the installer again.' >&2
    exit 1
fi
if [ -e "$editor_destination" ]; then
    editor_existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$editor_destination/Contents/Info.plist")
    if [ "$editor_existing_id" != 'org.sourceeditor.SourceEditor' ]; then
        printf '%s\n' 'Destination belongs to a different application; installation stopped.' >&2
        exit 1
    fi
    mkdir -p .build/install-backups
    editor_backup=$(mktemp -d .build/install-backups/install.XXXXXX)
    mv "$editor_destination" "$editor_backup/Source Editor.app"
    printf 'Previous installation preserved: %s\n' "$editor_backup/Source Editor.app"
fi
mv "$editor_staging/Source Editor.app" "$editor_destination"
editor_lsregister='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
# Register the installed copy; the build output is not an installation.
"$editor_lsregister" -u '.build/Source Editor.app'
"$editor_lsregister" -f "$editor_destination"
"$editor_destination/Contents/MacOS/source-editor" --version
open "$editor_destination"
printf 'Installed and launched: %s\n' "$editor_destination"
