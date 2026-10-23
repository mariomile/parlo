#!/bin/zsh
# Build Parlo (Release), install it to ~/Applications/Parlo.app and launch it.
# A stable install path keeps macOS privacy permissions attached to the same app.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
xcodebuild -project Parlo.xcodeproj -scheme Parlo -configuration Release \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' build | tail -3

mkdir -p ~/Applications
pkill -x Parlo 2>/dev/null || true
rm -rf ~/Applications/Parlo.app
cp -R build/DerivedData/Build/Products/Release/Parlo.app ~/Applications/Parlo.app
open ~/Applications/Parlo.app
echo "Parlo installed in ~/Applications/Parlo.app"
