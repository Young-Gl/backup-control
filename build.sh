#!/bin/bash
# Builds "Backup Control.app" into ./build
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Backup Control.app"
CACHE=".modulecache"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/scripts" "$CACHE"

echo "==> Compiling"
swiftc -O -parse-as-library -module-cache-path "$CACHE" \
  Sources/main.swift \
  -o "$APP/Contents/MacOS/BackupControl" \
  -framework SwiftUI -framework AppKit

echo "==> Bundling resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp scripts/backup.sh scripts/estimate.py "$APP/Contents/Resources/scripts/"
chmod 755 "$APP/Contents/Resources/scripts/backup.sh"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Backup Control</string>
  <key>CFBundleDisplayName</key><string>Backup Control</string>
  <key>CFBundleIdentifier</key><string>dev.backupcontrol.app</string>
  <key>CFBundleExecutable</key><string>BackupControl</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed"

echo "==> Done: $APP"
