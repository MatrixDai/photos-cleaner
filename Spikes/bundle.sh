#!/bin/sh
set -eu
cd "$(dirname "$0")"

swift build -c release --product PhotosSpike
app=build/PhotosSpike.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/PhotosSpike" "$app/Contents/MacOS/PhotosSpike"
cp Info.plist "$app/Contents/Info.plist"
# Hardened Runtime would also need the photos-library entitlement, so the throwaway spike is signed without it.
codesign --force --sign - "$app"
echo "$PWD/$app"
