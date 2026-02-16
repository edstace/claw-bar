# ClawBar

ClawBar is a macOS menu bar app that lets you talk to OpenClaw using your voice.

It records audio, turns speech into text with OpenAI, sends that text (and optional file attachments) to OpenClaw, then can read the reply back out loud.

## Highlights

- Menu bar chat UI
- Live voice mode (`Continuous` or `Push-to-talk`)
- Speech-to-text with configurable sensitivity presets
- OpenClaw relay with retry/timeout hardening
- Text + file attachments (drag/drop + picker)
- Configurable voice style controls (style, accent, tone, intonation, pace)
- Voice playback using OpenAI Realtime TTS (with non-realtime fallback)
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
3. Open `Diagnostics` and resolve any `Setup Check` warnings/errors.

## How It Works

ClawBar is mainly a coordinator around three jobs:

1. Capture your input (voice or text).
2. Use OpenAI services for speech recognition and speech output.
3. Relay user requests to OpenClaw and show the response.

### End-to-End Flow

1. You press the mic (or type text + attach files).
2. Audio is recorded to a temporary local file.
3. `WhisperService` sends audio to OpenAI transcription (`/v1/audio/transcriptions`).
4. The transcript is added to chat history.
5. `OpenClawRelay` runs `openclaw agent --json ...` as a subprocess.
6. OpenClaw response is parsed and shown in the UI.
7. If live voice is on, `RealtimeTTSService` synthesizes audio and plays it.

### OpenClaw Connection Model

ClawBar does not call OpenClaw through a custom REST server.

It shells out to your local `openclaw` CLI and passes a message/session via CLI flags:

- agent id: `main`
- session id: persisted/rotated by ClawBar
- payload: user text + attachment list (paths and types)

This gives you:

- compatibility with existing OpenClaw installs
- easier debugging (`openclaw ... --json` in Terminal)
- retries/timeouts controlled by ClawBar

### Voice Pipeline Details

Speech-to-text:

- File is recorded with AVFoundation.
- ClawBar computes simple audio signal stats (RMS, peak, active ratio) to reject obvious noise.
- Audio is sent to OpenAI Whisper with deterministic settings for short clips.

Text-to-speech:

- Primary: OpenAI Realtime API over WebSocket for lower-latency audio output.
- Fallback: standard OpenAI speech endpoint (`/v1/audio/speech`) if realtime fails.
- Output plays locally with `AVAudioPlayer`.

### Live Voice Modes

- `Continuous`: auto-records turns back-to-back.
- `Push-to-talk`: records only while you tap.

Lifecycle safety (sleep/lock/wake):

- ClawBar pauses live voice on sleep/lock/session inactive.
- It resumes only if voice was active before the pause.
- Recording/playback tasks are cleaned up during lifecycle transitions and app termination.

## Security and Local Data

API key:

- Stored in your macOS Keychain as `com.openclaw.clawbar`.
- Not written to plaintext app config files.

Local persisted state:

- Chat/session history is saved in Application Support so conversations survive restarts.
- Logs from launch-at-login mode can be written under `~/Library/Logs/ClawBar.log`.

Network calls:

- OpenAI APIs for STT/TTS.
- GitHub release API for update checks.

## Project Structure

- `Sources/ClawBarApp/` app source
- `Sources/ClawBarApp/ClawBarViewModel.swift` state + orchestration
- `Sources/ClawBarApp/OpenAIServices.swift` Whisper + TTS integrations
- `Sources/ClawBarApp/OpenClawRelay.swift` OpenClaw CLI bridge
- `Sources/ClawBarApp/LaunchAgentManager.swift` launch-at-login plumbing
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

### Manual update check says update feed is not found

If releases are private, unauthenticated clients cannot read `releases/latest` from the GitHub API. In that case in-app update checks will fail until release metadata is publicly reachable.

## License

Add your preferred license here.
