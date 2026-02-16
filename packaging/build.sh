#!/bin/bash
set -euo pipefail

# ClawBar build & package script
# Produces a proper .app bundle from the SPM executable.

PRODUCT_NAME="VoiceBridgeApp"
APP_NAME="ClawBar"
BUNDLE_ID="com.openclaw.voicebridge"
BUILD_DIR=".build/release"
APP_DIR="dist/${APP_NAME}.app"

echo "==> Building release…"
swift build -c release

echo "==> Creating app bundle…"
rm -rf "dist"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

# Copy binary
cp "${BUILD_DIR}/${PRODUCT_NAME}" "${APP_DIR}/Contents/MacOS/${PRODUCT_NAME}"

# Copy Info.plist
cp "Sources/VoiceBridgeApp/Info.plist" "${APP_DIR}/Contents/Info.plist"

# Copy bundled image resources (menu bar template icon, etc.)
if [ -d "Sources/VoiceBridgeApp/Resources" ]; then
  cp -R "Sources/VoiceBridgeApp/Resources/." "${APP_DIR}/Contents/Resources/"
fi

# Sign with entitlements (ad-hoc for local use)
echo "==> Signing (ad-hoc)…"
codesign --force --sign - \
  --entitlements "Sources/VoiceBridgeApp/VoiceBridge.entitlements" \
  "${APP_DIR}"

echo "==> Done! App bundle at: ${APP_DIR}"
echo ""
echo "To install:"
echo "  cp -r ${APP_DIR} /Applications/"
echo ""
echo "To install LaunchAgent (auto-start at login):"
echo "  cp packaging/com.openclaw.voicebridge.plist ~/Library/LaunchAgents/"
echo "  launchctl load ~/Library/LaunchAgents/com.openclaw.voicebridge.plist"
echo ""
echo "To uninstall LaunchAgent:"
echo "  launchctl unload ~/Library/LaunchAgents/com.openclaw.voicebridge.plist"
echo "  rm ~/Library/LaunchAgents/com.openclaw.voicebridge.plist"
