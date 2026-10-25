#!/bin/zsh
# Build Parlo (Release) and sign it, Sparkle's helpers included, with the stable "Parlo Development" identity.
# Prints nothing but xcodebuild's tail; the app is at build/DerivedData/Build/Products/Release/Parlo.app.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/make-signing-identity.sh
xcodegen generate --quiet
xcodebuild -project Parlo.xcodeproj -scheme Parlo -configuration Release \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' build | tail -3

app=build/DerivedData/Build/Products/Release/Parlo.app
sign() { codesign --force --sign "Parlo Development" --options runtime "$@"; }
# Inside out, as Sparkle documents for re-signing: every nested binary must carry the app's identity.
sparkle=$app/Contents/Frameworks/Sparkle.framework/Versions/B
sign "$sparkle/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"
sign "$app/Contents/Frameworks/Sparkle.framework"
sign --entitlements App/Parlo.entitlements "$app"
