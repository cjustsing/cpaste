#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

swift run CPasteCoreChecks
swift build -c release --arch arm64
./scripts/build_app.sh >/tmp/cpaste-build.out
cat /tmp/cpaste-build.out
plutil -lint build/CPaste.app/Contents/Info.plist
if [[ "$(plutil -extract CFBundleLocalizations.0 raw build/CPaste.app/Contents/Info.plist)" != "en" ]]; then
  echo "English localization is missing from the app bundle" >&2
  exit 1
fi
if [[ "$(plutil -extract CFBundleLocalizations.1 raw build/CPaste.app/Contents/Info.plist)" != "zh-Hans" ]]; then
  echo "Simplified Chinese localization is missing from the app bundle" >&2
  exit 1
fi
ICON_FILE="$(plutil -extract CFBundleIconFile raw build/CPaste.app/Contents/Info.plist)"
if [[ "$ICON_FILE" != "CPaste.icns" ]]; then
  echo "Unexpected CFBundleIconFile: $ICON_FILE" >&2
  exit 1
fi
if [[ ! -s "build/CPaste.app/Contents/Resources/$ICON_FILE" ]]; then
  echo "Missing packaged app icon: $ICON_FILE" >&2
  exit 1
fi
for legal_file in LICENSE NOTICE; do
  if ! cmp -s "$legal_file" "build/CPaste.app/Contents/Resources/$legal_file"; then
    echo "Packaged $legal_file differs from source" >&2
    exit 1
  fi
done
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
if ! cmp -s "Resources/Brand/github-mark.svg" "build/CPaste.app/Contents/Resources/Brand/github-mark.svg"; then
  echo "Packaged GitHub mark differs from source" >&2
  exit 1
fi
file "build/CPaste.app/Contents/Resources/$ICON_FILE" | grep -F "Mac OS X icon"
file build/CPaste.app/Contents/MacOS/CPaste
lipo -archs build/CPaste.app/Contents/MacOS/CPaste
codesign --verify --deep --strict --verbose=2 build/CPaste.app

echo "CPaste quality gate passed"
