#!/bin/zsh
# Publish verified assets through a draft. Rerun the same version to resume after a failed push/upload.
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:?usage: scripts/release.sh <version>}
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Version looks like 0.2.0, without v."; exit 1; }
[[ $(git branch --show-current) == main ]] || { echo "Release from main."; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "Commit or stash your changes first."; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Log in to GitHub first: gh auth login."; exit 1; }

repo=mariomile/parlo
tag=v$version
dist=build/release/$version
archive=Parlo-$version.zip
download_url="https://github.com/$repo/releases/download/$tag/$archive"
# A failed API request must not be interpreted as 'release absent'. Pagination also covers older releases.
release_state=$(gh api --paginate "repos/$repo/releases?per_page=100" \
  --jq ".[] | select(.tag_name == \"$tag\") | .draft")
if [[ -n $(git ls-remote --tags origin "refs/tags/$tag") ]]; then
  # Fetch also detects a conflicting local tag; never replace either tag silently.
  git fetch --quiet origin "tag" "$tag"
fi
has_tag=false
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  has_tag=true
  [[ $(git rev-parse "$tag^{commit}") == $(git rev-parse HEAD) ]] || {
    echo "$tag belongs to a different commit. Resume from its release commit; no public assets were changed."; exit 1
  }
fi
[[ -z $release_state || $has_tag == true ]] || { echo "Existing release has no matching tag."; exit 1; }

# Identify a resume before advancing the checkout. A draft remains tied to its release commit
# even when origin/main subsequently advances; a failed push can also leave an untagged commit.
checkout_version=$(sed -n 's/^ *CFBundleShortVersionString: "\(.*\)"$/\1/p' project.yml)
resuming=false
if [[ $has_tag == true || ( $checkout_version == $version && $(git log -1 --format=%s) == "chore(release): $version" ) ]]; then
  resuming=true
fi
git fetch --quiet --no-tags origin refs/heads/main
remote_main=$(git rev-parse FETCH_HEAD)
if [[ $resuming == true ]]; then
  if ! git merge-base --is-ancestor HEAD "$remote_main" && ! git merge-base --is-ancestor "$remote_main" HEAD; then
    echo "The release commit and origin/main have diverged. Resolve the history before resuming."; exit 1
  fi
else
  git merge --quiet --ff-only "$remote_main"
fi
current_version=$(sed -n 's/^ *CFBundleShortVersionString: "\(.*\)"$/\1/p' project.yml)
build=$(sed -n 's/^ *CFBundleVersion: "\(.*\)"$/\1/p' project.yml)
public_key=$(sed -n 's/^ *SUPublicEDKey: //p' project.yml)
[[ -n $public_key && $build =~ '^[0-9]+$' ]] || { echo "Missing update public key or build number."; exit 1; }

version_changed=false
verification_dir=$(mktemp -d)
cleanup() {
  local result=$?
  rm -rf "$verification_dir"
  if [[ $version_changed == true ]]; then
    git restore --staged --worktree -- project.yml App/Info.plist App/Parlo.entitlements
  fi
  return $result
}
trap cleanup EXIT

verify_assets() {
  swift scripts/verify-appcast.swift "$1/appcast.xml" "$1/$archive" "$public_key" "$version" "$build" "$download_url"
}

if [[ $release_state == false ]]; then
  [[ $has_tag == true && $current_version == $version ]] || { echo "Published release does not match this checkout."; exit 1; }
  gh release download "$tag" --repo "$repo" --pattern "$archive" --pattern appcast.xml --dir "$verification_dir"
  verify_assets "$verification_dir" || exit $?
  echo "Parlo $version is already published and its downloaded assets verify."
  exit 0
fi

if [[ $current_version != $version ]]; then
  [[ $has_tag == false && -z $release_state ]] || { echo "Existing release/tag has a different version."; exit 1; }
  # Numeric semver ordering; never publish a lower version as the latest release.
  typeset -a requested existing
  requested=("${(@s:.:)version}")
  existing=("${(@s:.:)current_version}")
  newer=false
  for i in 1 2 3; do
    (( requested[i] < existing[i] )) && { echo "Release version must increase."; exit 1; }
    if (( requested[i] > existing[i] )); then newer=true; break; fi
  done
  [[ $newer == true ]] || { echo "Release version must increase."; exit 1; }
  build=$(( build + 1 ))
  version_changed=true
  sed -i '' -e "s/CFBundleShortVersionString: \".*\"/CFBundleShortVersionString: \"$version\"/" \
    -e "s/CFBundleVersion: \".*\"/CFBundleVersion: \"$build\"/" project.yml
elif [[ $has_tag == false && $(git log -1 --format=%s) != "chore(release): $version" ]]; then
  echo "This version is not a resumable release commit. Choose a newer version."; exit 1
fi

if [[ $version_changed == true || ! -f "$dist/source-commit" ]]; then
  ./scripts/build.sh
  sparkle=build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
  [[ $($sparkle/generate_keys --account parlo -p) == $public_key ]] || { echo "Signing key does not match SUPublicEDKey."; exit 1; }
  app=build/DerivedData/Build/Products/Release/Parlo.app
  codesign --verify --deep --strict "$app"
  rm -rf "$dist"
  mkdir -p "$dist"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$dist/$archive"
  "$sparkle/generate_appcast" --account parlo --download-url-prefix "https://github.com/$repo/releases/download/$tag/" "$dist"
  verify_assets "$dist" || exit $?
  # The build may regenerate only these tracked files. Never commit unrelated dependency changes.
  git diff --exit-code -- . ':!project.yml' ':!App/Info.plist' ':!App/Parlo.entitlements'
  if [[ $version_changed == true ]]; then
    git add -- project.yml App/Info.plist App/Parlo.entitlements
    git commit --quiet -m "chore(release): $version"
    version_changed=false
  else
    git diff --exit-code
  fi
  (cd "$dist"; shasum -a 256 "$archive" appcast.xml > SHA256SUMS.tmp; mv SHA256SUMS.tmp SHA256SUMS)
  git rev-parse HEAD > "$dist/source-commit.tmp"
  mv "$dist/source-commit.tmp" "$dist/source-commit"
else
  [[ $(cat "$dist/source-commit") == $(git rev-parse HEAD) ]] || { echo "Retained artifacts belong to another commit."; exit 1; }
  (cd "$dist"; shasum -a 256 -c SHA256SUMS)
  verify_assets "$dist" || exit $?
fi

[[ $has_tag == true ]] || git tag "$tag"
if git merge-base --is-ancestor HEAD "$remote_main"; then
  # The release is already in origin/main. Do not try to push an older main over later work.
  git push --quiet origin "refs/tags/$tag"
else
  git push --quiet --atomic origin main "refs/tags/$tag"
fi
if [[ -z $release_state ]]; then
  gh release create "$tag" --repo "$repo" --draft --verify-tag --title "Parlo $version" --generate-notes
fi
gh release upload "$tag" "$dist/$archive" "$dist/appcast.xml" --repo "$repo" --clobber
gh release download "$tag" --repo "$repo" --pattern "$archive" --pattern appcast.xml --dir "$verification_dir"
cmp "$dist/$archive" "$verification_dir/$archive"
cmp "$dist/appcast.xml" "$verification_dir/appcast.xml"
gh release edit "$tag" --repo "$repo" --draft=false --latest
echo "Released and verified Parlo $version (build $build)"
