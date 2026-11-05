#!/usr/bin/env bash
#
# build.sh — build the menu bar app as a universal (arm64 + x86_64) .app and
# a drag-to-Applications .dmg. Runs on a Mac with Xcode or just the Command
# Line Tools (xcode-select --install), Swift 5.9+.
#
#   ./build.sh          → dist/Love Around.app, dist/LoveAround.dmg
#
# With a "Developer ID Application" identity in the keychain the app and the
# .dmg are signed with it (hardened runtime) and the .dmg is notarized and
# stapled through the notarytool keychain profile "lovearound":
#
#   xcrun notarytool store-credentials lovearound --apple-id … --team-id …
#
# Without the identity the app is ad-hoc signed, and the first launch goes
# through System Settings → Privacy & Security → "Open Anyway".
#
#   SIGN_ID=…            identity to sign with (default: the first Developer ID)
#   NOTARY_PROFILE=…     notarytool keychain profile (default: lovearound)
#   NOTARIZE=0           sign with Developer ID but skip notarization: for
#                        test builds; publish.sh won't publish them
#
set -euo pipefail

# The bundle, its id and the download carry the product name; the executable
# keeps the codename. Links are lovearound://, and needed:// still opens the app.
APP_NAME="Love Around"
EXE_NAME="Needed"
DMG_NAME="LoveAround"
VOLUME="Love Around"
cd "$(dirname "${BASH_SOURCE[0]}")"
DIST="$PWD/dist"
APP="$DIST/$APP_NAME.app"

# 0.2.<commit count of this repository>; the build number (CFBundleVersion,
# what Sparkle compares) is 100 + that count. The 0.1 builds came from the old
# shared repository, whose count reached 92, so installed apps have build 92.
COUNT="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
VERSION="0.2.$COUNT"
BUILD="$((100 + COUNT))"

echo ">> compiling $VERSION for arm64 and x86_64"
# One scratch path per arch: newer SwiftPM puts every triple in the same
# out/Products/Release, so the second build would overwrite the first.
BINS=()
for arch in arm64 x86_64; do
  args=(-c release --triple "$arch-apple-macosx13.0" --scratch-path ".build/$arch")
  swift build "${args[@]}"
  BINS+=("$(swift build "${args[@]}" --show-bin-path)/$EXE_NAME")
done

rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/$EXE_NAME"
# Sparkle (updates) ships as a universal binary framework; the executable
# finds it through the @executable_path/../Frameworks rpath (Package.swift).
SPARKLE="$(find .build/arm64/artifacts -type d -name Sparkle.framework -path '*macos*' -print -quit)"
[[ -n "$SPARKLE" ]] || { echo ">> Sparkle.framework not found under .build/arm64/artifacts"; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
# The dictionaries (Strings.swift), and an empty .lproj per language so macOS
# offers the app in System Settings → General → Language & Region → Applications.
mkdir -p "$APP/Contents/Resources/i18n"
cp i18n/*.json "$APP/Contents/Resources/i18n/"
for lproj in en es pt-BR de fr it pl tr uk ru id ko zh-Hans; do
  mkdir -p "$APP/Contents/Resources/$lproj.lproj"
done

echo ">> icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
if swift Tools/make-icon.swift "$ICONSET/full.png"; then
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICONSET/full.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$ICONSET/full.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  rm "$ICONSET/full.png"
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
else
  echo "   (icon failed, building without it)"
fi

SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)}"
if [[ -n "$SIGN_ID" ]]; then
  echo ">> signing with $SIGN_ID"
  # Inside out, no --deep: Sparkle's helpers first, then the framework, then
  # the app (Sparkle's "Sandboxing and code signing" recipe).
  sign() { codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$@"; }
  FW="$APP/Contents/Frameworks/Sparkle.framework"
  sign "$FW/Versions/B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
  sign "$FW/Versions/B/Autoupdate"
  sign "$FW/Versions/B/Updater.app"
  sign "$FW"
  sign "$APP"
  codesign --verify --strict --deep "$APP"
else
  echo ">> ad-hoc signing (no Developer ID Application identity in the keychain)"
  codesign --force --deep --sign - "$APP"
fi

echo ">> dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$DMG_NAME.dmg" >/dev/null
rm -rf "$STAGE"
SIGNING=adhoc
if [[ -n "$SIGN_ID" ]]; then
  codesign --force --timestamp --sign "$SIGN_ID" "$DIST/$DMG_NAME.dmg"
  SIGNING=signed
  if [[ "${NOTARIZE:-1}" != 0 ]]; then
    echo ">> notarizing (a few minutes)"
    xcrun notarytool submit "$DIST/$DMG_NAME.dmg" \
      --keychain-profile "${NOTARY_PROFILE:-lovearound}" --wait
    # The ticket goes on the .dmg; the app inside is checked online. Sparkle
    # installs don't get the quarantine flag, so updates aren't checked at all.
    xcrun stapler staple "$DIST/$DMG_NAME.dmg"
    spctl --assess --type open --context context:primary-signature -v "$DIST/$DMG_NAME.dmg"
    SIGNING=notarized
  fi
fi
# For the appcast: publish.sh reads the build number and version from
# here, and refuses a build that isn't notarized.
echo "$BUILD $VERSION $SIGNING" > "$DIST/$DMG_NAME.version"

lipo -archs "$APP/Contents/MacOS/$EXE_NAME"
echo ">> done: $DIST/$DMG_NAME.dmg ($(du -h "$DIST/$DMG_NAME.dmg" | cut -f1), $SIGNING)"
