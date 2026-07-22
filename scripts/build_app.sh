#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CPaste"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_PATH="$ROOT_DIR/Resources/AppIcon/CPaste.icns"
SUPPORT_ASSETS_DIR="$ROOT_DIR/Resources/Support"

cd "$ROOT_DIR"
swift build -c release --arch arm64

BIN_PATH="$ROOT_DIR/.build/arm64-apple-macosx/release/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
  BIN_PATH="$(find "$ROOT_DIR/.build" -path "*/release/$APP_NAME" -type f -perm +111 | head -n 1)"
fi

if [[ -z "${BIN_PATH:-}" || ! -x "$BIN_PATH" ]]; then
  echo "Unable to locate built $APP_NAME binary" >&2
  exit 1
fi

if [[ ! -f "$ICON_PATH" ]]; then
  echo "Unable to locate app icon at $ICON_PATH" >&2
  exit 1
fi

for support_asset in alipay-support-qr.png wechat-support-qr.png; do
  if [[ ! -f "$SUPPORT_ASSETS_DIR/$support_asset" ]]; then
    echo "Unable to locate support asset at $SUPPORT_ASSETS_DIR/$support_asset" >&2
    exit 1
  fi
done

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR/Support"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
cp "$ICON_PATH" "$RESOURCES_DIR/CPaste.icns"
cp "$SUPPORT_ASSETS_DIR/alipay-support-qr.png" "$RESOURCES_DIR/Support/alipay-support-qr.png"
cp "$SUPPORT_ASSETS_DIR/wechat-support-qr.png" "$RESOURCES_DIR/Support/wechat-support-qr.png"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>CPaste</string>
  <key>CFBundleExecutable</key>
  <string>CPaste</string>
  <key>CFBundleIdentifier</key>
  <string>local.cpaste.CPaste</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>CPaste.icns</string>
  <key>CFBundleName</key>
  <string>CPaste</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.3.1</string>
  <key>CFBundleVersion</key>
  <string>4</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticTermination</key>
  <false/>
  <key>NSSupportsSuddenTermination</key>
  <false/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR" >/dev/null
echo "$APP_DIR"
