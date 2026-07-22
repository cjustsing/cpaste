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
for support_asset in alipay-support-qr.png wechat-support-qr.png; do
  packaged_asset="build/CPaste.app/Contents/Resources/Support/$support_asset"
  if [[ ! -s "$packaged_asset" ]]; then
    echo "Missing packaged support asset: $support_asset" >&2
    exit 1
  fi
  if ! cmp -s "Resources/Support/$support_asset" "$packaged_asset"; then
    echo "Packaged support asset differs from source: $support_asset" >&2
    exit 1
  fi
done
file "build/CPaste.app/Contents/Resources/$ICON_FILE" | rg "Mac OS X icon"
file build/CPaste.app/Contents/MacOS/CPaste
lipo -archs build/CPaste.app/Contents/MacOS/CPaste
codesign --verify --deep --strict --verbose=2 build/CPaste.app

echo "CPaste quality gate passed"
