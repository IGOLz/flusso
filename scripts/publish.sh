#!/usr/bin/env bash
# Publishes what scripts/release.sh built in build/release as the latest GitHub release.
#
# The release is created as a draft, gets all its files, and only then is
# published: installed apps read the update feed from the latest release's
# appcast.xml, so it never points at a release whose .zip isn't uploaded yet.
#
# Usage: scripts/publish.sh [--prerelease]
#   Notes come from build/release/release-notes.md (RELEASE_NOTES given to release.sh).
#   A pre-release is not "latest", so installed apps are not offered it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=Flusso
OUT=build/release
REPO=IGOLz/flusso
[[ -d "$OUT/$APP.app" ]] || { echo "Run scripts/release.sh first." >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$OUT/$APP.app/Contents/Info.plist")"
TAG="v$VERSION"
FILES=("$OUT/$APP-$VERSION.dmg" "$OUT/$APP-$VERSION.zip" "$OUT/appcast.xml" "$OUT/SHA256SUMS.txt")
for file in "${FILES[@]}"; do [[ -f "$file" ]] || { echo "Missing $file" >&2; exit 1; }; done
grep -q "$TAG/$APP-$VERSION.zip" "$OUT/appcast.xml" || { echo "appcast.xml has no entry for $VERSION." >&2; exit 1; }

NOTES=(--generate-notes)
[[ -f "$OUT/release-notes.md" ]] && NOTES=(--notes-file "$OUT/release-notes.md")
EXTRA=()
[[ "${1:-}" == "--prerelease" ]] && EXTRA=(--prerelease)

echo "→ Creating draft release $TAG"
gh release create "$TAG" -R "$REPO" --draft --title "$APP $VERSION" "${NOTES[@]}" "${EXTRA[@]+"${EXTRA[@]}"}" "${FILES[@]}"
echo "→ Publishing $TAG"
gh release edit "$TAG" -R "$REPO" --draft=false
echo "✓ https://github.com/$REPO/releases/tag/$TAG"
