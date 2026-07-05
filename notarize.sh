#!/bin/bash
# Notarize the DMG (and staple the ticket) so others can open the app without
# Gatekeeper warnings. Requires an Apple Developer account.
#
# Credentials are NEVER stored in this repo. Two ways to supply them:
#
#   1. Keychain profile (recommended — one-time setup, then just ./notarize.sh):
#        xcrun notarytool store-credentials LEDOCD \
#            --apple-id "you@example.com" --team-id "YOURTEAMID"
#      (prompts for an app-specific password from https://account.apple.com
#       → Sign-In and Security → App-Specific Passwords, and stores everything
#       in your macOS keychain under the profile name "LEDOCD")
#
#   2. Environment variables for a one-off run:
#        AC_APPLE_ID="you@example.com" AC_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
#        AC_TEAM="YOURTEAMID" ./notarize.sh
#
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${AC_PROFILE:-LEDOCD}"

if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    AUTH=(--keychain-profile "$PROFILE")
    echo "==> Using keychain profile \"$PROFILE\"."
elif [ -n "${AC_APPLE_ID:-}" ] && [ -n "${AC_PASSWORD:-}" ] && [ -n "${AC_TEAM:-}" ]; then
    AUTH=(--apple-id "$AC_APPLE_ID" --password "$AC_PASSWORD" --team-id "$AC_TEAM")
    echo "==> Using credentials from environment."
else
    echo "No notary credentials found."
    echo "One-time setup (stores them in your keychain, nothing in the repo):"
    echo "    xcrun notarytool store-credentials $PROFILE --apple-id \"you@example.com\" --team-id \"YOURTEAMID\""
    echo "Then simply run ./notarize.sh again."
    exit 1
fi

DMG="dist/LED-OCD.dmg"
APP="dist/LED OCD.app"
[ -f "$DMG" ] || { echo "Build the DMG first: ./makedmg.sh"; exit 1; }

echo "==> Submitting to Apple notary service (this can take a few minutes)…"
xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait

echo "==> Stapling the app…"
xcrun stapler staple "$APP"

# Rebuilding the DMG (so it contains the stapled app) produces a new file that
# Apple hasn't seen — submit that one too, then staple it as well.
./makedmg.sh
echo "==> Submitting the rebuilt DMG…"
xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait
echo "==> Stapling the DMG…"
xcrun stapler staple "$DMG"

echo "==> Verifying…"
spctl -a -vvv -t install "$APP" || true
echo "Done. $DMG is notarized and ready to share."
