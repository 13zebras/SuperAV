#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/SuperAV.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ICON_SOURCE="$ROOT/speakers-3-colorful.png"
ICONSET="$ROOT/.SuperAV.iconset"

# The Command Line Tools toolchain lacks the SwiftUI macro plugin that
# @State needs, so build with Xcode's toolchain when it's installed.
XCODE_DEVELOPER="/Applications/Xcode.app/Contents/Developer"
if [[ -z "${DEVELOPER_DIR:-}" && -d "$XCODE_DEVELOPER" ]]; then
  export DEVELOPER_DIR="$XCODE_DEVELOPER"
fi

# Compile before touching the existing bundle so a failed build leaves the
# last working app in place.
BUILD_BINARY="$ROOT/.SuperAV.build"
swiftc \
  -parse-as-library \
  -target arm64-apple-macosx26.0 \
  -framework SwiftUI \
  -framework CoreAudio \
  -framework AudioToolbox \
  -framework Cocoa \
  -framework CoreGraphics \
  -framework IOKit \
  "$ROOT/SuperAVApp.swift" \
  "$ROOT/AudioBalance.swift" \
  "$ROOT/SoundSourceWorkflow.swift" \
  "$ROOT/DisplayBrightness.swift" \
  -o "$BUILD_BINARY"

rm -rf "$APP" "$ICONSET"
mkdir -p "$MACOS" "$RESOURCES" "$ICONSET"

if [[ ! -f "$ICON_SOURCE" ]]; then
  printf 'Missing icon source: %s\n' "$ICON_SOURCE" >&2
  exit 1
fi

make_icon() {
  local size="$1"
  local name="$2"
  sips --resampleHeightWidth "$size" "$size" "$ICON_SOURCE" \
    --out "$ICONSET/$name" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png
iconutil --convert icns "$ICONSET" --output "$RESOURCES/SuperAV.icns"
rm -rf "$ICONSET"

mv "$BUILD_BINARY" "$MACOS/SuperAV"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>SuperAV</string>
    <key>CFBundleIdentifier</key>
    <string>local.superav</string>
    <key>CFBundleIconFile</key>
    <string>SuperAV.icns</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>SuperAV</string>
    <key>CFBundleDisplayName</key>
    <string>SuperAV</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>SuperAV adjusts system volume and quits or restarts SoundSource using AppleScript.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
