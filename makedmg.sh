#!/bin/bash
# Package dist/LED OCD.app into a distributable disk image.
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/LED OCD.app"
DMG="dist/LED-OCD.dmg"
STAGING="dist/dmg-staging"

[ -d "$APP" ] || { echo "Build the app first: ./build.sh"; exit 1; }

echo "==> Staging…"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating $DMG …"
hdiutil create -volname "LED OCD" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "Done: $DMG"
