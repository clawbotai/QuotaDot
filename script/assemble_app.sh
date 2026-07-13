#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${1:-debug}"
APP_NAME="QuotaDot"
BUNDLE_ID="com.cmsjcm.QuotaDot"
VERSION="${QUOTADOT_VERSION:-0.1.0}"
BUILD_NUMBER="${QUOTADOT_BUILD_NUMBER:-1}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${2:-$ROOT_DIR/dist/$APP_NAME.app}"
APP_MACOS="$APP_BUNDLE/Contents/MacOS"
APP_RESOURCES="$APP_BUNDLE/Contents/Resources"

case "$CONFIGURATION" in
  debug) SWIFT_CONFIGURATION="debug" ;;
  release) SWIFT_CONFIGURATION="release" ;;
  *) echo "usage: $0 [debug|release] [output.app]" >&2; exit 2 ;;
esac

cd "$ROOT_DIR"
if [[ "$SWIFT_CONFIGURATION" == "release" ]]; then
  swift build -c release
  BIN_PATH="$(swift build -c release --show-bin-path)"
else
  swift build
  BIN_PATH="$(swift build --show-bin-path)"
fi
BUILD_BINARY="$BIN_PATH/$APP_NAME"
RESOURCE_BUNDLE="$(find "$BIN_PATH" -maxdepth 1 -type d -name 'QuotaDot_QuotaDot.bundle' -print -quit)"
ICON_SOURCE="$ROOT_DIR/Sources/QuotaDot/Resources/AppIcon.icns"

[[ -x "$BUILD_BINARY" ]] || { echo "missing executable: $BUILD_BINARY" >&2; exit 3; }
[[ -f "$ICON_SOURCE" ]] || { echo "missing app icon: $ICON_SOURCE" >&2; exit 3; }

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_MACOS/$APP_NAME"
chmod +x "$APP_MACOS/$APP_NAME"
cp "$ICON_SOURCE" "$APP_RESOURCES/AppIcon.icns"
if [[ -n "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$APP_RESOURCES/"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>$APP_NAME</string>
<key>CFBundleExecutable</key><string>$APP_NAME</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocationWhenInUseUsageDescription</key><string>用于根据 Mac 当前所在位置显示实时天气背景。</string>
<key>NSLocationUsageDescription</key><string>用于根据 Mac 当前所在位置显示实时天气背景。</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

SIGNING_IDENTITY="${QUOTADOT_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  if [[ "$CONFIGURATION" == "release" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' \
      | head -n 1)"
  else
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' \
      | head -n 1)"
  fi
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
  if [[ "${QUOTADOT_ALLOW_ADHOC:-0}" == "1" ]]; then
    SIGNING_IDENTITY="-"
    echo "warning: assembling an ad-hoc signed build; it is not suitable for public distribution" >&2
  else
    echo "No suitable signing identity found." >&2
    if [[ "$CONFIGURATION" == "release" ]]; then
      echo "Install a Developer ID Application certificate, or set QUOTADOT_ALLOW_ADHOC=1 for local packaging QA only." >&2
    else
      echo "Install an Apple Development certificate, or set QUOTADOT_ALLOW_ADHOC=1." >&2
    fi
    exit 4
  fi
fi

SIGN_ARGS=(--force --deep --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID")
if [[ "$CONFIGURATION" == "release" && "$SIGNING_IDENTITY" != "-" ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "$APP_BUNDLE"
