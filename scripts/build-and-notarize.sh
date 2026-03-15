#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------
# Claudoscope — Build, Sign, Notarize, and Package
# -----------------------------------------------------------
# Required environment variables:
#   APPLE_ID                   — Apple ID email
#   APPLE_APP_SPECIFIC_PASSWORD — App-specific password
#   TEAMID                     — Apple Developer Team ID
# -----------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="Claudoscope"
BUNDLE_ID="com.claudoscope.app"
SIGN_IDENTITY="Developer ID Application"
SCHEME="Claudoscope"
CONFIG="Release"
BUILD_DIR="$PROJECT_DIR/build"
OUTPUT_DIR="$PROJECT_DIR/dist"
APP_PATH="$BUILD_DIR/Build/Products/$CONFIG/$APP_NAME.app"
DMG_PATH="$OUTPUT_DIR/$APP_NAME.dmg"
ZIP_PATH="$OUTPUT_DIR/$APP_NAME.zip"

# ---- Preflight checks ----

for var in APPLE_ID APPLE_APP_SPECIFIC_PASSWORD TEAMID; do
    if [ -z "${!var:-}" ]; then
        echo "Error: $var is not set" >&2
        exit 1
    fi
done

if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "Error: No '$SIGN_IDENTITY' certificate found in keychain" >&2
    exit 1
fi

command -v xcodegen >/dev/null 2>&1 || { echo "Error: xcodegen not found" >&2; exit 1; }

# ---- Version (optional override) ----

VERSION="${VERSION:-$(defaults read "$PROJECT_DIR/$APP_NAME/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0.0")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
echo "Building $APP_NAME v$VERSION ($BUILD_NUMBER)"

# ---- Generate Xcode project ----

echo "==> Generating Xcode project..."
cd "$PROJECT_DIR"
xcodegen generate

# ---- Build ----

echo "==> Building $CONFIG..."
xcodebuild \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$BUILD_DIR" \
    clean build \
    CODE_SIGN_STYLE=Manual \
    "CODE_SIGN_IDENTITY=$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAMID" \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    "OTHER_CODE_SIGN_FLAGS=--timestamp" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    MARKETING_VERSION="$VERSION" \
    | tail -5

echo "==> Build succeeded"

# ---- Verify signature ----

echo "==> Verifying code signature..."
codesign --verify --deep --strict "$APP_PATH"
echo "    Signature OK"

# ---- Notarize app ----

echo "==> Creating ZIP for notarization..."
mkdir -p "$OUTPUT_DIR"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Submitting to Apple notary service..."
xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --team-id "$TEAMID" \
    --wait

echo "==> Stapling notarization ticket to app..."
xcrun stapler staple "$APP_PATH"

# ---- Create DMG ----

echo "==> Creating DMG..."
STAGING_DIR=$(mktemp -d)
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov -format UDZO \
    "$DMG_PATH"

rm -rf "$STAGING_DIR"

# ---- Sign and notarize DMG ----

echo "==> Signing DMG..."
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

echo "==> Notarizing DMG..."
xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --team-id "$TEAMID" \
    --wait

echo "==> Stapling DMG..."
xcrun stapler staple "$DMG_PATH"

# ---- Done ----

echo ""
echo "============================================"
echo "  $APP_NAME v$VERSION built successfully"
echo "  DMG: $DMG_PATH"
echo "  ZIP: $ZIP_PATH"
echo "============================================"
