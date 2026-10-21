#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${1:-release}"
case "$CONFIGURATION" in
  debug|release) ;;
  *) echo "error: configuration must be debug or release." >&2; exit 1 ;;
esac

APP_NAME="SnapDock"
APP_DIR="$ROOT/dist/${APP_NAME}.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
# Build against the macOS 26 SDK so the UI keeps the look of released builds; set SNAPDOCK_SDK to override.
# The SDK version is passed to the linker explicitly: swiftbuild recorded it as the 13.0 deployment
# target, which made macOS run the app in legacy compatibility mode. 13.0 matches .macOS(.v13) in Package.swift.
SDK_PATH="${SNAPDOCK_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk}"
if [[ ! -f "$SDK_PATH/SDKSettings.plist" ]]; then
  echo "error: macOS SDK not found at $SDK_PATH (set SNAPDOCK_SDK to choose one)" >&2
  exit 1
fi
SDK_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :Version' "$SDK_PATH/SDKSettings.plist")"
# swiftbuild ignores --sdk and always uses the SDK bundled with Xcode, so use the native build system.
BUILD_FLAGS=(--configuration "$CONFIGURATION" --arch arm64 --build-system native --sdk "$SDK_PATH"
  -Xlinker -platform_version -Xlinker macos -Xlinker 13.0 -Xlinker "$SDK_VERSION")

echo "==> Resolving packages"
swift package resolve

echo "==> Building arm64 (${CONFIGURATION})"
swift build "${BUILD_FLAGS[@]}"
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"

if [[ ! -x "$BIN" ]]; then
  echo "error: built binary not found at $BIN" >&2
  exit 1
fi

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
cp "$ROOT/App/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/App/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  bundle_name="${bundle##*/}"
  cp -R "$bundle" "$RESOURCES_DIR/$bundle_name"
done
shopt -u nullglob

printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "==> Built $APP_DIR"
echo "    Run with: open \"$APP_DIR\""
