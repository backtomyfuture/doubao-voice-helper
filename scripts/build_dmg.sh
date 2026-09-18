#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="DoubaoVoiceHelper"
APP_PATH="${APP_PATH:-$ROOT_DIR/build/$APP_NAME.app}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/build}"
DMG_PATH="${DMG_PATH:-$OUTPUT_DIR/$APP_NAME.dmg}"
BACKGROUND="$ROOT_DIR/Resources/DMG/dmg_background.png"

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "create-dmg is required to build $APP_NAME.dmg" >&2
    echo "Install it with: brew install create-dmg" >&2
    exit 1
fi

if [ ! -d "$APP_PATH" ]; then
    echo "App not found at $APP_PATH. Run ./scripts/build_app.sh first." >&2
    exit 1
fi

if [ ! -f "$BACKGROUND" ]; then
    echo "DMG background not found at $BACKGROUND" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/doubao-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
cp -R "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
rm -f "$DMG_PATH"

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

echo "Built $DMG_PATH"
