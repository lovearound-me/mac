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
# The appcast is signed with the EdDSA key in the environment, SPARKLE_KEY
# (the PEM itself): the release workflow passes its GitHub secret. The key is
# kept nowhere else but the owner's password manager, never in a file, so
# releases go through the workflow; its public half is SUPublicEDKey in
# Resources/Info.plist. Without it no update can reach the installed apps.
# Signing uses OpenSSL 3 (pkeyutl -rawin).
#
# Only a notarized build is released (the third field of
# dist/LoveAround.version, written by build.sh). ALLOW_UNNOTARIZED=1 releases
# a signed-only or ad-hoc build anyway.
#
# Needs gh, logged in with write access to the repository; the release is
# tagged at HEAD, so push first. Needs the history and tags (for the notes).
#
#   REPO=…          the GitHub repository (default: lovearound-me/mac)
#   SPARKLE_KEY=…   the private key, PEM (in the workflow, its secret)
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
REPO="${REPO:-lovearound-me/mac}"
[[ -n "${SPARKLE_KEY:-}" ]] || { echo ">> no SPARKLE_KEY: releases are signed in the GitHub workflow"; exit 1; }

DMG=dist/LoveAround.dmg
for f in "$DMG" dist/LoveAround.version; do
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

# What changed, for the release page: each `Release-note: …` line in the
# messages of the commits since the last release, oldest first. One line per
# change, anywhere in the message; a commit nobody would notice has none.
PREV="$(git describe --tags --abbrev=0 --match 'v*' HEAD 2>/dev/null || true)"
NOTES="$(git log --reverse --format=%B "${PREV:+$PREV..}HEAD" \
  | sed -n -e 's/^Release-note:[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/- \1/p')"
if [[ -z "$NOTES" ]]; then
  echo "::warning::no Release-note lines since ${PREV:-the first commit}"
  NOTES="Small fixes under the hood."
fi
printf '>> notes:\n%s\n' "$NOTES"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp "$DMG" "$STAGE/LoveAround.dmg"
# The key reaches openssl through a pipe: on no command line, in no file.
SIGNATURE="$(openssl pkeyutl -sign -rawin -inkey <(printf '%s\n' "$SPARKLE_KEY") -in "$DMG" | base64 -w0)"
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
  --title "Love Around $VERSION" --notes "$NOTES" \
  "$STAGE/LoveAround.dmg" "$STAGE/appcast.xml"
echo ">> done: https://github.com/$REPO/releases/tag/$TAG"
