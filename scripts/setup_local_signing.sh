#!/bin/bash
set -euo pipefail

IDENTITY_NAME="${LOCAL_SIGNING_IDENTITY:-DoubaoVoiceHelper Development}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
CERTIFICATE_FILE="$(mktemp "${TMPDIR:-/tmp}/doubao-voice-helper-cert.XXXXXX.pem")"
PRIVATE_KEY_FILE="$(mktemp "${TMPDIR:-/tmp}/doubao-voice-helper-key.XXXXXX.pem")"
PKCS12_FILE="$(mktemp "${TMPDIR:-/tmp}/doubao-voice-helper-identity.XXXXXX.p12")"
trap 'rm -f "$CERTIFICATE_FILE" "$PRIVATE_KEY_FILE" "$PKCS12_FILE"' EXIT

if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl is required to create the local signing identity." >&2
    exit 1
fi

if ! command -v security >/dev/null 2>&1; then
    echo "security is required to install the local signing identity." >&2
    exit 1
fi

if security find-identity -v -p codesigning 2>/dev/null \
    | grep -Fq "\"$IDENTITY_NAME\""; then
    echo "Signing identity already exists: $IDENTITY_NAME"
    exit 0
fi

if [ ! -f "$KEYCHAIN" ]; then
    echo "Login keychain not found: $KEYCHAIN" >&2
    exit 1
fi

echo "Creating local signing identity: $IDENTITY_NAME"
PKCS12_PASSWORD="$(openssl rand -hex 32)"

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$PRIVATE_KEY_FILE" \
    -out "$CERTIFICATE_FILE" \
    -days 3650 \
    -subj "/CN=$IDENTITY_NAME" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    >/dev/null 2>&1

openssl pkcs12 -export -legacy \
    -inkey "$PRIVATE_KEY_FILE" \
    -in "$CERTIFICATE_FILE" \
    -out "$PKCS12_FILE" \
    -passout "pass:$PKCS12_PASSWORD" \
    -name "$IDENTITY_NAME" \
    >/dev/null 2>&1

security import "$PKCS12_FILE" \
    -k "$KEYCHAIN" \
    -P "$PKCS12_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    >/dev/null

security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$KEYCHAIN" \
    "$CERTIFICATE_FILE" \
    >/dev/null

if ! security find-identity -v -p codesigning 2>/dev/null \
    | grep -Fq "\"$IDENTITY_NAME\""; then
    echo "The local signing identity was not installed successfully." >&2
    exit 1
fi

echo "Created stable local signing identity: $IDENTITY_NAME"
echo "It is stored in the login keychain and is not part of the repository."
