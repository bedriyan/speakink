#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$PROJECT_DIR/build/signing}"
CERTIFICATE_NAME="${SPEAKY_CERTIFICATE_NAME:-Speaky Open Source Release}"
CERTIFICATE_DAYS="${SPEAKY_CERTIFICATE_DAYS:-3650}"
P12_PATH="$OUTPUT_DIR/Speaky-Open-Source-Release.p12"
CERTIFICATE_PATH="$OUTPUT_DIR/Speaky-Open-Source-Release.cer"

if [ -z "${SPEAKY_CERTIFICATE_PASSWORD:-}" ]; then
    echo "ERROR: Set SPEAKY_CERTIFICATE_PASSWORD before generating signing assets."
    exit 1
fi

if [[ ! "$CERTIFICATE_NAME" =~ ^[A-Za-z0-9._[:space:]-]+$ ]]; then
    echo "ERROR: SPEAKY_CERTIFICATE_NAME contains unsupported characters."
    exit 1
fi

if [[ ! "$CERTIFICATE_DAYS" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: SPEAKY_CERTIFICATE_DAYS must be a positive integer."
    exit 1
fi

if ! openssl req -help 2>&1 | grep -q -- "-addext"; then
    echo "ERROR: OpenSSL 1.1.1 or newer is required."
    echo "       Install it with Homebrew and ensure it is first on PATH."
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
if [ -e "$P12_PATH" ] || [ -e "$CERTIFICATE_PATH" ]; then
    echo "ERROR: Signing assets already exist in '$OUTPUT_DIR'."
    echo "       Refusing to replace the release identity."
    exit 1
fi

umask 077
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/speaky-certificate.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT

openssl req \
    -x509 \
    -newkey rsa:3072 \
    -sha256 \
    -nodes \
    -keyout "$TEMP_DIR/private-key.pem" \
    -out "$TEMP_DIR/certificate.pem" \
    -days "$CERTIFICATE_DAYS" \
    -subj "/CN=$CERTIFICATE_NAME/O=Speaky Open Source" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    >/dev/null 2>&1

P12_OPTIONS=(-export)
if openssl version | grep -q "^OpenSSL 3"; then
    P12_OPTIONS+=(-legacy)
fi

openssl pkcs12 \
    "${P12_OPTIONS[@]}" \
    -inkey "$TEMP_DIR/private-key.pem" \
    -in "$TEMP_DIR/certificate.pem" \
    -name "$CERTIFICATE_NAME" \
    -out "$P12_PATH" \
    -passout env:SPEAKY_CERTIFICATE_PASSWORD

openssl x509 \
    -in "$TEMP_DIR/certificate.pem" \
    -outform DER \
    -out "$CERTIFICATE_PATH"

chmod 600 "$P12_PATH"
chmod 644 "$CERTIFICATE_PATH"

echo "Created a stable self-signed release identity:"
echo "    Private identity: $P12_PATH"
echo "    Public anchor:    $CERTIFICATE_PATH"
echo ""
openssl x509 \
    -in "$TEMP_DIR/certificate.pem" \
    -noout \
    -subject \
    -dates \
    -fingerprint \
    -sha256
echo ""
echo "Back up the .p12 and its password securely. Never commit the .p12."
