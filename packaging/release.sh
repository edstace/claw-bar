#!/bin/bash
set -euo pipefail

# ClawBar signed + notarized release build
# Prereqs:
# - Apple Developer ID Application certificate in keychain
# - xcrun notarytool configured (profile) or Apple ID credentials env vars

APP_NAME="ClawBar"
APP_PATH="dist/${APP_NAME}.app"
RELEASE_DIR="release"
ZIP_PATH="${RELEASE_DIR}/${APP_NAME}.zip"

DEVELOPER_ID_APP="${DEVELOPER_ID_APP:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_APP_PASSWORD="${APPLE_APP_PASSWORD:-}"

if [[ -z "${DEVELOPER_ID_APP}" ]]; then
  echo "error: DEVELOPER_ID_APP is required (example: 'Developer ID Application: Your Name (TEAMID)')."
  exit 1
fi

echo "==> Building app bundle"
"$(dirname "$0")/build.sh"

mkdir -p "${RELEASE_DIR}"
rm -f "${ZIP_PATH}"

echo "==> Signing app with Developer ID"
codesign --force --sign "${DEVELOPER_ID_APP}" \
  --options runtime --timestamp \
  --entitlements "Sources/VoiceBridgeApp/VoiceBridge.entitlements" \
  "${APP_PATH}"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
spctl --assess --type execute --verbose=2 "${APP_PATH}" || true

echo "==> Creating notarization zip"
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

if [[ -n "${NOTARY_PROFILE}" ]]; then
  echo "==> Submitting to notarization with notarytool profile '${NOTARY_PROFILE}'"
  xcrun notarytool submit "${ZIP_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
else
  if [[ -z "${APPLE_ID}" || -z "${APPLE_TEAM_ID}" || -z "${APPLE_APP_PASSWORD}" ]]; then
    echo "error: notarization requires NOTARY_PROFILE or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD."
    exit 1
  fi
  echo "==> Submitting to notarization with Apple ID credentials"
  xcrun notarytool submit "${ZIP_PATH}" \
    --apple-id "${APPLE_ID}" \
    --team-id "${APPLE_TEAM_ID}" \
    --password "${APPLE_APP_PASSWORD}" \
    --wait
fi

echo "==> Stapling ticket"
xcrun stapler staple "${APP_PATH}"

echo "==> Final Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "${APP_PATH}" || true

echo "==> Release ready: ${APP_PATH}"
echo "==> Notarization zip: ${ZIP_PATH}"
