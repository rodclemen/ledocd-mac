#!/bin/bash
# Build a universal (Apple Silicon + Intel) "LED OCD.app" and code-sign it with
# the Developer ID identity. Notarization is a separate step (see notarize.sh).
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="LED OCD"
BUNDLE_ID="com.rodclemen.ledocd"
EXE_NAME="LEDOCD"
# Version scheme: bump the LAST number for every release (0.9.2, 0.9.3, …,
# 0.9.566, …) — it never rolls over. 1.0 happens only as a deliberate milestone.
VERSION="0.9.3"
BUILD="${VERSION##*.}"   # CFBundleVersion derived from the last number
# Code-signing identity — nothing personal is hardcoded:
#   1. $LEDOCD_SIGN_ID, if set (explicit override)
#   2. the first "Developer ID Application" certificate in this Mac's keychain
#      (the maintainer's machine picks up their own identity automatically)
#   3. ad-hoc ("-"): anyone can build & run locally, but the app isn't
#      notarizable and other Macs will show the Gatekeeper warning.
if [ -n "${LEDOCD_SIGN_ID:-}" ]; then
    SIGN_ID="$LEDOCD_SIGN_ID"
else
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
    [ -n "$SIGN_ID" ] || SIGN_ID="-"
fi
if [ "$SIGN_ID" = "-" ]; then
    echo "==> No Developer ID certificate found — using ad-hoc signing (local use only)."
else
    echo "==> Signing as: $SIGN_ID"
fi

DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> Building universal release binary…"
swift build -c release --arch arm64 --arch x86_64

BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "==> Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/data"
cp "$BIN_PATH/$EXE_NAME" "$APP/Contents/MacOS/$EXE_NAME"

echo "==> Bundling machine presets (CSV)…"
cp data/*.csv "$APP/Contents/Resources/data/"

echo "==> Bundling the manual…"
cp docs/manual.html "$APP/Contents/Resources/manual.html"

echo "==> Generating app icon (asset catalog, like stock macOS apps)…"
# Finder/IconServices reliably render the icon from a COMPILED ASSET CATALOG
# (Assets.car) referenced by CFBundleIconName — this is what Apple's own apps
# (e.g. Notes) do. A loose AppIcon.icns + CFBundleIconFile is the legacy path
# and is where Finder shows a stale/inset icon. We build both: actool emits
# Assets.car (primary) plus a fallback AppIcon.icns.
TMPICON="$(mktemp -d)"
swiftc makeicon.swift -o "$TMPICON/makeicon" >/dev/null      # reshape to macOS squircle template
"$TMPICON/makeicon" app_icon.png "$TMPICON/shaped.png"
SET="$TMPICON/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$SET"
for px in 16 32 64 128 256 512 1024; do
    sips -z $px $px "$TMPICON/shaped.png" --out "$SET/icon_${px}.png" >/dev/null
done
cat > "$SET/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom":"mac", "size":"16x16",   "scale":"1x", "filename":"icon_16.png" },
    { "idiom":"mac", "size":"16x16",   "scale":"2x", "filename":"icon_32.png" },
    { "idiom":"mac", "size":"32x32",   "scale":"1x", "filename":"icon_32.png" },
    { "idiom":"mac", "size":"32x32",   "scale":"2x", "filename":"icon_64.png" },
    { "idiom":"mac", "size":"128x128", "scale":"1x", "filename":"icon_128.png" },
    { "idiom":"mac", "size":"128x128", "scale":"2x", "filename":"icon_256.png" },
    { "idiom":"mac", "size":"256x256", "scale":"1x", "filename":"icon_256.png" },
    { "idiom":"mac", "size":"256x256", "scale":"2x", "filename":"icon_512.png" },
    { "idiom":"mac", "size":"512x512", "scale":"1x", "filename":"icon_512.png" },
    { "idiom":"mac", "size":"512x512", "scale":"2x", "filename":"icon_1024.png" }
  ],
  "info" : { "author":"xcode", "version":1 }
}
JSON
xcrun actool "$TMPICON/Assets.xcassets" \
    --compile "$APP/Contents/Resources" \
    --app-icon AppIcon \
    --platform macosx \
    --minimum-deployment-target 12.0 \
    --output-partial-info-plist "$TMPICON/partial.plist" \
    --errors --warnings >/dev/null
rm -rf "$TMPICON"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>      <string>$EXE_NAME</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundleIconName</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$BUILD</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>LSMinimumSystemVersion</key>  <string>12.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> Code-signing with hardened runtime…"
# Ad-hoc signatures can't carry a secure timestamp — only pass --timestamp
# when signing with a real certificate.
SIGN_FLAGS=(--force --options runtime)
[ "$SIGN_ID" != "-" ] && SIGN_FLAGS+=(--timestamp)
codesign "${SIGN_FLAGS[@]}" \
    --sign "$SIGN_ID" \
    "$APP"

echo "==> Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP"

echo ""
echo "Done: $APP"
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/$EXE_NAME")"
