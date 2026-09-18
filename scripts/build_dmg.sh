#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="DoubaoVoiceHelper"
APP_PATH="${APP_PATH:-$ROOT_DIR/build/$APP_NAME.app}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/build}"
DMG_PATH="${DMG_PATH:-$OUTPUT_DIR/$APP_NAME.dmg}"
BACKGROUND="$ROOT_DIR/Resources/DMG/dmg_background.png"

if [ ! -d "$APP_PATH" ]; then
    echo "App not found at $APP_PATH. Run ./scripts/build_app.sh first." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/doubao-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
cp -R "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
rm -f "$DMG_PATH"

if command -v create-dmg >/dev/null 2>&1 && [ -f "$BACKGROUND" ]; then
    create-dmg \
        --volname "豆包语音助手" \
        --background "$BACKGROUND" \
        --window-pos 200 120 \
        --window-size 660 400 \
        --icon-size 112 \
        --icon "$APP_NAME.app" 170 215 \
        --app-drop-link 490 215 \
        --hide-extension "$APP_NAME.app" \
        --no-internet-enable \
        "$DMG_PATH" \
        "$STAGING_DIR"
else
    echo "create-dmg not found or background missing, using native hdiutil to build DMG..."
    ln -s /Applications "$STAGING_DIR/Applications"
    hdiutil create \
        -volname "豆包语音助手" \
        -srcfolder "$STAGING_DIR" \
        -ov \
        -format UDZO \
        "$DMG_PATH"
fi

echo "Built $DMG_PATH"
