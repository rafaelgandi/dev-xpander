#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_FILE="$ROOT_DIR/Devxpander.swift"
APP_BUNDLE="$ROOT_DIR/Devxpander.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RES_DIR="$CONTENTS_DIR/Resources"
BINARY_OUT="$MACOS_DIR/Devxpander"

if [[ ! -f "$SWIFT_FILE" ]]; then
    echo "Missing Swift source at: $SWIFT_FILE"
    exit 1
fi

APP_ICON_PNG="$ROOT_DIR/app.png"
if [[ ! -f "$APP_ICON_PNG" ]]; then
    echo "Missing app.png at $APP_ICON_PNG (Finder / Dock icns source)."
    exit 1
fi

echo "Creating app bundle structure..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
mkdir -p "$RES_DIR"

cat > "$CONTENTS_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Devxpander</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.raffy.devxpander</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Devxpander</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "Compiling Devxpander..."
swiftc \
    "$SWIFT_FILE" \
    -o "$BINARY_OUT" \
    -framework Cocoa \
    -framework SwiftUI \
    -framework WebKit \
    -framework ApplicationServices

chmod +x "$BINARY_OUT"

ICONSET_TMP="$ROOT_DIR/build/AppIcon.iconset"
rm -rf "$ICONSET_TMP"
mkdir -p "$ICONSET_TMP"

echo "Building AppIcon.icns from app.png..."
sips -z 16 16 "$APP_ICON_PNG" --out "$ICONSET_TMP/icon_16x16.png"
sips -z 32 32 "$APP_ICON_PNG" --out "$ICONSET_TMP/icon_16x16@2x.png"
sips -z 32 32 "$APP_ICON_PNG" --out "$ICONSET_TMP/icon_32x32.png"
sips -z 64 64 "$APP_ICON_PNG" --out "$ICONSET_TMP/icon_32x32@2x.png"
sips -z 128 128 "$APP_ICON_PNG" --out "$ICONSET_TMP/icon_128x128.png"
sips -z 256 256 "$APP_ICON_PNG" --out "$ICONSET_TMP/icon_128x128@2x.png"
sips -z 256 256 "$APP_ICON_PNG" --out "$ICONSET_TMP/icon_256x256.png"
sips -z 512 512 "$APP_ICON_PNG" --out "$ICONSET_TMP/icon_256x256@2x.png"
sips -z 512 512 "$APP_ICON_PNG" --out "$ICONSET_TMP/icon_512x512.png"
sips -z 1024 1024 "$APP_ICON_PNG" --out "$ICONSET_TMP/icon_512x512@2x.png"

iconutil -c icns "$ICONSET_TMP" -o "$RES_DIR/AppIcon.icns"

MB_SRC="$ROOT_DIR/menubar-source.png"
if [[ -f "$MB_SRC" ]]; then
    echo "Rendering menu bar template PNGs from menubar-source.png..."
    sips -z 36 36 "$MB_SRC" --out "$RES_DIR/MenuBarTemplate@2x.png"
    sips -z 18 18 "$MB_SRC" --out "$RES_DIR/MenuBarTemplate.png"
else
    echo "Note: Missing menubar-source.png — skipping menu bar PNGs."
fi

WEB_SRC="$ROOT_DIR/web"
if [[ -d "$WEB_SRC" ]]; then
    echo "Copying web assets..."
    cp -R "$WEB_SRC" "$RES_DIR/web"
fi

echo "Ad hoc code signing bundle (Accessibility / TCC uses code identity)..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Build complete: $BINARY_OUT"