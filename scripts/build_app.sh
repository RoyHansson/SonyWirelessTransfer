#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Sony Wireless Transfer"
PRODUCT_NAME="SonyWirelessMacOS"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
DMG_STAGING_DIR="$ROOT_DIR/dist/dmg-staging"
DMG_PATH="$ROOT_DIR/dist/$APP_NAME.dmg"
APP_ZIP_PATH="$ROOT_DIR/dist/$APP_NAME-notarization.zip"
LIBUSB_PREFIX="${LIBUSB_PREFIX:-/opt/homebrew/opt/libusb}"
LIBUSB_INCLUDE_DIR="$LIBUSB_PREFIX/include"
LIBUSB_DYLIB_PATH="$LIBUSB_PREFIX/lib/libusb-1.0.0.dylib"
GUID_HELPER_SOURCE="$ROOT_DIR/sony-guid-setter.c"
GUID_HELPER_OUTPUT="$APP_DIR/Contents/Resources/sony-guid-setter"
LIBUSB_APP_PATH="$APP_DIR/Contents/Resources/libusb-1.0.0.dylib"
NOTICES_DIR="$APP_DIR/Contents/Resources/OpenSourceNotices"
SWIFTPM_HOME="$ROOT_DIR/.build/swiftpm-home"
MODULE_CACHE_DIR="$ROOT_DIR/.build/ModuleCache"
DEVELOPER_ID_IDENTITY="${SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | perl -ne 'print "$1\n" if /"(Developer ID Application:.*?)"/' | head -n 1)}"
NOTARYTOOL_KEYCHAIN_PROFILE="${NOTARYTOOL_KEYCHAIN_PROFILE:-}"

sign_path() {
  local path="$1"
  /usr/bin/codesign --force --sign "$DEVELOPER_ID_IDENTITY" --options runtime --timestamp "$path"
}

cd "$ROOT_DIR"
mkdir -p "$SWIFTPM_HOME" "$MODULE_CACHE_DIR"
HOME="$SWIFTPM_HOME" \
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR" \
swift build -c release --disable-sandbox

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/$PRODUCT_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/AppBundle/Info.plist" "$APP_DIR/Contents/Info.plist"
for bundle in "$BUILD_DIR"/*.bundle(N); do
  cp -R "$bundle" "$APP_DIR/Contents/Resources/"
done

if [[ -f "$GUID_HELPER_SOURCE" && -f "$LIBUSB_DYLIB_PATH" && -f "$LIBUSB_INCLUDE_DIR/libusb-1.0/libusb.h" ]]; then
  cc -I"$LIBUSB_INCLUDE_DIR" "$GUID_HELPER_SOURCE" "$LIBUSB_DYLIB_PATH" -o "$GUID_HELPER_OUTPUT"
  cp "$LIBUSB_DYLIB_PATH" "$LIBUSB_APP_PATH"
  install_name_tool -change "$LIBUSB_DYLIB_PATH" "@executable_path/../Resources/libusb-1.0.0.dylib" "$GUID_HELPER_OUTPUT"
  chmod +x "$GUID_HELPER_OUTPUT"

  mkdir -p "$NOTICES_DIR"
  cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$NOTICES_DIR/THIRD_PARTY_NOTICES.md"
  cp "$ROOT_DIR/LICENSES/LGPL-2.1-or-later.txt" "$NOTICES_DIR/LGPL-2.1-or-later.txt"
else
  echo "Warning: libusb not found. Building without the USB pairing helper." >&2
fi

chmod -R u+w "$APP_DIR" || true
xattr -cr "$APP_DIR" 2>/dev/null || true

if [[ -z "$DEVELOPER_ID_IDENTITY" ]]; then
  echo "Warning: no Developer ID Application certificate found. Falling back to ad-hoc signing." >&2
  /usr/bin/codesign --force --deep --sign - "$APP_DIR"
else
  echo "Signing with: $DEVELOPER_ID_IDENTITY"
  if [[ -f "$LIBUSB_APP_PATH" ]]; then
    sign_path "$LIBUSB_APP_PATH"
  fi
  if [[ -f "$GUID_HELPER_OUTPUT" ]]; then
    sign_path "$GUID_HELPER_OUTPUT"
  fi
  sign_path "$APP_DIR/Contents/MacOS/$APP_NAME"
  sign_path "$APP_DIR"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"

  if [[ -n "$NOTARYTOOL_KEYCHAIN_PROFILE" ]]; then
    rm -f "$APP_ZIP_PATH"
    ditto -c -k --keepParent "$APP_DIR" "$APP_ZIP_PATH"
    xcrun notarytool submit "$APP_ZIP_PATH" --keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE" --wait
    xcrun stapler staple "$APP_DIR"
    rm -f "$APP_ZIP_PATH"
  fi
fi

rm -rf "$DMG_STAGING_DIR" "$DMG_PATH"
mkdir -p "$DMG_STAGING_DIR"
cp -R "$APP_DIR" "$DMG_STAGING_DIR/"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null

if [[ -n "$DEVELOPER_ID_IDENTITY" ]]; then
  /usr/bin/codesign --force --sign "$DEVELOPER_ID_IDENTITY" --timestamp "$DMG_PATH"
  /usr/bin/codesign --verify --verbose=2 "$DMG_PATH"

  if [[ -n "$NOTARYTOOL_KEYCHAIN_PROFILE" ]]; then
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
  fi
fi

echo "Built $APP_DIR"
echo "Built $DMG_PATH"
