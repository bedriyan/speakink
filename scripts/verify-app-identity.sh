#!/bin/bash
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Usage: $0 <app-path> [previous-app-path]" >&2
    exit 1
fi

APP_PATH="$1"
PREVIOUS_APP_PATH="${2:-}"
EXPECTED_BUNDLE_ID="com.bedriyan.speaky"
EXPECTED_CERTIFICATE="${SPEAKY_SIGNING_CERTIFICATE:-}"
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/speaky-identity-verification.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT

error() {
    echo "ERROR: $*" >&2
    exit 1
}

certificate_sha1() {
    openssl x509 \
        -inform DER \
        -in "$1" \
        -noout \
        -fingerprint \
        -sha1 |
        sed 's/.*=//' |
        tr -d ':' |
        tr '[:lower:]' '[:upper:]'
}

require_entitlement() {
    local entitlements_path="$1"
    local key="$2"
    local value
    value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$entitlements_path" 2>/dev/null || true)
    [ "$value" = "true" ] ||
        error "Required entitlement '$key' is missing or false."
}

reject_entitlement() {
    local entitlements_path="$1"
    local key="$2"
    local value
    value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$entitlements_path" 2>/dev/null || true)
    [ "$value" != "true" ] ||
        error "Release app contains forbidden entitlement '$key'."
}

inspect_runtime_signature() {
    local code_path="$1"
    local expected_certificate_sha1="$2"
    local details
    local extracted_certificate_prefix
    local actual_certificate_sha1

    details=$(codesign -dvvv "$code_path" 2>&1)

    printf '%s\n' "$details" | grep -Fq "Signature=adhoc" &&
        error "Ad-hoc nested signature found: $code_path"
    printf '%s\n' "$details" | grep -Fq "Authority=" ||
        error "Certificate-backed nested signature is missing: $code_path"
    printf '%s\n' "$details" | grep -Eq 'flags=.*runtime' ||
        error "Hardened runtime is missing from nested code: $code_path"

    if [ -n "$expected_certificate_sha1" ]; then
        extracted_certificate_prefix="$TEMP_DIR/nested-certificate-"
        rm -f "$extracted_certificate_prefix"*
        codesign -d \
            --extract-certificates="$extracted_certificate_prefix" \
            "$code_path" >/dev/null 2>&1
        [ -f "${extracted_certificate_prefix}0" ] ||
            error "Unable to extract the nested signing certificate: $code_path"
        actual_certificate_sha1=$(certificate_sha1 "${extracted_certificate_prefix}0")
        [ "$actual_certificate_sha1" = "$expected_certificate_sha1" ] ||
            error "Nested code is signed by a different certificate: $code_path"
    fi
}

