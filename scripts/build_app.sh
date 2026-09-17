#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
BIN_DIR="$(swift build --package-path "$ROOT_DIR" -c "$CONFIGURATION" --show-bin-path)"

swift build \
    --package-path "$ROOT_DIR" \
    -c "$CONFIGURATION" \
    --product DoubaoVoiceHelper

APP_DIR="$ROOT_DIR/build/DoubaoVoiceHelper.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/DoubaoVoiceHelper" "$APP_DIR/Contents/MacOS/DoubaoVoiceHelper"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP_DIR"
fi

echo "Built $APP_DIR"
