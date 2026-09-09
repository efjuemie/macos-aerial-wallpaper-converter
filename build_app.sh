sed: --: No such file or directory
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
chmod +x "$APP_BUNDLE/Contents/MacOS/WallpaperConverter"

echo "Built $APP_BUNDLE"
