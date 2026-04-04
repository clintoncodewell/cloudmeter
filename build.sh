#!/bin/bash
set -e
cd "$(dirname "$0")"

# Compile
swiftc -O -o CloudMeter main.swift \
    -framework Cocoa \
    -framework UserNotifications \
    -sdk "$(xcrun --show-sdk-path)"

# Create .app bundle
APP="CloudMeter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
mv CloudMeter "$APP/Contents/MacOS/"

cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>co.advisewell.cloudmeter</string>
    <key>CFBundleName</key>
    <string>CloudMeter</string>
    <key>CFBundleDisplayName</key>
    <string>CloudMeter</string>
    <key>CFBundleExecutable</key>
    <string>CloudMeter</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

echo "Built CloudMeter.app ($(du -sh "$APP" | cut -f1 | xargs))"
