#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
swift build --package-path "$project_dir" -c release
binary_dir="$(swift build --package-path "$project_dir" -c release --show-bin-path)"
app_dir="$project_dir/build/StreamDrop.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/StreamDrop" "$app_dir/Contents/MacOS/StreamDrop"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
swift "$project_dir/Resources/Icon.swift" "$project_dir/build/AppIcon.iconset"
iconutil -c icns "$project_dir/build/AppIcon.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
printf 'App ready: %s\n' "$app_dir"
