#!/usr/bin/env bash
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "=========================================="
echo "  📦 Building & Installing SwaprTrans ... "
echo "=========================================="

# 1. Fast incremental build for host architecture
swift build -c release

BIN_PATH="$REPO_ROOT/.build/release/SwaprTrans"
APP_DEST="/Applications/SwaprTrans.app"
CONTENTS_DIR="$APP_DEST/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# 2. Terminate currently running instance
killall SwaprTrans 2>/dev/null || true
sleep 0.5

# 3. In-place update App Bundle (preserve directory inode to maintain macOS TCC permissions)
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

cp -f "$BIN_PATH" "$MACOS_DIR/SwaprTrans"
chmod +x "$MACOS_DIR/SwaprTrans"

if [ -f "$REPO_ROOT/assets/AppIcon.icns" ]; then
    cp -f "$REPO_ROOT/assets/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

VERSION="${1:-1.0.0}"
VERSION="${VERSION#v}"
BUILD_NUMBER="1"

GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "dev")
GIT_DATE=$(git log -1 --format="%cd" --date=short 2>/dev/null || echo "")
GIT_MSG=$(git log -1 --format="%s" 2>/dev/null || echo "")

cat <<INFOEOF > "$CONTENTS_DIR/Info.plist"
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

# 4. Clean quarantine attributes before signing
xattr -cr "$APP_DEST"

# 5. Code signing with persistent requirement
echo "Signing /Applications/SwaprTrans.app..."
DR_REQ='designated => identifier "com.linrol.SwaprTrans"'

if security find-identity -v -p codesigning | grep -q "Teams Wake Dev"; then
    echo "Found signing identity: Teams Wake Dev"
    codesign --force --deep -r="$DR_REQ" --sign "Teams Wake Dev" "$APP_DEST"
elif security find-identity -v -p codesigning | grep -q "Apple Development"; then
    IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -n 1 | awk -F '"' '{print $2}')
    echo "Found signing identity: $IDENTITY"
    codesign --force --deep -r="$DR_REQ" --sign "$IDENTITY" "$APP_DEST"
else
    echo "Using ad-hoc signature (-s -)..."
    codesign --force --deep --sign - "$APP_DEST"
fi

xattr -cr "$APP_DEST"

echo "=========================================="
echo "  🎉 Installed to /Applications/SwaprTrans.app"
echo "  🚀 Launching..."
echo "=========================================="

open "$APP_DEST"
