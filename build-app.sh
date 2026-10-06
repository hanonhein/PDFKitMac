#!/bin/bash
# Builds "PDF Kit.app" into the build/ folder. Run: ./build-app.sh
set -e
cd "$(dirname "$0")"
mkdir -p build

# Workaround: some Macs have an old leftover file in the Command Line Tools
# (usr/include/swift/module.modulemap) that breaks the build. We hide it here.
EXTRA=()
OLD=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
if [ -f "$OLD" ] && [ -f "$(dirname "$OLD")/bridging.modulemap" ]; then
    : > build/empty.modulemap
    cat > build/fix-clt.yaml <<YAML
{ "version": 0, "case-sensitive": false, "roots": [ { "type": "directory",
  "name": "$(dirname "$OLD")",
  "contents": [ { "type": "file", "name": "module.modulemap", "external-contents": "$PWD/build/empty.modulemap" } ] } ] }
YAML
    EXTRA=(-vfsoverlay build/fix-clt.yaml -Xcc -ivfsoverlay -Xcc build/fix-clt.yaml)
fi

swiftc -O -parse-as-library -target arm64-apple-macos14.0 "${EXTRA[@]}" \
    Sources/PDFKitMac/*.swift -o build/PDFKitMac

APP="build/PDF Kit.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/PDFKitMac "$APP/Contents/MacOS/PDFKitMac"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PDF Kit</string>
    <key>CFBundleDisplayName</key><string>PDF Kit</string>
    <key>CFBundleIdentifier</key><string>com.devhein.pdfkit.mac</string>
    <key>CFBundleExecutable</key><string>PDFKitMac</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Sign it just for this Mac (free, no Apple account needed)
codesign --force --sign - "$APP"
echo "Built: $APP"