inspect_app() {
    local app_path="$1"
    local info_plist="$app_path/Contents/Info.plist"
    local bundle_id
    local executable_name
    local requirement_output
    local requirement
    local signature_details
    local entitlements_path
    local entitlement_key_count
    local expected_anchor=""
    local nested_path

    [ -d "$app_path" ] || error "App does not exist: $app_path"
    [ -f "$info_plist" ] || error "Info.plist is missing from $app_path."

    plutil -lint "$info_plist" >/dev/null
    bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$info_plist")
    executable_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$info_plist")

    [ "$bundle_id" = "$EXPECTED_BUNDLE_ID" ] ||
        error "Expected '$EXPECTED_BUNDLE_ID', found '$bundle_id' in $app_path."
    [ -x "$app_path/Contents/MacOS/$executable_name" ] ||
        error "Bundle executable '$executable_name' is missing in $app_path."

    codesign --verify --deep --strict --verbose=2 "$app_path"
    signature_details=$(codesign -dvvv "$app_path" 2>&1)

    printf '%s\n' "$signature_details" | grep -Fq "Signature=adhoc" &&
        error "The app is ad-hoc signed and cannot establish a stable identity."
    printf '%s\n' "$signature_details" | grep -Fq "Authority=" ||
        error "The app does not contain a certificate-backed signature."
    printf '%s\n' "$signature_details" | grep -Eq 'flags=.*runtime' ||
        error "The app is missing the hardened-runtime code-signing flag."

    requirement_output=$(codesign -d -r- "$app_path" 2>&1)
    requirement=$(
        printf '%s\n' "$requirement_output" |
            awk '/^(# )?designated => / { sub(/^# /, ""); print; exit }'
    )
    [ -n "$requirement" ] ||
        error "No designated requirement found in $app_path."

    case "$requirement" in
        *cdhash*) error "The designated requirement is code-hash based, not certificate anchored." ;;
    esac
    case "$requirement" in
        *'anchor = H"'*|*'certificate root = H"'*) ;;
        *) error "The designated requirement is not anchored to a certificate hash." ;;
    esac
    case "$requirement" in
        *"identifier \"$EXPECTED_BUNDLE_ID\""*) ;;
        *) error "The designated requirement does not contain the expected bundle identifier." ;;
    esac

    if [ -n "$EXPECTED_CERTIFICATE" ]; then
        [ -f "$EXPECTED_CERTIFICATE" ] ||
            error "SPEAKY_SIGNING_CERTIFICATE does not exist: $EXPECTED_CERTIFICATE"
        local expected_anchor_lowercase
        expected_anchor=$(certificate_sha1 "$EXPECTED_CERTIFICATE")
        expected_anchor_lowercase=$(printf '%s' "$expected_anchor" | tr '[:upper:]' '[:lower:]')
        case "$requirement" in
            *"anchor = H\"$expected_anchor\""*|\
            *"anchor = H\"$expected_anchor_lowercase\""*|\
            *"certificate root = H\"$expected_anchor\""*|\
            *"certificate root = H\"$expected_anchor_lowercase\""*) ;;
            *) error "The app requirement is not anchored to SPEAKY_SIGNING_CERTIFICATE." ;;
        esac
    fi

    entitlements_path="$TEMP_DIR/entitlements.plist"
    codesign -d --entitlements :- "$app_path" >"$entitlements_path" 2>/dev/null
    require_entitlement "$entitlements_path" "com.apple.security.device.audio-input"
    reject_entitlement "$entitlements_path" "com.apple.security.cs.disable-library-validation"
    reject_entitlement "$entitlements_path" "com.apple.security.get-task-allow"
    entitlement_key_count=$(grep -c '<key>' "$entitlements_path")
    [ "$entitlement_key_count" -eq 1 ] ||
        error "Release app must contain only the microphone entitlement."

    for nested_path in \
        "$app_path"/Contents/Frameworks/*.framework \
        "$app_path"/Contents/Frameworks/*.dylib \
        "$app_path"/Contents/PlugIns/*.appex \
        "$app_path"/Contents/PlugIns/*.xpc \
        "$app_path"/Contents/Library/LoginItems/*.app; do
        [ -e "$nested_path" ] || continue
        inspect_runtime_signature "$nested_path" "$expected_anchor"
    done

    echo "App: $app_path" >&2
    echo "Bundle ID: $bundle_id" >&2
    echo "Executable: $executable_name" >&2
    echo "Requirement: $requirement" >&2

    printf '%s' "$requirement"
}

CURRENT_REQUIREMENT=$(inspect_app "$APP_PATH")

if [ -n "$PREVIOUS_APP_PATH" ]; then
    echo ""
    PREVIOUS_REQUIREMENT=$(inspect_app "$PREVIOUS_APP_PATH")

    [ "$CURRENT_REQUIREMENT" = "$PREVIOUS_REQUIREMENT" ] ||
        error "The two builds have different designated requirements.
       macOS may treat them as different Accessibility clients."

    echo ""
    echo "Identity continuity verified: both builds share the same designated requirement."
else
    echo ""
    echo "Stable application identity verified."
fi
