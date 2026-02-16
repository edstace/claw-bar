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
- Signed app: `dist/ClawBar.app`
- Signed, notarized, stapled installer DMG: `release/ClawBar.dmg`

## Notes
- `packaging/build.sh` remains the local ad-hoc build path for development.
- `packaging/make-dmg.sh` creates a drag-and-drop DMG from an existing app bundle.
- `packaging/release.sh` is for public distribution artifacts and notarizes the DMG.

## GitHub Releases (automatic)
This repo includes `.github/workflows/release.yml`.
Pushing a tag like `v0.1.0` will:
- build
- sign app + DMG with Developer ID
- notarize and staple the DMG
- publish a GitHub Release with:
  - `ClawBar.dmg`
  - `ClawBar.dmg.sha256`

Required repository secrets:
- `DEVELOPER_ID_APP` (example: `Developer ID Application: Your Name (TEAMID)`)
- `DEVELOPER_ID_P12_BASE64` (base64 of your exported `.p12`)
- `DEVELOPER_ID_P12_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD`

Create and push a release tag:

```bash
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```
