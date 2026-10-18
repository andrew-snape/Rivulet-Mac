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
xcodebuild -scheme "Rivulet Mac" -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$build" build >/dev/null

app=$build/Build/Products/Release/Rivulet.app
built=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ $built == "$version" ]] || { echo "App is version $built, not $version" >&2; exit 1; }

zip=$stage/Rivulet-$version-arm64.zip
ditto -c -k --keepParent "$app" "$zip"

tools=$build/SourcePackages/artifacts/sparkle/Sparkle/bin
"$tools/generate_appcast" --download-url-prefix "https://github.com/$repo/releases/download/$tag/" "$stage"

gh release create "$tag" "$zip" "$stage/appcast.xml" --repo "$repo" --target main \
  --title "Rivulet for Mac $tag" --generate-notes
