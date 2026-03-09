#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Speaky"
BUILD_DIR="$PROJECT_DIR/build"
VERSION=$(grep 'MARKETING_VERSION' "$PROJECT_DIR/project.yml" | head -1 | sed 's/.*"\(.*\)".*/\1/')
DMGBUILD_SETTINGS="$PROJECT_DIR/.github/dmgbuild-settings.py"
DMG_BACKGROUND="$PROJECT_DIR/.github/dmg-background.png"

echo "==> Generating Xcode project..."
cd "$PROJECT_DIR"
xcodegen generate

# Parse arguments
BUILD_MODE="${1:-universal}" # universal, silicon, intel, separate

# Helper: wipe DerivedData to avoid stale builds across architectures
clean_derived_data() {
    rm -rf ~/Library/Developer/Xcode/DerivedData/"$APP_NAME"-*
}

# Clean DerivedData to avoid stale cached builds
clean_derived_data

# Ensure clean build output directory
mkdir -p "$BUILD_DIR"

# Helper: find the built .app in DerivedData
find_built_app() {
    find ~/Library/Developer/Xcode/DerivedData/"$APP_NAME"-*/Build/Products/Release \
        -name "$APP_NAME.app" -maxdepth 1 2>/dev/null | head -1
}

# Helper: prepare app for distribution (strip quarantine, re-sign)
prepare_app() {
    local app_path="$1"
    xattr -cr "$app_path"
    # Deep-sign nested frameworks/bundles first, then re-sign the main app
    # with explicit identifier so macOS Accessibility matches the bundle ID
    codesign --force --deep --sign - "$app_path"
    codesign --force --sign - --identifier com.bedriyan.speaky "$app_path"
}

# Helper: create DMG using dmgbuild (with drag-to-Applications visual)
create_dmg() {
    local app_path="$1"
    local dmg_path="$2"

    if command -v dmgbuild &>/dev/null && [ -f "$DMGBUILD_SETTINGS" ]; then
        APP_PATH="$app_path" DMG_BACKGROUND="$DMG_BACKGROUND" \
            dmgbuild -s "$DMGBUILD_SETTINGS" "$APP_NAME" "$dmg_path"
    else
        echo "    (dmgbuild not found, falling back to hdiutil)"
        local tmpdir
        tmpdir=$(mktemp -d)
        ditto "$app_path" "$tmpdir/$APP_NAME.app"
        hdiutil create -volname "$APP_NAME" -srcfolder "$tmpdir" -ov -format UDZO "$dmg_path" 2>&1 | tail -2
        rm -rf "$tmpdir"
    fi
}

# Helper: sign and package a single build into a DMG
package_build() {
    local suffix="$1"  # e.g. "Apple-Silicon", "Intel", "Universal", or ""
    local dmg_name

    BUILT_APP=$(find_built_app)
    if [ -z "$BUILT_APP" ]; then
        echo "ERROR: Build product not found!"
        exit 1
    fi

    echo "    Arch: $(lipo -info "$BUILT_APP/Contents/MacOS/$APP_NAME" 2>&1)"

    # Stage, sign, and create DMG
    local stage_dir
    stage_dir=$(mktemp -d)
    ditto "$BUILT_APP" "$stage_dir/$APP_NAME.app"
    prepare_app "$stage_dir/$APP_NAME.app"

    if [ -n "$suffix" ]; then
        dmg_name="$APP_NAME-$VERSION-$suffix.dmg"
    else
        dmg_name="$APP_NAME-$VERSION.dmg"
    fi

    echo "==> Creating DMG: $dmg_name..."
    rm -f "$BUILD_DIR/$dmg_name"
    create_dmg "$stage_dir/$APP_NAME.app" "$BUILD_DIR/$dmg_name"
    rm -rf "$stage_dir"

    echo "    $BUILD_DIR/$dmg_name"
}

case "$BUILD_MODE" in
  silicon)
    echo "==> Building $APP_NAME (Release, Apple Silicon only)..."
    xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
        ARCHS="arm64" ONLY_ACTIVE_ARCH=NO \
        build 2>&1 | tail -5
    package_build "Apple-Silicon"
    ;;
  intel)
    echo "==> Building $APP_NAME (Release, Intel only)..."
    xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
        ARCHS="x86_64" ONLY_ACTIVE_ARCH=NO \
        build 2>&1 | tail -5
    package_build "Intel"
    ;;
  separate)
    # --- Apple Silicon ---
    echo "==> Building $APP_NAME (Release, Apple Silicon)..."
    clean_derived_data
    xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
        ARCHS="arm64" ONLY_ACTIVE_ARCH=NO \
        build 2>&1 | tail -5
    package_build "Apple-Silicon"

    # --- Intel ---
    echo "==> Building $APP_NAME (Release, Intel)..."
    clean_derived_data
    xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
        ARCHS="x86_64" ONLY_ACTIVE_ARCH=NO \
        build 2>&1 | tail -5
    package_build "Intel"
    ;;
  universal|*)
    echo "==> Building $APP_NAME (Release, Universal Binary)..."
    xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
        ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
        build 2>&1 | tail -5
    package_build ""
    ;;
esac

echo ""
echo "==> Build complete!"
ls -lh "$BUILD_DIR/$APP_NAME-$VERSION"*.dmg 2>/dev/null | awk '{print "    " $5 "\t" $NF}'
echo ""
echo "Install from the DMG in build/ directory."
