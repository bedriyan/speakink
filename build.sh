#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Speaky"
LOCAL_APP="$PROJECT_DIR/$APP_NAME.app"
RELEASE_DIR="$PROJECT_DIR/release"
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

# Helper: find the built .app in DerivedData
find_built_app() {
    find ~/Library/Developer/Xcode/DerivedData/"$APP_NAME"-*/Build/Products/Release \
        -name "$APP_NAME.app" -maxdepth 1 2>/dev/null | head -1
}

# Helper: prepare app for distribution (strip quarantine, re-sign)
prepare_app() {
    local app_path="$1"
    xattr -cr "$app_path"
    codesign --force --deep --sign - --identifier com.bedriyan.speaky "$app_path"
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

case "$BUILD_MODE" in
  silicon)
    echo "==> Building $APP_NAME (Release, Apple Silicon only)..."
    xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
        ARCHS="arm64" ONLY_ACTIVE_ARCH=NO \
        build 2>&1 | tail -5
    ;;
  intel)
    echo "==> Building $APP_NAME (Release, Intel only)..."
    xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
        ARCHS="x86_64" ONLY_ACTIVE_ARCH=NO \
        build 2>&1 | tail -5
    ;;
  separate)
    mkdir -p "$RELEASE_DIR"

    # --- Apple Silicon ---
    echo "==> Building $APP_NAME (Release, Apple Silicon)..."
    clean_derived_data
    xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
        ARCHS="arm64" ONLY_ACTIVE_ARCH=NO \
        build 2>&1 | tail -5

    BUILT_APP=$(find_built_app)
    if [ -z "$BUILT_APP" ]; then
        echo "ERROR: Apple Silicon build product not found!"
        exit 1
    fi

    echo "    Arch: $(lipo -info "$BUILT_APP/Contents/MacOS/$APP_NAME" 2>&1)"

    # Stage for DMG (as "Speaky.app", not "Speaky-Apple-Silicon.app")
    STAGE_DIR=$(mktemp -d)
    ditto "$BUILT_APP" "$STAGE_DIR/$APP_NAME.app"
    prepare_app "$STAGE_DIR/$APP_NAME.app"

    echo "==> Creating Apple Silicon DMG..."
    rm -f "$RELEASE_DIR/$APP_NAME-$VERSION-Apple-Silicon.dmg"
    create_dmg "$STAGE_DIR/$APP_NAME.app" "$RELEASE_DIR/$APP_NAME-$VERSION-Apple-Silicon.dmg"
    rm -rf "$STAGE_DIR"

    # --- Intel ---
    echo "==> Building $APP_NAME (Release, Intel)..."
    clean_derived_data
    xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
        ARCHS="x86_64" ONLY_ACTIVE_ARCH=NO \
        build 2>&1 | tail -5

    BUILT_APP=$(find_built_app)
    if [ -z "$BUILT_APP" ]; then
        echo "ERROR: Intel build product not found!"
        exit 1
    fi

    echo "    Arch: $(lipo -info "$BUILT_APP/Contents/MacOS/$APP_NAME" 2>&1)"

    STAGE_DIR=$(mktemp -d)
    ditto "$BUILT_APP" "$STAGE_DIR/$APP_NAME.app"
    prepare_app "$STAGE_DIR/$APP_NAME.app"

    echo "==> Creating Intel DMG..."
    rm -f "$RELEASE_DIR/$APP_NAME-$VERSION-Intel.dmg"
    create_dmg "$STAGE_DIR/$APP_NAME.app" "$RELEASE_DIR/$APP_NAME-$VERSION-Intel.dmg"
    rm -rf "$STAGE_DIR"

    echo ""
    echo "==> Separate builds complete!"
    echo "    DMG (Silicon): $RELEASE_DIR/$APP_NAME-$VERSION-Apple-Silicon.dmg"
    echo "    DMG (Intel):   $RELEASE_DIR/$APP_NAME-$VERSION-Intel.dmg"
    echo ""
    ls -lh "$RELEASE_DIR/$APP_NAME-$VERSION"-*.dmg 2>/dev/null | awk '{print "    " $5 "\t" $NF}'
    exit 0
    ;;
  universal|*)
    echo "==> Building $APP_NAME (Release, Universal Binary)..."
    xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
        ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
        build 2>&1 | tail -5
    ;;
esac

# Find the built .app in DerivedData
BUILT_APP=$(find_built_app)

if [ -z "$BUILT_APP" ]; then
    echo "ERROR: Build product not found!"
    exit 1
fi

echo "==> Removing old $APP_NAME.app..."
rm -rf "$LOCAL_APP"

echo "==> Copying new build to project root..."
cp -R "$BUILT_APP" "$LOCAL_APP"

echo "==> Done! $LOCAL_APP"
echo "==> Opening $APP_NAME..."
open "$LOCAL_APP"
