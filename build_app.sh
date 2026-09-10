#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
APP_BUNDLE="$PROJECT_DIR/dist/WallpaperConverter.app"
THIRD_PARTY_DIR="$PROJECT_DIR/ThirdParty/macos-custom-video-wallpaper-fix"
ENCODER_STAGE="$BUILD_DIR/encoder-staging"
SWIFTC="${SWIFTC:-swiftc}"

cd "$PROJECT_DIR"
swift build -c release

rm -rf "$ENCODER_STAGE"
mkdir -p "$ENCODER_STAGE"
"$SWIFTC" -O -target arm64-apple-macosx13.0 \
  "$THIRD_PARTY_DIR/encode_temporal.swift" \
  -o "$ENCODER_STAGE/encode_temporal"
chmod +x "$ENCODER_STAGE/encode_temporal"

if ! command -v file >/dev/null 2>&1; then
  echo "file is required to validate the bundled encoder" >&2
  exit 1
fi
ENCODER_FILE_DESCRIPTION="$(file -b "$ENCODER_STAGE/encode_temporal")"
case "$ENCODER_FILE_DESCRIPTION" in
  *"arm64"*) ;;
  *)
    echo "Bundled encoder is not arm64: $ENCODER_FILE_DESCRIPTION" >&2
    exit 1
    ;;
esac

mkdir -p "$PROJECT_DIR/dist"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" \
  "$APP_BUNDLE/Contents/Resources/Encoder/bin" \
  "$APP_BUNDLE/Contents/Resources/Encoder/source"
cp "$BUILD_DIR/release/WallpaperConverter" "$APP_BUNDLE/Contents/MacOS/WallpaperConverter"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppLogo.png" "$APP_BUNDLE/Contents/Resources/AppLogo.png"
cp "$ENCODER_STAGE/encode_temporal" \
  "$APP_BUNDLE/Contents/Resources/Encoder/bin/encode_temporal"
cp "$THIRD_PARTY_DIR/LICENSE" "$APP_BUNDLE/Contents/Resources/Encoder/LICENSE"
cp "$THIRD_PARTY_DIR/encode_temporal.swift" \
  "$THIRD_PARTY_DIR/groups.py" \
  "$THIRD_PARTY_DIR/build.sh" \
  "$APP_BUNDLE/Contents/Resources/Encoder/source/"
chmod +x "$APP_BUNDLE/Contents/Resources/Encoder/bin/encode_temporal"

APP_FILE_DESCRIPTION="$(file -b "$APP_BUNDLE/Contents/MacOS/WallpaperConverter")"
case "$APP_FILE_DESCRIPTION" in
  *"arm64"*) ;;
  *)
    echo "WallpaperConverter is not arm64: $APP_FILE_DESCRIPTION" >&2
    exit 1
    ;;
esac

ENCODER_BINARY="$APP_BUNDLE/Contents/Resources/Encoder/bin/encode_temporal"
if ! command -v codesign >/dev/null 2>&1; then
  echo "codesign is required to build a distributable app" >&2
  exit 1
fi
# Sign the nested encoder first. Its signature is part of the manifest hash.
codesign --force --sign - "$ENCODER_BINARY"
ENCODER_SHA256="$(shasum -a 256 "$ENCODER_BINARY" | awk '{print $1}')"
cat > "$APP_BUNDLE/Contents/Resources/Encoder/manifest.json" <<EOF
{
  "version": 1,
  "architecture": "arm64",
  "files": {
    "bin/encode_temporal": "$ENCODER_SHA256"
  }
}
EOF

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
codesign --force --sign - "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "Built and ad-hoc signed $APP_BUNDLE"
