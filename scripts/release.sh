#!/usr/bin/env bash
# Builds a universal (Apple Silicon + Intel), Developer ID–signed, notarized
# Flusso-<version>.dmg and .zip in build/release, plus the Sparkle appcast.xml
# that offers the .zip as an in-app update. Publish with scripts/publish.sh.
# Same setup as ImmichGallery (see docs/Updates.md).
#
# Requirements (one-time, same account as QuotaDeck/ImmichGallery):
#   - "Developer ID Application" certificate in the login keychain
#   - Notary credentials, either:
#       NOTARY_PROFILE=<name>   (xcrun notarytool store-credentials; default quotadeck-notary)
#     or an App Store Connect API key:
#       NOTARY_KEY=/path/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX NOTARY_ISSUER=<issuer-uuid>
#     Both can be kept in .release.env at the repo root (ignored by Git).
#   - The Sparkle EdDSA private key in the login keychain (shared with ImmichGallery)
#
#   - A logged-in desktop session: Finder lays out the DMG window (scripts/create-dmg.sh)
#
# Usage:  RELEASE_NOTES=notes.md ./scripts/release.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Machine-local notarization configuration, intentionally excluded from version control.
if [[ -f .release.env ]]; then
  source .release.env
fi

APP=Flusso
OUT=build/release
DERIVED=build/dd-release
PACKAGES=build/SourcePackages
SPARKLE_BIN=$PACKAGES/artifacts/sparkle/Sparkle/bin
REPO_URL=https://github.com/IGOLz/flusso
if [[ -n "${NOTARY_KEY:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" && -z "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
  NOTARY_ARGS=(--keychain-profile "${NOTARY_PROFILE:-quotadeck-notary}")
fi
[[ -z "${RELEASE_NOTES:-}" || -f "$RELEASE_NOTES" ]] || { echo "RELEASE_NOTES file not found: $RELEASE_NOTES" >&2; exit 1; }

IDENTITY="$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application identity found" >&2; exit 1; }

if [[ ! -f build/engine/lib/libtranscribe.a ]] || [[ "$(lipo -archs build/engine/lib/libtranscribe.a)" != *x86_64* ]]; then
  ./scripts/build-engine.sh
fi
if [[ ! -f build/llm/lib/libflusso-llm.dylib ]]; then
  ./scripts/build-llm.sh
fi

# Submits to Apple and fails unless the result is Accepted.
notarize() {
  local result id status
  echo "→ Notarizing $1"
  result="$(xcrun notarytool submit "$1" "${NOTARY_ARGS[@]}" --wait --timeout 30m --output-format json)"
  id="$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$result")"
  status="$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$result")"
  echo "  $id: $status"
  if [[ "$status" != "Accepted" ]]; then
    xcrun notarytool log "$id" "${NOTARY_ARGS[@]}" >&2 || true
    exit 1
  fi
}

# 1. Universal Release build.
xcodegen generate
mkdir -p build
LOG=build/release-build.log
rm -rf "$DERIVED/Build/Products/Release/$APP.app"
echo "→ Building (log: $LOG)"
if ! xcodebuild -project $APP.xcodeproj -scheme $APP -configuration Release \
  -derivedDataPath "$DERIVED" -clonedSourcePackagesDirPath "$PACKAGES" \
  ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" clean build >"$LOG" 2>&1; then
  grep -E "error:" "$LOG" | head -40 >&2 || true
  echo "Build failed — full log: $LOG" >&2
  exit 1
fi

rm -rf "$OUT" && mkdir -p "$OUT"
ditto "$DERIVED/Build/Products/Release/$APP.app" "$OUT/$APP.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$OUT/$APP.app/Contents/Info.plist")"
FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$OUT/$APP.app/Contents/Info.plist")"
echo "→ $APP $VERSION — $(lipo -archs "$OUT/$APP.app/Contents/MacOS/$APP") — $IDENTITY"

