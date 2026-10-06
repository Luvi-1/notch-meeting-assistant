#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64 --arch x86_64
binary_dir="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
app="dist/Notch.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/NotchMeetingAssistant" "$app/Contents/MacOS/NotchMeetingAssistant"
cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
/usr/bin/lipo -verify_arch arm64 x86_64 "$app/Contents/MacOS/NotchMeetingAssistant"
/usr/bin/codesign --force --sign - --identifier com.luvi.notchmeetingassistant "$app"
/usr/bin/codesign --verify --strict "$app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" dist/Notch-Meeting-Assistant.zip
printf 'Built %s\n' "$app"
