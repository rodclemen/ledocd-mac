#!/bin/bash
# One-command release: build → package → notarize → GitHub release.
#
# Usage:
#   1. Bump VERSION in build.sh and update CHANGELOG.md (a "## X.Y.Z — date"
#      section — it becomes the release notes).
#   2. ./release.sh
#
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(sed -n 's/^VERSION="\(.*\)"/\1/p' build.sh)"
[ -n "$VERSION" ] || { echo "Could not read VERSION from build.sh"; exit 1; }
TAG="v$VERSION"

# Refuse to release uncommitted work — the tag should match the repo.
if [ -n "$(git status --porcelain)" ]; then
    echo "Working tree has uncommitted changes — commit & push first."
    exit 1
fi

if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Release $TAG already exists. Bump VERSION in build.sh first."
    exit 1
fi

echo "==> Releasing $TAG"
./build.sh
./makedmg.sh
./notarize.sh

# Release notes: the CHANGELOG section for this version, if present.
NOTES_FILE="$(mktemp)"
awk -v v="$VERSION" '
    $0 ~ "^## " v " " || $0 ~ "^## " v "$" {grab=1; next}
    grab && /^## / {exit}
    grab {print}
' CHANGELOG.md > "$NOTES_FILE"
if [ ! -s "$NOTES_FILE" ]; then
    echo "See CHANGELOG.md for details." > "$NOTES_FILE"
    echo "(No CHANGELOG section found for $VERSION - using a generic note.)"
fi

echo "==> Creating GitHub release $TAG..."
git push
gh release create "$TAG" "dist/LED-OCD.dmg" \
    --title "LED OCD for Mac $VERSION" \
    --notes-file "$NOTES_FILE"
rm -f "$NOTES_FILE"

echo ""
echo "Done: $(gh release view "$TAG" --json url -q .url)"
