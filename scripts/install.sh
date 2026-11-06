#!/usr/bin/env bash
# Builds Flusso (Release) and installs it into /Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

command -v xcodegen >/dev/null || { echo "Installa xcodegen: brew install xcodegen"; exit 1; }

if [[ ! -f build/engine/lib/libtranscribe.a ]]; then
  command -v cmake >/dev/null || { echo "Installa cmake e ninja: brew install cmake ninja"; exit 1; }
  ./scripts/build-engine.sh
fi

xcodegen generate
xcodebuild -project Flusso.xcodeproj -scheme Flusso -configuration Release \
  -derivedDataPath build/dd-release build | grep -E "error:|warning: |BUILD" || true

APP="build/dd-release/Build/Products/Release/Flusso.app"
[[ -d "$APP" ]] || { echo "Build fallita"; exit 1; }

# Quit a running copy, then replace it.
osascript -e 'tell application id "dev.igol.flusso" to quit' >/dev/null 2>&1 || true
pkill -x Flusso >/dev/null 2>&1 || true
sleep 0.5
rm -rf /Applications/Flusso.app
ditto "$APP" /Applications/Flusso.app
echo "Installato in /Applications/Flusso.app"

if [[ "${1:-}" != "--no-launch" ]]; then
  open /Applications/Flusso.app
fi
