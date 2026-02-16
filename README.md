# ClawBar

ClawBar is a macOS menu bar app that bridges microphone/text input to OpenAI speech services and OpenClaw, then returns chat + optional voice responses.

## Highlights

- Menu bar chat UI
- Live voice mode (`Continuous` or `Push-to-talk`)
- Speech-to-text with configurable sensitivity presets
- OpenClaw relay with retry/timeout hardening
- Text + file attachments (drag/drop + picker)
- Voice playback matching your configured voice profile
- Setup diagnostics, fix-command copy, and diagnostics export
- Launch-at-login toggle
- Local session persistence across restarts

## Requirements

- macOS 14+
- OpenAI API key
- OpenClaw CLI installed (`openclaw`)
- Node.js available for OpenClaw launcher

## Quick Start

1. Download the latest `ClawBar.dmg` from Releases.
2. Open the DMG and drag `ClawBar.app` into `Applications`.
3. Launch ClawBar from Applications.

On first run:

1. Open Settings in the app.
2. Save your OpenAI API key.
3. Run `Setup Check` and resolve any warnings/errors.

## Project Structure

- `Sources/ClawBarApp/` app source
- `packaging/build.sh` local ad-hoc build
- `packaging/release.sh` signed/notarized release flow
- `scripts/run_checks.sh` basic regression checks

## Troubleshooting

### `OpenClaw relay failed: ... env: node: No such file or directory`

ClawBar launches subprocesses with its own PATH. Ensure Node/OpenClaw are installed and visible:

```bash
which node
which openclaw
openclaw status --json
```

If needed, set:

- `OPENCLAW_CLI_PATH` to the full `openclaw` binary path
- `OPENCLAW_HOME` to your OpenClaw config home

### Background noise gets transcribed

In Settings → `Voice` → `Speech Detection`:

- choose `Noisy Room`, or
- lower sensitivity with the slider.

### App icon does not refresh in Launchpad/Finder

After replacing icon assets, restart Dock/Finder or log out/in to refresh icon caches.

### First launch asks for Keychain password

ClawBar stores and reads your API key from Keychain item `com.openclaw.clawbar`. On first launch after install/update, macOS may prompt to allow access. Choose `Always Allow` to avoid repeated prompts.

## License

Add your preferred license here.
