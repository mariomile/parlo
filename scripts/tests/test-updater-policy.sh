#!/bin/zsh
# Instantiate an unstarted updater for a temporary host; no app launches, checks or installations.
set -euo pipefail
cd "$(dirname "$0")/../.."
frameworks="$PWD/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
[[ -d "$frameworks/Sparkle.framework" ]] || { echo "Build once to make pinned Sparkle available."; exit 1; }
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
swiftc scripts/tests/UpdaterPolicy.swift -F "$frameworks" -framework Sparkle \
  -Xlinker -rpath -Xlinker "$frameworks" -o "$output/policy"
"$output/policy" App/Info.plist
