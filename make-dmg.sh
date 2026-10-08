#!/bin/bash
# Makes the installer: build/PDFEditorKit-<version>-mac.dmg
# (open it, drag PDF Editor Kit into Applications). Run: ./make-dmg.sh
set -e
cd "$(dirname "$0")"
./build-app.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "build/PDF Editor Kit.app/Contents/Info.plist")
DMG="build/PDFEditorKit-$VERSION-mac.dmg"
STAGE=build/dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "build/PDF Editor Kit.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # so people can drag the app onto it

hdiutil create -volname "PDF Editor Kit" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Made: $DMG ($(du -h "$DMG" | cut -f1))"
