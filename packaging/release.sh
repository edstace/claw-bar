#!/bin/bash
set -euo pipefail

# ClawBar signed + notarized release build
# Prereqs:
# - Apple Developer ID Application certificate in keychain
# - xcrun notarytool configured (profile) or Apple ID credentials env vars

APP_NAME="ClawBar"
APP_PATH="dist/${APP_NAME}.app"
RELEASE_DIR="release"
DMG_PATH="${RELEASE_DIR}/${APP_NAME}.dmg"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-release.XXXXXX")"
WORK_APP_PATH="${WORK_DIR}/${APP_NAME}.app"

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

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
rm -f "${DMG_PATH}"

echo "==> Staging app bundle outside iCloud-managed paths"
cp -R "${APP_PATH}" "${WORK_APP_PATH}"

echo "==> Sanitizing staged app bundle metadata"
xattr -cr "${WORK_APP_PATH}" || true
find "${WORK_APP_PATH}" -name ".DS_Store" -delete || true

echo "==> Signing app with Developer ID"
codesign --force --sign "${DEVELOPER_ID_APP}" \
  --options runtime --timestamp \
  --entitlements "Sources/ClawBarApp/ClawBar.entitlements" \
  "${WORK_APP_PATH}"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "${WORK_APP_PATH}"
spctl --assess --type execute --verbose=2 "${WORK_APP_PATH}" || true

echo "==> Creating distributable DMG"
APP_PATH="${WORK_APP_PATH}" RELEASE_DIR="${RELEASE_DIR}" DMG_PATH="${DMG_PATH}" "$(dirname "$0")/make-dmg.sh"

echo "==> Signing DMG container with Developer ID"
codesign --force --sign "${DEVELOPER_ID_APP}" \
  --timestamp \
  "${DMG_PATH}"

echo "==> Verifying DMG signature"
codesign --verify --verbose=2 "${DMG_PATH}"

if [[ -n "${NOTARY_PROFILE}" ]]; then
  echo "==> Submitting to notarization with notarytool profile '${NOTARY_PROFILE}'"
  xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
else
  if [[ -z "${APPLE_ID}" || -z "${APPLE_TEAM_ID}" || -z "${APPLE_APP_PASSWORD}" ]]; then
    echo "error: notarization requires NOTARY_PROFILE or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD."
    exit 1
  fi
  echo "==> Submitting to notarization with Apple ID credentials"
  xcrun notarytool submit "${DMG_PATH}" \
    --apple-id "${APPLE_ID}" \
    --team-id "${APPLE_TEAM_ID}" \
    --password "${APPLE_APP_PASSWORD}" \
    --wait
fi

echo "==> Stapling DMG ticket"
xcrun stapler staple "${DMG_PATH}"

echo "==> Final Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "${WORK_APP_PATH}" || true
spctl -a -t open --context context:primary-signature -v "${DMG_PATH}" || true

echo "==> Release ready (staged app): ${WORK_APP_PATH}"
echo "==> Distributable DMG: ${DMG_PATH}"
