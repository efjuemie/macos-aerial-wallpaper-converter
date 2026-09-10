#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="$PROJECT_DIR/dist/WallpaperConverter.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
RELEASE_DIR="$PROJECT_DIR/dist/releases"

if [[ ! -d "$APP_BUNDLE" || ! -f "$INFO_PLIST" ]]; then
  echo "Missing $APP_BUNDLE; run ./build_app.sh first." >&2
  exit 1
fi

VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST")"
[[ -n "$VERSION" ]] || { echo "Info.plist has no version" >&2; exit 1; }
[[ "$BUNDLE_ID" == "io.github.efjuemie.WallpaperConverter" ]] || {
  echo "Unexpected bundle identifier: $BUNDLE_ID" >&2
  exit 1
}

APP_BINARY="$APP_BUNDLE/Contents/MacOS/WallpaperConverter"
ENCODER_BINARY="$APP_BUNDLE/Contents/Resources/Encoder/bin/encode_temporal"
ENCODER_MANIFEST="$APP_BUNDLE/Contents/Resources/Encoder/manifest.json"
for required in "$APP_BINARY" "$ENCODER_BINARY" "$ENCODER_MANIFEST" \
  "$APP_BUNDLE/Contents/Resources/Encoder/LICENSE" \
  "$APP_BUNDLE/Contents/Resources/Encoder/source/encode_temporal.swift" \
  "$APP_BUNDLE/Contents/Resources/Encoder/source/groups.py"; do
  [[ -e "$required" ]] || { echo "Missing app resource: $required" >&2; exit 1; }
done

APP_ARCHS="$(lipo -archs "$APP_BINARY")"
ENCODER_ARCHS="$(lipo -archs "$ENCODER_BINARY")"
case " $APP_ARCHS " in *" arm64 "*) ;; *) echo "App is not arm64: $APP_ARCHS" >&2; exit 1 ;; esac
case " $ENCODER_ARCHS " in *" arm64 "*) ;; *) echo "Encoder is not arm64: $ENCODER_ARCHS" >&2; exit 1 ;; esac
ENCODER_SHA256="$(shasum -a 256 "$ENCODER_BINARY" | awk '{print $1}')"
grep -F '"bin/encode_temporal": "'"$ENCODER_SHA256"'"' "$ENCODER_MANIFEST" >/dev/null || {
  echo "Encoder manifest SHA-256 does not match" >&2
  exit 1
}
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

mkdir -p "$RELEASE_DIR"
ZIP_PATH="$RELEASE_DIR/Aerial-Wallpaper-Converter-v${VERSION}-Apple-Silicon.zip"
DMG_PATH="$RELEASE_DIR/Aerial-Wallpaper-Converter-v${VERSION}-Apple-Silicon.dmg"
rm -f "$ZIP_PATH" "$DMG_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aerial-wallpaper-release.XXXXXX")"
MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aerial-wallpaper-mount.XXXXXX")"
cleanup() {
  hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  rm -rf "$STAGING_DIR" "$MOUNT_DIR"
}
trap cleanup EXIT
cp -R "$APP_BUNDLE" "$STAGING_DIR/WallpaperConverter.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname "Aerial Wallpaper Converter v${VERSION}" \
  -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null

unzip -tqq "$ZIP_PATH"
ATTACH_OUTPUT="$(hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_DIR")"
[[ -d "$MOUNT_DIR/WallpaperConverter.app" ]] || { echo "DMG is missing the app" >&2; exit 1; }
[[ -L "$MOUNT_DIR/Applications" ]] || { echo "DMG is missing Applications symlink" >&2; exit 1; }
hdiutil detach "$MOUNT_DIR" >/dev/null
trap - EXIT
rm -rf "$STAGING_DIR" "$MOUNT_DIR"

echo "Packaged version $VERSION"
echo "$ZIP_PATH"
echo "$DMG_PATH"
echo "Ad-hoc signed only; Developer ID signing and notarization are not configured."
