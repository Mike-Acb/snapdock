#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

./Scripts/build-app.sh "${1:-release}"

APP_DIR="$ROOT/dist/SnapDock.app"
ZIP="$ROOT/dist/SnapDock.zip"

rm -f "$ZIP"
ditto -c -k --norsrc --keepParent "$APP_DIR" "$ZIP"

echo "==> Packaged $ZIP"
du -h "$ZIP"
