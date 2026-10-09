#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
BS_BUILD="${BS_BUILD_DIR:-.build}"
BS_APP="${BS_APP_PATH:-$BS_BUILD/Beep Source.app}"
BS_IDENTITY="${BS_SIGN_IDENTITY:-6E99F92E9A1BA1273CD084FAFE940A7280DB0A30}"
mkdir -p "$BS_BUILD" "$BS_APP/Contents/MacOS" "$BS_APP/Contents/Resources"
xcrun clang -O2 -fobjc-arc -target arm64-apple-macos14.2 -c Sources/AudioMeter.m -o "$BS_BUILD/AudioMeter.o"
xcrun swiftc -O -whole-module-optimization -swift-version 5 -target arm64-apple-macos14.2 \
  -import-objc-header Sources/AudioMeter.h Sources/Events.swift Sources/Engine.swift Sources/Store.swift Sources/Interface.swift Sources/App.swift \
  "$BS_BUILD/AudioMeter.o" -framework AppKit -framework SwiftUI -framework CoreAudio -framework ServiceManagement \
  -o "$BS_APP/Contents/MacOS/BeepSource"
rm -rf "$BS_BUILD/AppIcon.iconset"
xcrun swift Tools/Icon.swift "$BS_BUILD/AppIcon.iconset"
iconutil -c icns "$BS_BUILD/AppIcon.iconset" -o "$BS_APP/Contents/Resources/AppIcon.icns"
cp Info.plist "$BS_APP/Contents/Info.plist"
if [ "$BS_IDENTITY" = "-" ]; then
  codesign --force --sign - "$BS_APP"
else
  codesign --force --options runtime --timestamp --sign "$BS_IDENTITY" "$BS_APP"
fi
codesign --verify --strict --verbose=2 "$BS_APP"
printf 'Built and signed: %s\n' "$BS_APP"
