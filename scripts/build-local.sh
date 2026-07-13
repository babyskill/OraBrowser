#!/bin/bash
set -euo pipefail

# build-local.sh — Build local development App and DMG without code signing.
# Output: build/CapyApp.dmg

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Preflight checks
echo "Checking tools..."
if ! command -v xcodegen >/dev/null; then
    echo "xcodegen is required. Installing..."
    brew install xcodegen
fi

if ! command -v xcbeautify >/dev/null; then
    echo "xcbeautify is required. Installing..."
    brew install xcbeautify
fi

if ! command -v create-dmg >/dev/null; then
    echo "create-dmg is required. Installing..."
    brew install create-dmg
fi

echo "Cleaning build directory..."
rm -rf build
mkdir -p build

echo "Generating Xcode project..."
xcodegen

echo "Building app bundle (Release config, unsigned)..."
if command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild build \
        -scheme ora \
        -configuration Release \
        -destination "platform=macOS" \
        -derivedDataPath build/DerivedData \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        2>&1 | xcbeautify
else
    xcodebuild build \
        -scheme ora \
        -configuration Release \
        -destination "platform=macOS" \
        -derivedDataPath build/DerivedData \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO
fi

APP_PATH="build/DerivedData/Build/Products/Release/CapyBrowser.app"
[[ -d "$APP_PATH" ]] || { echo "error: App build failed, app bundle not found."; exit 1; }

echo "Copying app to build root..."
cp -R "$APP_PATH" "build/CapyBrowser.app"

echo "Packaging app into DMG..."
create-dmg \
    --app-drop-link 600 185 \
    --window-size 800 400 \
    --volname "CapyBrowser" \
    --skip-jenkins \
    "build/CapyApp.dmg" \
    "build/CapyBrowser.app" 2>/dev/null || true

# create-dmg sometimes uses a temp name or fails on return status but works
TEMP_DMG=$(ls build/rw.*.dmg 2>/dev/null | head -1 || true)
[[ -n "$TEMP_DMG" ]] && mv "$TEMP_DMG" "build/CapyApp.dmg"

if [[ -f "build/CapyApp.dmg" ]]; then
    echo "========================================"
    echo "Local build complete!"
    echo "App bundle: build/CapyBrowser.app"
    echo "DMG package: build/CapyApp.dmg ($(du -h "build/CapyApp.dmg" | cut -f1))"
    echo "========================================"
else
    echo "error: DMG creation failed."
    exit 1
fi
