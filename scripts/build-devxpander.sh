#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_FILE="$ROOT_DIR/Devxpander.app/Contents/MacOS/Devxpander.swift"
BINARY_OUT="$ROOT_DIR/Devxpander.app/Contents/MacOS/Devxpander"
APP_BUNDLE="$ROOT_DIR/Devxpander.app"
RES_DIR="$APP_BUNDLE/Contents/Resources"

if [[ ! -f "$SWIFT_FILE" ]]; then
    echo "Missing Swift source at: $SWIFT_FILE"
    exit 1
fi

APP_ICON_PNG="$ROOT_DIR/app.png"
if [[ ! -f "$APP_ICON_PNG" ]]; then
    echo "Missing app.png at $APP_ICON_PNG (Finder / Dock icns source)."
    exit 1
fi

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
    echo "Note: Missing menubar-source.png — menu bar PNGs left unchanged."
fi

echo "Ad hoc code signing bundle (Accessibility / TCC uses code identity)..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Build complete: $BINARY_OUT"
