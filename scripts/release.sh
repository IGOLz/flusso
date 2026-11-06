#!/usr/bin/env bash
# Builds a universal (Apple Silicon + Intel), Developer ID–signed and
# notarized Flusso-<version>.dmg, ready to share.
#
# One-time setup (same account as QuotaDeck):
#   1. "Developer ID Application" certificate in the login keychain.
#   2. Notary credentials in the keychain:
#        xcrun notarytool store-credentials quotadeck-notary \
#          --apple-id <apple-id> --team-id 884UZN5CH3
#
# Usage: ./scripts/release.sh        Optional env: NOTARY_PROFILE
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROFILE="${NOTARY_PROFILE:-quotadeck-notary}"
SIGN_IDENTITY="$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
[[ -n "$SIGN_IDENTITY" ]] || { echo "No Developer ID Application identity found" >&2; exit 1; }

if [[ ! -f build/engine/lib/libtranscribe.a ]] || [[ "$(lipo -archs build/engine/lib/libtranscribe.a)" != *x86_64* ]]; then
  ./scripts/build-engine.sh
fi

xcodegen generate
DERIVED="build/dd-release"
LOG="build/release-build.log"
mkdir -p build
rm -rf "$DERIVED/Build/Products/Release/Flusso.app"
if ! xcodebuild -project Flusso.xcodeproj -scheme Flusso -configuration Release \
  -derivedDataPath "$DERIVED" ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" \
  clean build >"$LOG" 2>&1; then
  grep -E "error:" "$LOG" | head -40 >&2 || true
  echo "Build failed — full log: $LOG" >&2
  exit 1
fi

APP="$DERIVED/Build/Products/Release/Flusso.app"
[[ -d "$APP" ]] || { echo "Build produced no app — log: $LOG" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "Flusso $VERSION — $(lipo -archs "$APP/Contents/MacOS/Flusso") — $SIGN_IDENTITY"

codesign --verify --strict --deep "$APP"

if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
  echo "The app carries get-task-allow: notarization would be rejected" >&2; exit 1
fi

# Submits to Apple and fails unless the result is Accepted.
notarize() {
  local result id status
  result="$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json)"
  id="$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$result")"
  status="$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$result")"
  echo "Notarization $id: $status"
  if [[ "$status" != "Accepted" ]]; then
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
    exit 1
  fi
}

OUT="build/release"
rm -rf "$OUT" && mkdir -p "$OUT"

# 1. Notarize the app and staple its ticket (works offline once installed).
ditto -c -k --keepParent "$APP" "$OUT/Flusso.zip"
notarize "$OUT/Flusso.zip"
xcrun stapler staple "$APP"
rm -f "$OUT/Flusso.zip"

# 2. Disk image with a drag-to-Applications layout, signed and notarized too.
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Flusso.app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/Flusso-$VERSION.dmg"
hdiutil create -volname "Flusso" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

spctl --assess --type execute --verbose "$APP"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
echo "Ready: $ROOT/$DMG"
shasum -a 256 "$DMG"
