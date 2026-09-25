#!/bin/sh
set -e
cd "$(dirname "$0")"
APP=build/PhotoKitPair.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
swiftc -O -target arm64-apple-macos15.0 main.swift -o "$APP/Contents/MacOS/PhotoKitPair"
xattr -cr "$APP"
codesign --force --sign - "$APP"
