#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
swift build -c "$configuration"
bin_path="$(swift build -c "$configuration" --show-bin-path)"
app_path="$PWD/build/Paint.MAC.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_path/PaintMac" "$app_path/Contents/MacOS/PaintMac"
cp scripts/Info.plist "$app_path/Contents/Info.plist"
swift scripts/make-icon.swift build/AppIcon.iconset
if [ -d build/AppIcon.iconset ]; then
    iconutil -c icns build/AppIcon.iconset -o "$app_path/Contents/Resources/AppIcon.icns"
fi
codesign --force --deep --sign - "$app_path"
echo "$app_path"
