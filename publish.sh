#!/usr/bin/env bash
#
# publish.sh — release dist/LoveAround.dmg (from build.sh) as the GitHub
# release v<version> of this repository, with the Sparkle appcast the
# installed apps check every hour.
#
# lovearound.me/download/appcast.xml (SUFeedURL in Resources/Info.plist) and
# /download/LoveAround.dmg redirect to the latest release (firebase.json in
# the site repo); the appcast points at this release's dmg.
#
# The appcast is signed with the EdDSA key at $SPARKLE_KEY; its public half is
# SUPublicEDKey in Resources/Info.plist. Without that key no update can reach
# the installed apps, so keep a copy of it elsewhere. Signing uses OpenSSL 3
# (pkeyutl -rawin): run this where the key is, after copying dist/ there.
#
# Only a notarized build is released (the third field of
# dist/LoveAround.version, written by build.sh). ALLOW_UNNOTARIZED=1 releases
# a signed-only or ad-hoc build anyway.
#
# Needs gh, logged in with write access to the repository; the release is
# tagged at HEAD, so push first.
#
#   REPO=…          the GitHub repository (default: lovearound-me/mac)
#   SPARKLE_KEY=…   default: ~/.config/lovearound/sparkle_ed25519.pem
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
REPO="${REPO:-lovearound-me/mac}"
SPARKLE_KEY="${SPARKLE_KEY:-$HOME/.config/lovearound/sparkle_ed25519.pem}"

DMG=dist/LoveAround.dmg
for f in "$DMG" dist/LoveAround.version "$SPARKLE_KEY"; do
  [[ -f "$f" ]] || { echo ">> no $f"; exit 1; }
done
read -r BUILD VERSION SIGNING < dist/LoveAround.version
if [[ "$SIGNING" != notarized && "${ALLOW_UNNOTARIZED:-0}" != 1 ]]; then
  echo ">> $VERSION is ${SIGNING:-ad-hoc}, not notarized: rebuild without NOTARIZE=0, or ALLOW_UNNOTARIZED=1"
  exit 1
fi
TAG="v$VERSION"
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  echo ">> $TAG is already released"; exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp "$DMG" "$STAGE/LoveAround.dmg"
SIGNATURE="$(openssl pkeyutl -sign -rawin -inkey "$SPARKLE_KEY" -in "$DMG" | base64 -w0)"
cat > "$STAGE/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Love Around</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u -R)</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/LoveAround.dmg" length="$(stat -c %s "$DMG")" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
    </item>
  </channel>
</rss>
XML

echo ">> releasing $TAG (build $BUILD, $(du -h "$DMG" | cut -f1))"
gh release create "$TAG" -R "$REPO" --target "$(git rev-parse HEAD)" --latest \
  --title "Love Around $VERSION" --notes "" \
  "$STAGE/LoveAround.dmg" "$STAGE/appcast.xml"
echo ">> done: https://github.com/$REPO/releases/tag/$TAG"
