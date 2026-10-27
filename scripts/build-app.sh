#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-1.0.0}"
VERSION="${VERSION#v}"
BUILD_NUMBER="${2:-1}"

echo "=========================================="
echo "  🔨 Building SwaprTrans.app (v${VERSION}) ... "
echo "=========================================="

# 1. Build release binary
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
DIST_DIR="$ROOT/dist"
APP="$DIST_DIR/SwaprTrans.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

# 2. Package App Bundle
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

cp -f "$BIN_DIR/SwaprTrans" "$MACOS/SwaprTrans"
chmod +x "$MACOS/SwaprTrans"

if [ -f "$ROOT/assets/AppIcon.icns" ]; then
  cp -f "$ROOT/assets/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "release")
GIT_DATE=$(git log -1 --format="%cd" --date=short 2>/dev/null || echo "")
GIT_MSG=$(git log -1 --format="%s" 2>/dev/null || echo "")

cat <<INFOEOF > "$CONTENTS/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SwaprTrans</string>
    <key>CFBundleIdentifier</key>
    <string>com.linrol.SwaprTrans</string>
    <key>CFBundleName</key>
    <string>SwaprTrans</string>
    <key>CFBundleDisplayName</key>
    <string>SwaprTrans</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>GitCommit</key>
    <string>${GIT_COMMIT}</string>
    <key>GitCommitDate</key>
    <string>${GIT_DATE}</string>
    <key>GitCommitMessage</key>
    <string>${GIT_MSG}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.2</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
INFOEOF

# 3. Clean attributes and ad-hoc sign
xattr -cr "$APP"

DR_REQ='designated => identifier "com.linrol.SwaprTrans"'
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Teams Wake Dev"; then
    codesign --force --deep -r="$DR_REQ" --sign "Teams Wake Dev" "$APP"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
    IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -n 1 | awk -F '"' '{print $2}')
    codesign --force --deep -r="$DR_REQ" --sign "$IDENTITY" "$APP"
else
    codesign --force --deep --sign - "$APP"
fi

xattr -cr "$APP"

echo "✅ Successfully built: $APP"
