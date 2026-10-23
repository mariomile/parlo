#!/bin/zsh
# Build Parlo (Release), sign it, install it to ~/Applications/Parlo.app and launch it.
# A stable install path and signing identity keep macOS privacy permissions across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/make-signing-identity.sh
xcodegen generate --quiet
xcodebuild -project Parlo.xcodeproj -scheme Parlo -configuration Release \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' build | tail -3

app=build/DerivedData/Build/Products/Release/Parlo.app
codesign --force --sign "Parlo Development" --options runtime \
  --entitlements App/Parlo.entitlements "$app"

mkdir -p ~/Applications
pkill -x Parlo 2>/dev/null || true
rm -rf ~/Applications/Parlo.app
cp -R "$app" ~/Applications/Parlo.app
open ~/Applications/Parlo.app
echo "Parlo installed in ~/Applications/Parlo.app"
