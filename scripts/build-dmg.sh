#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-1.0.0}"
VERSION="${VERSION#v}"

# 1. Build .app bundle
bash "$ROOT/scripts/build-app.sh" "$VERSION"

APP="$ROOT/dist/SwaprTrans.app"
STAGE="$ROOT/dist/dmg-stage"
DMG="$ROOT/dist/SwaprTrans-${VERSION}.dmg"

echo "=========================================="
echo "  💿 Packaging SwaprTrans-${VERSION}.dmg ... "
echo "=========================================="

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/SwaprTrans.app"

if command -v create-dmg >/dev/null 2>&1; then
  echo "Using create-dmg for styled disk image..."
  VOLICON_ARG=()
  if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
    VOLICON_ARG=(--volicon "$APP/Contents/Resources/AppIcon.icns")
  fi

  create-dmg \
    --volname "SwaprTrans" \
    "${VOLICON_ARG[@]}" \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "SwaprTrans.app" 160 200 \
    --hide-extension "SwaprTrans.app" \
    --app-drop-link 440 200 \
    --overwrite \
    "$DMG" \
    "$STAGE/" || {
      echo "create-dmg failed or exited with status, falling back to hdiutil..."
      rm -f "$DMG"
      ln -s /Applications "$STAGE/Applications"
      hdiutil create -volname "SwaprTrans" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
    }
else
  echo "create-dmg not found, generating DMG via hdiutil..."
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "SwaprTrans" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
fi

rm -rf "$STAGE"

echo "=========================================="
echo "  🎉 Built DMG: $DMG"
ls -lh "$DMG"
echo "=========================================="
