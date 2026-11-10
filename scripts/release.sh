#!/bin/zsh
# Build, sign the update, and publish a GitHub release that Sparkle picks up.
#   scripts/release.sh 0.2.0
# Before running: set MARKETING_VERSION to the version and raise
# CURRENT_PROJECT_VERSION (Sparkle compares the build number), then commit
# and push. The EdDSA private key is read from the login keychain
# (created once with Sparkle's generate_keys).
set -euo pipefail

version=${1:?usage: scripts/release.sh <version>}
tag="v$version"
repo=andrew-snape/Rivulet-Mac
root=${0:A:h:h}
build=/tmp/rivulet-release
stage=$build/stage

cd "$root"
[[ -z $(git status --porcelain) ]] || { echo "Working tree is not clean" >&2; exit 1; }
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || { echo "HEAD is not pushed to origin/main" >&2; exit 1; }

rm -rf "$build" && mkdir -p "$stage"
echo "Building $version (a few minutes; log at $build.log)"
xcodebuild -scheme "Rivulet Mac" -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$build" build >"$build.log" 2>&1 \
  || { tail -40 "$build.log" >&2; echo "Build failed, see $build.log" >&2; exit 1; }

app=$build/Build/Products/Release/Rivulet.app
built=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ $built == "$version" ]] || { echo "App is version $built, not $version" >&2; exit 1; }

# Sparkle compares the build number, so it must beat the latest published one
# or installed copies are never offered this release.
new_build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")
if appcast=$(curl -fsSL "https://github.com/$repo/releases/latest/download/appcast.xml" 2>/dev/null); then
  # Accepts the element form and the enclosure attribute form. A no-match grep
  # must not trip set -e / pipefail, hence the trailing || true.
  last_build=$(print -r -- "$appcast" \
    | grep -oE '<sparkle:version>[0-9]+<|sparkle:version="[0-9]+"' \
    | grep -oE '[0-9]+' | sort -n | tail -1 || true)
  if [[ -z $last_build ]]; then
    echo "Note: no sparkle:version in the published appcast, skipping the build number check"
  else
    [[ $new_build =~ ^[0-9]+$ && $last_build =~ ^[0-9]+$ ]] \
      || { echo "Build numbers are not integers (new '$new_build', published '$last_build')" >&2; exit 1; }
    (( new_build > last_build )) \
      || { echo "Build number $new_build is not higher than the published $last_build; raise CURRENT_PROJECT_VERSION" >&2; exit 1; }
  fi
else
  echo "Note: could not fetch the published appcast (no release yet?), skipping the build number check"
fi

zip=$stage/Rivulet-$version-arm64.zip
ditto -c -k --keepParent "$app" "$zip"

tools=$build/SourcePackages/artifacts/sparkle/Sparkle/bin
"$tools/generate_appcast" --download-url-prefix "https://github.com/$repo/releases/download/$tag/" "$stage"

gh release create "$tag" "$zip" "$stage/appcast.xml" --repo "$repo" --target main \
  --title "Rivulet for Mac $tag" --generate-notes
