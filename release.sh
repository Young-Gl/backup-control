#!/bin/bash
# Build a universal .app and a distributable zip.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-1.0.0}"
APP="build/Backup Control.app"
DIST="dist"
NAME="BackupControl-$VERSION"

rm -rf "$APP" "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/scripts" "$DIST" build/cache-arm build/cache-x86

echo "==> Compiling (arm64)"
swiftc -O -parse-as-library -target arm64-apple-macos14.0 -module-cache-path build/cache-arm \
  Sources/main.swift -o build/arm64 -framework SwiftUI -framework AppKit

echo "==> Compiling (x86_64)"
swiftc -O -parse-as-library -target x86_64-apple-macos14.0 -module-cache-path build/cache-x86 \
  Sources/main.swift -o build/x86_64 -framework SwiftUI -framework AppKit

echo "==> Creating universal binary"
lipo -create build/arm64 build/x86_64 -output "$APP/Contents/MacOS/BackupControl"
lipo -archs "$APP/Contents/MacOS/BackupControl"

cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp scripts/backup.sh scripts/estimate.py "$APP/Contents/Resources/scripts/"
chmod 755 "$APP/Contents/Resources/scripts/backup.sh"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Backup Control</string>
  <key>CFBundleDisplayName</key><string>Backup Control</string>
  <key>CFBundleIdentifier</key><string>dev.backupcontrol.app</string>
  <key>CFBundleExecutable</key><string>BackupControl</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
xattr -c "$APP" 2>/dev/null || true
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
find "$APP" -name "._*" -delete 2>/dev/null || true
codesign --force --sign - "$APP/Contents/MacOS/BackupControl"
codesign --force --sign - "$APP"

echo "==> Packaging"
ditto -c -k --sequesterRsrc --keepParent --norsrc "$APP" "$DIST/$NAME.zip"
shasum -a 256 "$DIST/$NAME.zip" | tee "$DIST/$NAME.zip.sha256"

echo "==> Done"
ls -lh "$DIST"
