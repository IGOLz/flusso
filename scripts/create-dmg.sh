#!/bin/zsh
# Finder must be available in a logged-in macOS session during packaging.
set -euo pipefail
[[ $# == 3 && -d "$1" ]] || { echo "Usage: $0 app-path version output.dmg" >&2; exit 1; }
APP_PATH=${1:A}
VERSION=$2
OUTPUT=${3:A}
SCRIPTS=${0:A:h}
WORK=$(mktemp -d)
WORK=${WORK:A}
MOUNT="$WORK/mount"
detach_image() {
  for attempt in 1 2 3; do
    if hdiutil detach "$MOUNT" -quiet; then return 0; fi
    sleep 2
  done
  return 1
}
cleanup() {
  if mount | grep -Fq " on $MOUNT ("; then
    if ! detach_image; then
      echo "Could not eject $MOUNT; preserving temporary files at $WORK." >&2
      return 1
    fi
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$WORK/staging/.background"
ditto "$APP_PATH" "$WORK/staging/Flusso.app"
ln -s /Applications "$WORK/staging/Applications"
xcrun swift "$SCRIPTS/dmg/background.swift" "$WORK/staging/.background/install.tiff"
# A unique working name keeps Finder from targeting another mounted installer.
hdiutil create -quiet -volname "Flusso ${WORK:t}" -srcfolder "$WORK/staging" \
  -fs HFS+ -format UDRW "$WORK/writable.dmg"
hdiutil attach -quiet -nobrowse -mountpoint "$MOUNT" "$WORK/writable.dmg"
/usr/bin/osascript - "$MOUNT" <<'APPLESCRIPT'
on run argv
  set mountFolder to POSIX file (item 1 of argv) as alias
  tell application "Finder"
    open mountFolder
    set installerWindow to container window of mountFolder
    set current view of installerWindow to icon view
    set toolbar visible of installerWindow to false
    set statusbar visible of installerWindow to false
    set bounds of installerWindow to {200, 160, 840, 588}
    set options to icon view options of installerWindow
    set arrangement of options to not arranged
    set icon size of options to 96
    set text size of options to 13
    set background picture of options to file ".background:install.tiff" of mountFolder
    set position of item "Flusso.app" of mountFolder to {170, 205}
    set position of item "Applications" of mountFolder to {470, 205}
    set extension hidden of item "Flusso.app" of mountFolder to true
    close window id (id of installerWindow)
    open mountFolder
    update mountFolder without registering applications
    delay 2
    close window id (id of container window of mountFolder)
  end tell
end run
APPLESCRIPT
[[ -s "$MOUNT/.DS_Store" ]] || { echo "Finder did not save the installer layout." >&2; exit 1; }
diskutil rename "$MOUNT" "Flusso $VERSION" >/dev/null
sync
detach_image
hdiutil convert -quiet "$WORK/writable.dmg" -format UDZO -o "$OUTPUT"
hdiutil verify -quiet "$OUTPUT"
