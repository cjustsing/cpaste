#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

swift run CPasteCoreChecks
swift build -c release --arch arm64
./scripts/build_app.sh >/tmp/cpaste-build.out
cat /tmp/cpaste-build.out
plutil -lint build/CPaste.app/Contents/Info.plist
ICON_FILE="$(plutil -extract CFBundleIconFile raw build/CPaste.app/Contents/Info.plist)"
if [[ "$ICON_FILE" != "CPaste.icns" ]]; then
  echo "Unexpected CFBundleIconFile: $ICON_FILE" >&2
  exit 1
fi
if [[ ! -s "build/CPaste.app/Contents/Resources/$ICON_FILE" ]]; then
  echo "Missing packaged app icon: $ICON_FILE" >&2
  exit 1
fi
file "build/CPaste.app/Contents/Resources/$ICON_FILE" | rg "Mac OS X icon"
file build/CPaste.app/Contents/MacOS/CPaste
lipo -archs build/CPaste.app/Contents/MacOS/CPaste
codesign --verify --deep --strict --verbose=2 build/CPaste.app

echo "CPaste quality gate passed"
