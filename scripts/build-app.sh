#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
[[ "$VERSION" == "$PLIST_VERSION" ]] || { echo "Version mismatch" >&2; exit 1; }
export MACOSX_DEPLOYMENT_TARGET=11.0
ARCH="${ARCH:-x86_64}"
swift build -c release --arch "$ARCH"
BIN_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path)"
APP="dist/Point & Tell.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PointAndTell" "$APP/Contents/MacOS/PointAndTell"
cp Resources/Info.plist "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/PointAndTell"
# Ad-hoc signature, no Developer ID or notarization credentials.
codesign --force --deep --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"
file "$APP/Contents/MacOS/PointAndTell"
otool -l "$APP/Contents/MacOS/PointAndTell" | grep -A5 LC_BUILD_VERSION
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/Point-and-Tell-macOS-${ARCH}.zip"
shasum -a 256 "dist/Point-and-Tell-macOS-${ARCH}.zip" > "dist/Point-and-Tell-macOS-${ARCH}.zip.sha256"
