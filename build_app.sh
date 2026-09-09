#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
APP_BUNDLE="$PROJECT_DIR/dist/WallpaperConverter.app"

cd "$PROJECT_DIR"
swift build -c release
mkdir -p "$PROJECT_DIR/dist"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/release/WallpaperConverter" "$APP_BUNDLE/Contents/MacOS/WallpaperConverter"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppLogo.png" "$APP_BUNDLE/Contents/Resources/AppLogo.png"
mkdir -p "$APP_BUNDLE/Contents/Resources/Encoder"
cp -R "$PROJECT_DIR/ThirdParty/macos-custom-video-wallpaper-fix" \
  "$APP_BUNDLE/Contents/Resources/Encoder/macos-custom-video-wallpaper-fix"

if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  ICONSET="$BUILD_DIR/AppIcon.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$PROJECT_DIR/Resources/AppLogo.png" \
      --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$PROJECT_DIR/Resources/AppLogo.png" \
      --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil --convert icns --output "$APP_BUNDLE/Contents/Resources/AppIcon.icns" "$ICONSET"
fi
chmod +x "$APP_BUNDLE/Contents/MacOS/WallpaperConverter"

echo "Built $APP_BUNDLE"
