#!/bin/bash
# Makes the installer: build/PDFKit-<version>-mac.dmg
# (open it, drag PDF Kit into Applications). Run: ./make-dmg.sh
set -e
cd "$(dirname "$0")"
./build-app.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "build/PDF Kit.app/Contents/Info.plist")
DMG="build/PDFKit-$VERSION-mac.dmg"
STAGE=build/dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "build/PDF Kit.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # so people can drag the app onto it

hdiutil create -volname "PDF Kit" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Made: $DMG ($(du -h "$DMG" | cut -f1))"
