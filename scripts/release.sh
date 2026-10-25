#!/bin/zsh
# Publish a Parlo release that installed copies pick up through Sparkle.
# Bumps the version in project.yml, builds and signs, zips the app, signs the zip for Sparkle
# (EdDSA key "parlo" in the login keychain), commits and tags, then uploads the zip and the appcast
# to a GitHub release. The app reads releases/latest/download/appcast.xml.
# Usage: scripts/release.sh 0.2.0
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:?usage: scripts/release.sh <version>}
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Version looks like 0.2.0, without v."; exit 1; }
[[ $(git branch --show-current) == main ]] || { echo "Release from main."; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "Commit or stash your changes first."; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Log in to GitHub first: gh auth login."; exit 1; }
git pull --quiet --ff-only
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null || [[ -n $(git ls-remote --tags origin "v$version") ]]; then
  echo "v$version already exists."; exit 1
fi

# Until the release commit exists, a failure puts the version files back so the script can be rerun.
trap 'git checkout --quiet -- project.yml App/Info.plist App/Parlo.entitlements' ERR

build=$(( $(sed -n 's/^ *CFBundleVersion: "\(.*\)"$/\1/p' project.yml) + 1 ))
sed -i '' -e "s/CFBundleShortVersionString: \".*\"/CFBundleShortVersionString: \"$version\"/" \
  -e "s/CFBundleVersion: \".*\"/CFBundleVersion: \"$build\"/" project.yml

./scripts/build.sh
app=build/DerivedData/Build/Products/Release/Parlo.app
dist=build/release/$version
rm -rf "$dist" && mkdir -p "$dist"
ditto -c -k --sequesterRsrc --keepParent "$app" "$dist/Parlo-$version.zip"
build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast --account parlo \
  --download-url-prefix "https://github.com/mariomile/parlo/releases/download/v$version/" "$dist"

git commit --quiet -am "Release $version"
trap - ERR
git tag "v$version"
git push --quiet origin main "v$version"
gh release create "v$version" "$dist/Parlo-$version.zip" "$dist/appcast.xml" \
  --title "Parlo $version" --generate-notes
echo "Released Parlo $version (build $build)"
