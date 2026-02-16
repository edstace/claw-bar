#!/bin/bash
set -euo pipefail

APP_NAME="${APP_NAME:-ClawBar}"
APP_PATH="${APP_PATH:-dist/${APP_NAME}.app}"
RELEASE_DIR="${RELEASE_DIR:-release}"
DMG_PATH="${DMG_PATH:-${RELEASE_DIR}/${APP_NAME}.dmg}"
VOLUME_NAME="${VOLUME_NAME:-${APP_NAME}}"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: app bundle not found at ${APP_PATH}"
  exit 1
fi

STAGE_DIR="${RELEASE_DIR}/dmg-stage"
rm -rf "${STAGE_DIR}" "${DMG_PATH}"
mkdir -p "${STAGE_DIR}"

cp -R "${APP_PATH}" "${STAGE_DIR}/"
ln -s /Applications "${STAGE_DIR}/Applications"

hdiutil create \
  -volname "${VOLUME_NAME}" \
  -srcfolder "${STAGE_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

rm -rf "${STAGE_DIR}"

echo "==> DMG ready: ${DMG_PATH}"
