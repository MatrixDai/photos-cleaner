#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --product PhotosCleaner
app=build/PhotosCleaner.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --arch arm64 --show-bin-path)/PhotosCleaner" "$app/Contents/MacOS/PhotosCleaner"
cp App/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - --options runtime --entitlements App/PhotosCleaner.entitlements "$app"
echo "$PWD/$app"
