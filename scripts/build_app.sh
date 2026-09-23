#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="DoubaoVoiceHelper"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"
LOCAL_SIGNING_IDENTITY="${LOCAL_SIGNING_IDENTITY:-DoubaoVoiceHelper Development}"
BIN_DIR="$(swift build --package-path "$ROOT_DIR" -c "$CONFIGURATION" --show-bin-path)"

swift build \
    --package-path "$ROOT_DIR" \
    -c "$CONFIGURATION" \
    --product DoubaoVoiceHelper

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$ROOT_DIR"/Resources/MenuBar/*.png "$APP_DIR/Contents/Resources/"

if ! command -v codesign >/dev/null 2>&1; then
    echo "codesign is required to build $APP_NAME.app" >&2
    exit 1
fi

KEYCHAIN_ARG=""
if [ -n "${CODESIGN_KEYCHAIN:-}" ] && [ -f "${CODESIGN_KEYCHAIN:-}" ]; then
    KEYCHAIN_ARG="--keychain $CODESIGN_KEYCHAIN"
    FIND_ARG="$CODESIGN_KEYCHAIN"
else
    FIND_ARG=""
fi

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    SIGNING_IDENTITY="$CODESIGN_IDENTITY"
elif security find-identity -v -p codesigning $FIND_ARG 2>/dev/null | grep -Fq "\"$LOCAL_SIGNING_IDENTITY\""; then
    SIGNING_IDENTITY="$LOCAL_SIGNING_IDENTITY"
else
    echo "No stable signing identity named \"$LOCAL_SIGNING_IDENTITY\" was found. Falling back to ad-hoc signing (-)." >&2
    SIGNING_IDENTITY="-"
fi

# The bundle contains a single executable and no nested code, so --deep is
# unnecessary. Hardened Runtime is required for notarization and needs no
# extra entitlements for event taps or Accessibility.
if [ "$SIGNING_IDENTITY" = "-" ]; then
    codesign --force --sign "-" "$APP_DIR"
else
    TIMESTAMP_ARG=""
    case "$SIGNING_IDENTITY" in
        "Developer ID Application:"*) TIMESTAMP_ARG="--timestamp" ;;
    esac
    codesign --force --options runtime $TIMESTAMP_ARG $KEYCHAIN_ARG --sign "$SIGNING_IDENTITY" "$APP_DIR"
fi
codesign --verify --strict "$APP_DIR"

echo "Built $APP_DIR"
echo "Signed with $SIGNING_IDENTITY"
