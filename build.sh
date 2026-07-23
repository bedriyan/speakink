#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Speaky"
APP_BUNDLE_ID="com.bedriyan.speaky"
BUILD_DIR="$PROJECT_DIR/build"
DERIVED_DATA_DIR="$BUILD_DIR/DerivedData"
SOURCE_PACKAGES_DIR="$BUILD_DIR/SourcePackages"
PACKAGE_RESOLVED_PATH="$PROJECT_DIR/Speaky.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
VERSION=$(grep 'MARKETING_VERSION' "$PROJECT_DIR/project.yml" | head -1 | sed 's/.*"\(.*\)".*/\1/')
ENTITLEMENTS_PATH="$PROJECT_DIR/Speaky/Resources/Speaky.entitlements"
IDENTITY_VERIFIER="$PROJECT_DIR/scripts/verify-app-identity.sh"
MINIMUM_CERTIFICATE_VALIDITY_SECONDS=2592000

BUILD_MODE="${1:-universal}"
SIGNING_IDENTITY="${SPEAKY_SIGNING_IDENTITY:-}"
SIGNING_CERTIFICATE="${SPEAKY_SIGNING_CERTIFICATE:-}"
SIGNING_KEYCHAIN="${SPEAKY_SIGNING_KEYCHAIN:-}"
ALLOW_ADHOC="${SPEAKY_ALLOW_ADHOC:-0}"
TEMP_DIRECTORIES=()

error() {
    echo "ERROR: $*" >&2
    exit 1
}

register_temp_directory() {
    local variable_name="$1"
    local directory
    directory=$(mktemp -d "${TMPDIR:-/tmp}/speaky-build.XXXXXX")
    TEMP_DIRECTORIES+=("$directory")
    printf -v "$variable_name" '%s' "$directory"
}

cleanup_temp_directories() {
    local directory
    [ "${#TEMP_DIRECTORIES[@]}" -gt 0 ] || return
    for directory in "${TEMP_DIRECTORIES[@]}"; do
        [ ! -d "$directory" ] || rm -rf -- "$directory"
    done
}

trap cleanup_temp_directories EXIT

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

validate_signing_configuration() {
    case "$ALLOW_ADHOC" in
        0|1) ;;
        *) error "SPEAKY_ALLOW_ADHOC must be either 0 or 1." ;;
    esac

    if [ -z "$SIGNING_IDENTITY" ]; then
        if [ "$ALLOW_ADHOC" = "1" ]; then
            SIGNING_IDENTITY="-"
        else
            error "Official packaging requires SPEAKY_SIGNING_IDENTITY and SPEAKY_SIGNING_CERTIFICATE.
       For an unpublished local test build only, set SPEAKY_ALLOW_ADHOC=1."
        fi
    fi

    if [ "$SIGNING_IDENTITY" = "-" ]; then
        [ "$ALLOW_ADHOC" = "1" ] ||
            error "Ad-hoc signing requires the explicit SPEAKY_ALLOW_ADHOC=1 opt-in."
        echo "==> Signing mode: ad hoc (local testing only)"
        echo "    Hardened runtime is disabled for the final ad-hoc signature."
        echo "    Do not publish this artifact."
        return
    fi

    SIGNING_IDENTITY=$(printf '%s' "$SIGNING_IDENTITY" | tr '[:lower:]' '[:upper:]')
    [[ "$SIGNING_IDENTITY" =~ ^[0-9A-F]{40}$ ]] ||
        error "SPEAKY_SIGNING_IDENTITY must be the certificate's 40-character SHA-1 hash."

    [ -n "$SIGNING_CERTIFICATE" ] && [ -f "$SIGNING_CERTIFICATE" ] ||
        error "SPEAKY_SIGNING_CERTIFICATE must point to the matching public DER certificate."
    case "$SIGNING_CERTIFICATE" in
        /*) ;;
        *) error "SPEAKY_SIGNING_CERTIFICATE must be an absolute path." ;;
    esac

    if [ -n "$SIGNING_KEYCHAIN" ] && [ ! -f "$SIGNING_KEYCHAIN" ]; then
        error "SPEAKY_SIGNING_KEYCHAIN does not exist: $SIGNING_KEYCHAIN"
    fi
    if [ -n "$SIGNING_KEYCHAIN" ]; then
        case "$SIGNING_KEYCHAIN" in
            /*) ;;
            *) error "SPEAKY_SIGNING_KEYCHAIN must be an absolute path." ;;
        esac
        SIGNING_KEYCHAIN="$(
            cd "$(dirname "$SIGNING_KEYCHAIN")"
            printf '%s/%s' "$(pwd -P)" "$(basename "$SIGNING_KEYCHAIN")"
        )"

        local keychain_search_list
        keychain_search_list=$(
            security list-keychains -d user |
                sed 's/^[[:space:]"]*//; s/[[:space:]"]*$//'
        )
        printf '%s\n' "$keychain_search_list" | grep -Fxq "$SIGNING_KEYCHAIN" ||
            error "SPEAKY_SIGNING_KEYCHAIN must be on the user keychain search list.
       Add it with: security list-keychains -d user -s \"$SIGNING_KEYCHAIN\" <existing-keychains...>"
    fi

    openssl x509 \
        -inform DER \
        -in "$SIGNING_CERTIFICATE" \
        -noout \
        -checkend "$MINIMUM_CERTIFICATE_VALIDITY_SECONDS" >/dev/null ||
        error "The release signing certificate is invalid or expires within 30 days.
       Complete the documented certificate migration before publishing another release."
    openssl x509 -inform DER -in "$SIGNING_CERTIFICATE" -noout -text |
        grep -Fq "Code Signing" ||
        error "The release certificate is not valid for code signing."

    local expected_sha1
    expected_sha1=$(certificate_sha1 "$SIGNING_CERTIFICATE")
    [ "$SIGNING_IDENTITY" = "$expected_sha1" ] ||
        error "The public certificate does not match SPEAKY_SIGNING_IDENTITY.
       Certificate: $expected_sha1
       Identity:    $SIGNING_IDENTITY"

    local identity_output
    if [ -n "$SIGNING_KEYCHAIN" ]; then
        identity_output=$(security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" || true)
    else
        identity_output=$(security find-identity -v -p codesigning || true)
    fi
    printf '%s\n' "$identity_output" | grep -Fq "$SIGNING_IDENTITY" ||
        error "Code-signing identity '$SIGNING_IDENTITY' is not available."

    echo "==> Signing mode: stable self-signed identity"
    echo "    Certificate SHA-1: $SIGNING_IDENTITY"
    echo "    Requirement anchor: $SIGNING_CERTIFICATE"
}

