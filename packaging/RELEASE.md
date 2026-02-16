# ClawBar Release (Developer ID + Notarization)

## 1. Requirements
- Active Apple Developer Program account
- `Developer ID Application` signing certificate installed in login keychain
- Xcode Command Line Tools

## 2. Build + sign + notarize + package DMG
From project root:

```bash
./scripts/run_checks.sh
export DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)"
# Preferred: create a notarytool profile once
# xcrun notarytool store-credentials clawbar-notary --apple-id you@example.com --team-id TEAMID --password app-specific-password
export NOTARY_PROFILE="clawbar-notary"

./packaging/release.sh
```

Alternative (without keychain profile):

```bash
export DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)"
export APPLE_ID="you@example.com"
export APPLE_TEAM_ID="TEAMID"
export APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
./packaging/release.sh
```

## 3. Output
- Signed, stapled app: `dist/ClawBar.app`
- Signed, stapled installer DMG: `release/ClawBar.dmg`

## Notes
- `packaging/build.sh` remains the local ad-hoc build path for development.
- `packaging/make-dmg.sh` creates a drag-and-drop DMG from an existing app bundle.
- `packaging/release.sh` is for public distribution artifacts and notarizes the DMG.