# 2. Sparkle ships its helpers ad-hoc signed: sign them with the Developer ID
#    (no --deep: the Downloader has its own entitlements), then re-seal the app.
echo "→ Signing Sparkle helpers"
SPARKLE="$OUT/$APP.app/Contents/Frameworks/Sparkle.framework"
resign() { codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@"; }
resign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
resign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
resign "$SPARKLE/Versions/B/Autoupdate"
resign "$SPARKLE/Versions/B/Updater.app"
resign "$SPARKLE"
resign --entitlements App/Flusso.entitlements "$OUT/$APP.app"
codesign --verify --deep --strict "$OUT/$APP.app"
if codesign -d --entitlements - "$OUT/$APP.app" 2>/dev/null | grep -q get-task-allow; then
  echo "The app carries get-task-allow: notarization would be rejected" >&2; exit 1
fi

# 3. Notarize and staple the app itself (opens offline once installed).
ditto -c -k --keepParent "$OUT/$APP.app" "$OUT/$APP-notarize.zip"
notarize "$OUT/$APP-notarize.zip"
xcrun stapler staple "$OUT/$APP.app"
rm "$OUT/$APP-notarize.zip"

# 4. Zip of the stapled app: the in-app update payload.
ditto -c -k --keepParent "$OUT/$APP.app" "$OUT/$APP-$VERSION.zip"

# 5. Drag-to-Applications disk image, signed, notarized and stapled.
#    Background, icon layout and window size come from scripts/create-dmg.sh.
scripts/create-dmg.sh "$OUT/$APP.app" "$VERSION" "$OUT/$APP-$VERSION.dmg"
codesign --force --sign "$IDENTITY" --timestamp "$OUT/$APP-$VERSION.dmg"
notarize "$OUT/$APP-$VERSION.dmg"
xcrun stapler staple "$OUT/$APP-$VERSION.dmg"

# 6. Sparkle appcast: the published feed plus this version's .zip, signed with
#    the EdDSA key. Older entries are kept, so Macs that can't run a newer
#    version still find the last one they can.
echo "→ Generating the update feed"
UPDATES="$(mktemp -d)"
STATUS="$(curl -sSL -o "$UPDATES/appcast.xml" -w '%{http_code}' "$FEED_URL")"
case $STATUS in
  200) ;;
  404) rm -f "$UPDATES/appcast.xml"; echo "  No published feed yet: starting a new one." ;;
  *) echo "Could not download the published feed ($STATUS): $FEED_URL" >&2; exit 1 ;;
esac
cp "$OUT/$APP-$VERSION.zip" "$UPDATES/"
if [[ -n "${RELEASE_NOTES:-}" ]]; then
  cp "$RELEASE_NOTES" "$UPDATES/$APP-$VERSION.md"
  cp "$RELEASE_NOTES" "$OUT/release-notes.md"
fi
"$SPARKLE_BIN/generate_appcast" --embed-release-notes --maximum-versions 0 \
  --download-url-prefix "$REPO_URL/releases/download/v$VERSION/" \
  --full-release-notes-url "$REPO_URL/releases" --link "$REPO_URL" \
  "$UPDATES"
cp "$UPDATES/appcast.xml" "$OUT/appcast.xml"
rm -rf "$UPDATES"
grep -q "v$VERSION/$APP-$VERSION.zip" "$OUT/appcast.xml" || { echo "appcast.xml has no entry for $VERSION." >&2; exit 1; }

echo "→ Gatekeeper checks"
spctl -a -vv -t exec "$OUT/$APP.app"
spctl -a -vv -t open --context context:primary-signature "$OUT/$APP-$VERSION.dmg"

(cd "$OUT" && shasum -a 256 "$APP-$VERSION.dmg" "$APP-$VERSION.zip" | tee SHA256SUMS.txt)
echo "✓ $ROOT/$OUT/$APP-$VERSION.dmg"
echo "  Publish with: scripts/publish.sh"