codesign_item() {
    local code_path="$1"
    local arguments=(
        --force
        --sign "$SIGNING_IDENTITY"
        --timestamp=none
    )

    if [ "$SIGNING_IDENTITY" != "-" ]; then
        arguments+=(--options runtime)
    fi
    if [ -n "$SIGNING_KEYCHAIN" ]; then
        arguments+=(--keychain "$SIGNING_KEYCHAIN")
    fi
    codesign "${arguments[@]}" "$code_path"
}

sign_nested_code() {
    local app_path="$1"
    local frameworks_path="$app_path/Contents/Frameworks"
    local code_path

    if [ -d "$frameworks_path" ]; then
        while IFS= read -r -d '' code_path; do
            codesign_item "$code_path"
        done < <(
            find "$frameworks_path" -mindepth 1 -maxdepth 1 \
                \( -type d -name "*.framework" -o -type f -name "*.dylib" \) \
                -print0
        )
    fi

    for code_path in \
        "$app_path"/Contents/PlugIns/*.appex \
        "$app_path"/Contents/PlugIns/*.xpc \
        "$app_path"/Contents/Library/LoginItems/*.app; do
        [ -e "$code_path" ] || continue
        codesign_item "$code_path"
    done
}

prepare_app() {
    local app_path="$1"
    local info_plist="$app_path/Contents/Info.plist"
    local bundle_id
    local executable_name
    local arguments=()

    xattr -cr "$app_path"
    bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$info_plist")
    executable_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$info_plist")

    [ "$bundle_id" = "$APP_BUNDLE_ID" ] ||
        error "Expected bundle identifier '$APP_BUNDLE_ID', found '$bundle_id'."
    [ -x "$app_path/Contents/MacOS/$executable_name" ] ||
        error "Bundle executable '$executable_name' is missing."

    sign_nested_code "$app_path"

    arguments=(
        --force
        --sign "$SIGNING_IDENTITY"
        --timestamp=none
        --entitlements "$ENTITLEMENTS_PATH"
        --identifier "$APP_BUNDLE_ID"
    )
    if [ -n "$SIGNING_KEYCHAIN" ]; then
        arguments+=(--keychain "$SIGNING_KEYCHAIN")
    fi

    if [ "$SIGNING_IDENTITY" != "-" ]; then
        local designated_requirement
        designated_requirement="designated => anchor \"$SIGNING_CERTIFICATE\" and identifier \"$APP_BUNDLE_ID\""
        arguments+=(
            --options runtime
            --requirements "=$designated_requirement"
        )
    fi

    codesign "${arguments[@]}" "$app_path"
    codesign --verify --deep --strict --verbose=2 "$app_path"

    if [ "$SIGNING_IDENTITY" != "-" ]; then
        SPEAKY_SIGNING_CERTIFICATE="$SIGNING_CERTIFICATE" \
            "$IDENTITY_VERIFIER" "$app_path"
    fi

    echo "    Bundle ID: $bundle_id"
    echo "    Designated requirement:"
    codesign -d -r- "$app_path" 2>&1 | sed 's/^/        /'
}

create_dmg() {
    local app_path="$1"
    local dmg_path="$2"
    local temporary_directory

    register_temp_directory temporary_directory
    ditto "$app_path" "$temporary_directory/$APP_NAME.app"
    ln -s /Applications "$temporary_directory/Applications"
    hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$temporary_directory" \
        -ov \
        -format UDZO \
        "$dmg_path"
    hdiutil verify "$dmg_path" >/dev/null
    rm -rf -- "$temporary_directory"
}

clean_build_products() {
    xcodebuild \
        -project "$APP_NAME.xcodeproj" \
        -scheme "$APP_NAME" \
        -derivedDataPath "$DERIVED_DATA_DIR" \
        -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
        -disableAutomaticPackageResolution \
        -onlyUsePackageVersionsFromResolvedFile \
        clean >/dev/null
}

build_architectures() {
    local architectures="$1"
    clean_build_products
    xcodebuild \
        -project "$APP_NAME.xcodeproj" \
        -scheme "$APP_NAME" \
        -configuration Release \
        -destination "platform=macOS" \
        -derivedDataPath "$DERIVED_DATA_DIR" \
        -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
        -disableAutomaticPackageResolution \
        -onlyUsePackageVersionsFromResolvedFile \
        ARCHS="$architectures" \
        ONLY_ACTIVE_ARCH=NO \
        -quiet \
        build
}

package_build() {
    local suffix="$1"
    local expected_architectures="$2"
    local built_app="$DERIVED_DATA_DIR/Build/Products/Release/$APP_NAME.app"
    local executable_path="$built_app/Contents/MacOS/$APP_NAME"
    local actual_architectures
    local normalized_actual_architectures
    local normalized_expected_architectures
    local dmg_name
    local stage_dir

    [ -d "$built_app" ] || error "Build product not found: $built_app"
    actual_architectures=$(lipo -archs "$executable_path")
    normalized_actual_architectures=$(
        for architecture in $actual_architectures; do
            printf '%s\n' "$architecture"
        done | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'
    )
    normalized_expected_architectures=$(
        for architecture in $expected_architectures; do
            printf '%s\n' "$architecture"
        done | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'
    )
    [ "$normalized_actual_architectures" = "$normalized_expected_architectures" ] ||
        error "Expected architectures '$expected_architectures', found '$actual_architectures'."
    echo "    Architectures: $actual_architectures"

    register_temp_directory stage_dir
    ditto "$built_app" "$stage_dir/$APP_NAME.app"
    prepare_app "$stage_dir/$APP_NAME.app"

    if [ -n "$suffix" ]; then
        dmg_name="$APP_NAME-$VERSION-$suffix.dmg"
    else
        dmg_name="$APP_NAME-$VERSION.dmg"
    fi

    echo "==> Creating DMG: $dmg_name..."
    rm -f "$BUILD_DIR/$dmg_name"
    create_dmg "$stage_dir/$APP_NAME.app" "$BUILD_DIR/$dmg_name"
    rm -rf -- "$stage_dir"
    echo "    $BUILD_DIR/$dmg_name"
}

case "$BUILD_MODE" in
    silicon|intel|separate|universal) ;;
    *) error "Unknown build mode '$BUILD_MODE'. Use universal, silicon, intel, or separate." ;;
esac

echo "==> Generating Xcode project..."
cd "$PROJECT_DIR"
[ -f "$PACKAGE_RESOLVED_PATH" ] ||
    error "Tracked dependency lock is missing: $PACKAGE_RESOLVED_PATH"
PACKAGE_RESOLVED_SHA=$(
    shasum -a 256 "$PACKAGE_RESOLVED_PATH" |
        awk '{ print $1 }'
)
xcodegen generate
[ -f "$PACKAGE_RESOLVED_PATH" ] ||
    error "XcodeGen removed the tracked dependency lock: $PACKAGE_RESOLVED_PATH"
[ "$(
    shasum -a 256 "$PACKAGE_RESOLVED_PATH" |
        awk '{ print $1 }'
)" = "$PACKAGE_RESOLVED_SHA" ] ||
    error "XcodeGen changed the tracked dependency lock."
mkdir -p "$BUILD_DIR" "$SOURCE_PACKAGES_DIR"
validate_signing_configuration

case "$BUILD_MODE" in
    silicon)
        echo "==> Building $APP_NAME (Release, Apple Silicon)..."
        build_architectures "arm64"
        package_build "Apple-Silicon" "arm64"
        ;;
    intel)
        echo "==> Building $APP_NAME (Release, Intel)..."
        build_architectures "x86_64"
        package_build "Intel" "x86_64"
        ;;
    separate)
        echo "==> Building $APP_NAME (Release, Apple Silicon)..."
        build_architectures "arm64"
        package_build "Apple-Silicon" "arm64"

        echo "==> Building $APP_NAME (Release, Intel)..."
        build_architectures "x86_64"
        package_build "Intel" "x86_64"
        ;;
    universal)
        echo "==> Building $APP_NAME (Release, Universal Binary)..."
        build_architectures "arm64 x86_64"
        package_build "" "arm64 x86_64"
        ;;
esac

echo ""
echo "==> Build complete!"
find "$BUILD_DIR" -maxdepth 1 -name "$APP_NAME-$VERSION*.dmg" -exec ls -lh {} \; |
    awk '{print "    " $5 "\t" $NF}'
