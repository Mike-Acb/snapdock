#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

./Scripts/build-app.sh "${1:-release}"

# App/Info.plist is the single source of truth for the version.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/App/Info.plist")"
APP_DIR="$ROOT/dist/SnapDock.app"
DMG="$ROOT/dist/SnapDock-$VERSION.dmg"
STAGING="$ROOT/dist/dmg"

# The disk image holds the app next to an Applications link, so users install by dragging.
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "SnapDock" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGING"

echo "==> Packaged $DMG"
du -h "$DMG"
