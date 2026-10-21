#!/bin/sh
set -eu
THUIS_SOURCE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
THUIS_APP="$THUIS_SOURCE/Thuis Control.app"
mkdir -p "$THUIS_APP/Contents/MacOS" "$THUIS_APP/Contents/Resources"
xcrun swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 -framework SwiftUI -framework AppKit "$THUIS_SOURCE/ThuisControl.swift" "$THUIS_SOURCE/ControlCenter.swift" "$THUIS_SOURCE/TVNetwork.swift" "$THUIS_SOURCE/TVBackend.swift" "$THUIS_SOURCE/TVDevicesView.swift" -framework Security -o "$THUIS_APP/Contents/MacOS/ThuisControl"
if [ -f "$THUIS_SOURCE/Thuis.icns" ]; then cp "$THUIS_SOURCE/Thuis.icns" "$THUIS_APP/Contents/Resources/Thuis.icns"; fi
cat > "$THUIS_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIconFile</key><string>Thuis</string><key>CFBundleExecutable</key><string>ThuisControl</string><key>CFBundleIdentifier</key><string>nl.dextiny.thuis.control</string><key>CFBundleName</key><string>Thuis Control</string><key>CFBundleDisplayName</key><string>Thuis Control</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>3.0.0</string><key>CFBundleVersion</key><string>3</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>NSHighResolutionCapable</key><true/><key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict><key>NSLocalNetworkUsageDescription</key><string>Thuis Control bedient je LG-tv en stuurt wekberichten op je lokale netwerk.</string></dict></plist>
PLIST
codesign --force --sign - "$THUIS_APP"
echo "$THUIS_APP"
