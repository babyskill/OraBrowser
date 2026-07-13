#!/bin/bash
set -euo pipefail

# run-debug.sh — Build local debug App and open it immediately.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

echo "Building CapyBrowser (Debug configuration, unsigned)..."
if command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild build \
        -scheme ora \
        -configuration Debug \
        -destination "platform=macOS" \
        -derivedDataPath build/DerivedData \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        2>&1 | xcbeautify
else
    xcodebuild build \
        -scheme ora \
        -configuration Debug \
        -destination "platform=macOS" \
        -derivedDataPath build/DerivedData \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO
fi

APP_PATH="build/DerivedData/Build/Products/Debug/CapyBrowser.app"
if [[ -d "$APP_PATH" ]]; then
    echo "========================================"
    echo "Build succeeded! Launching CapyBrowser..."
    echo "========================================"
    open "$APP_PATH"
else
    echo "error: App build succeeded, but bundle not found at $APP_PATH"
    exit 1
fi
