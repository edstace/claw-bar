import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public final class ClawBarViewModel: ObservableObject {
    // MARK: - Published State

    @Published var apiKey: String = ""
    @Published var isRecording: Bool = false
    @Published var isTranscribing: Bool = false
    @Published var isSpeaking: Bool = false
    @Published var isLiveVoiceEnabled: Bool = false
    @Published var composerText: String = ""
    @Published var hasSavedAPIKey: Bool = false
    @Published var selectedVoice: String = "cedar"
    @Published var voiceStylePrompt: String = ""
    @Published var transcript: String = ""
    @Published var chatEntries: [ChatEntry] = []
    @Published var pendingAttachments: [AttachmentItem] = []
    @Published var latestTranscript: String = ""
    @Published var statusMessage: String = "Idle"
    @Published var showErrorAlert: Bool = false
    @Published var alertTitle: String = ""
    @Published var alertMessage: String = ""
    @Published var relayToOpenClaw: Bool = true
    @Published var setupChecks: [SetupCheck] = []
    @Published var setupLastCheckedAt: Date?
    @Published var isCheckingSetup: Bool = false
    @Published var recentErrors: [String] = []
    @Published var setupBanner: String?
    @Published var keychainStartupIssue: String?
    @Published var launchAtLoginEnabled: Bool = false
    @Published var isUpdatingLaunchAtLogin: Bool = false
    @Published var sttPreset: STTSensitivityPreset = .normal
    @Published var sttSensitivity: Double = 0.5
    @Published var liveVoiceMode: LiveVoiceMode = .continuous
    @Published var showReliabilityHUD: Bool = false
    @Published var lastTranscribeDurationMs: Int?
    @Published var lastRelayDurationMs: Int?
    @Published var lastRelayRetryCount: Int = 0
    @Published var isCheckingForUpdates: Bool = false
    @Published var availableUpdateVersion: String?
    @Published var availableUpdateURL: URL?
    @Published var lastUpdateCheckAt: Date?

    // MARK: - Private

    private let audioCapture = AudioCaptureManager()
    private var audioPlayer: AVAudioPlayer?
    private var autoSaveTask: Task<Void, Never>?
    private var liveAutoStopTask: Task<Void, Never>?
    private var lastSavedAPIKey: String = ""
    private let liveTurnMaxSeconds: Duration = .seconds(6)
    private let voiceProfile = VoiceCallProfile.load()
    private let voiceSettingKey = "clawbar.settings.voice"
    private let stylePromptSettingKey = "clawbar.settings.stylePrompt"
    private let sttPresetSettingKey = "clawbar.settings.sttPreset"
    private let liveVoiceModeSettingKey = "clawbar.settings.liveVoiceMode"
    private let showReliabilityHUDSettingKey = "clawbar.settings.showReliabilityHUD"
    private let updateLastCheckedAtKey = "clawbar.updates.lastCheckedAt"
    private let sessionStore = SessionStore()

    let availableVoices: [String] = [
        "alloy", "ash", "ballad", "cedar", "coral", "echo", "marin", "sage", "shimmer", "verse",
    ]

    init() {
        // Load saved API key from Keychain
        do {
            if let saved = try KeychainManager.load() {
                let trimmed = saved.trimmingCharacters(in: .whitespacesAndNewlines)
                apiKey = trimmed
                lastSavedAPIKey = trimmed
                hasSavedAPIKey = !trimmed.isEmpty
            }
        } catch {
            keychainStartupIssue = error.localizedDescription
            statusMessage = "Keychain access needs approval"
            appendRecentError("Keychain startup access: \(error.localizedDescription)")
        }
        loadVoiceSettings()
        loadSpeechDetectionSettings()
        loadLiveVoiceSettings()
        launchAtLoginEnabled = LaunchAgentManager.isEnabled()
        restoreSession()
        Task { [weak self] in
            await self?.checkForUpdatesIfDue()
            await self?.refreshSetupChecks()
        }
    }

    // MARK: - API Key

    func saveAPIKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showError(title: "API Key", message: "API key cannot be empty.")
            return
        }
        apiKey = trimmed
        do {
            try KeychainManager.save(apiKey: trimmed)
            lastSavedAPIKey = trimmed
            hasSavedAPIKey = true
            keychainStartupIssue = nil
            statusMessage = "API key saved to Keychain ✓"
        } catch {
            showError(title: "Keychain Error", message: error.localizedDescription)
        }
    }

    func scheduleAPIKeyAutosave() {
        autoSaveTask?.cancel()
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sk-"), trimmed.count > 20, trimmed != lastSavedAPIKey else {
            return
        }

        autoSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self else { return }

            let latest = self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard latest == trimmed else { return }
            do {
                try KeychainManager.save(apiKey: latest)
                lastSavedAPIKey = latest
                hasSavedAPIKey = true
                keychainStartupIssue = nil
                statusMessage = "API key auto-saved to Keychain ✓"
            } catch {
                statusMessage = "API key auto-save failed"
            }
        }
    }

    func replaceAPIKey(_ newKey: String) {
        let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sk-"), trimmed.count > 20 else {
            showError(title: "API Key", message: "Enter a valid OpenAI API key (starts with sk-).")
            return
        }
        apiKey = trimmed
        saveAPIKey()
    }

    func removeAPIKey() {
        do {
            try KeychainManager.delete()
            apiKey = ""
            lastSavedAPIKey = ""
            hasSavedAPIKey = false
            keychainStartupIssue = nil
            statusMessage = "API key removed from Keychain"
        } catch {
            showError(title: "Keychain Error", message: error.localizedDescription)
        }
    }

    func openKeychainAccess() {
        let keychainURL = URL(fileURLWithPath: "/System/Applications/Utilities/Keychain Access.app")
        NSWorkspace.shared.openApplication(at: keychainURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    // MARK: - Updates

    var currentVersionDisplay: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    func checkForUpdatesIfDue() async {
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: updateLastCheckedAtKey) as? Date {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < 60 * 60 * 24 {
                lastUpdateCheckAt = last
                return
            }
        }
        await checkForUpdates(userInitiated: false)
    }

    func checkForUpdates(userInitiated: Bool) async {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer {
            isCheckingForUpdates = false
        }

        let now = Date()
        UserDefaults.standard.set(now, forKey: updateLastCheckedAtKey)
        lastUpdateCheckAt = now

        let bundle = Bundle.main
        let currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        do {
            if let update = try await UpdateChecker.check(currentVersion: currentVersion) {
                availableUpdateVersion = update.version
                availableUpdateURL = update.downloadURL
                statusMessage = "Update available: v\(update.version)"
            } else {
                availableUpdateVersion = nil
                availableUpdateURL = nil
                if userInitiated {
                    statusMessage = "ClawBar is up to date"
                }
            }
        } catch {
            if userInitiated {
                showError(title: "Update Check Failed", message: error.localizedDescription)
            } else {
                appendRecentError("Update check: \(error.localizedDescription)")
            }
        }
    }

    func openAvailableUpdate() {
        if let url = availableUpdateURL {
            NSWorkspace.shared.open(url)
            return
        }
        if let fallback = URL(string: "https://github.com/edstace/claw-bar/releases") {
            NSWorkspace.shared.open(fallback)
        }
    }

    // MARK: - Voice Settings

    func saveVoiceSettings() {
        let voice = selectedVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !voice.isEmpty else { return }
        selectedVoice = voice
        let defaults = UserDefaults.standard
        defaults.set(voice, forKey: voiceSettingKey)
        defaults.set(voiceStylePrompt, forKey: stylePromptSettingKey)
        statusMessage = "Voice settings saved"
    }

    func resetVoiceSettingsToProfile() {
        selectedVoice = voiceProfile.voice
        voiceStylePrompt = voiceProfile.stylePrompt ?? ""
        saveVoiceSettings()
    }

    private func loadVoiceSettings() {
        let defaults = UserDefaults.standard
        if let savedVoice = defaults.string(forKey: voiceSettingKey), !savedVoice.isEmpty {
            selectedVoice = savedVoice
        } else {
            selectedVoice = voiceProfile.voice
        }

        if let savedPrompt = defaults.string(forKey: stylePromptSettingKey) {
            voiceStylePrompt = savedPrompt
        } else {
            voiceStylePrompt = voiceProfile.stylePrompt ?? ""
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        guard !isLiveVoiceEnabled else { return }
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func toggleLiveVoice() {
        if isLiveVoiceEnabled {
            disableLiveVoice()
        } else {
            enableLiveVoice()
        }
    }

    func handleMicButtonTap() {
        if isLiveVoiceEnabled {
            if liveVoiceMode == .pushToTalk {
                if isRecording {
                    stopRecording()
                } else if !isSpeaking && !isTranscribing {
                    startRecording()
                }
            } else {
                disableLiveVoice()
            }
            return
        }
        enableLiveVoice()
    }

    private func enableLiveVoice() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.hasPrefix("sk-"), trimmedKey.count > 20 else {
            showError(title: "API Key", message: "OpenAI API key looks invalid. Paste a key that starts with sk-.")
            return
        }
        isLiveVoiceEnabled = true
        relayToOpenClaw = true
        if composerText.isEmpty {
            composerText = liveVoiceMode == .continuous ? "Listening…" : "Tap mic to talk"
        }
        statusMessage = liveVoiceMode == .pushToTalk ? "Live voice enabled (push-to-talk)" : "Live voice enabled"
        if liveVoiceMode == .continuous, !isRecording && !isSpeaking && !isTranscribing {
            startRecording()
        }
    }

    private func disableLiveVoice() {
        isLiveVoiceEnabled = false
        liveAutoStopTask?.cancel()
        liveAutoStopTask = nil
        if isRecording {
            _ = audioCapture.stopRecording()
            isRecording = false
        }
        if composerText == "Listening…" || composerText == "Tap mic to talk" || composerText == "Recording… tap mic to send" {
            composerText = ""
        }
        statusMessage = "Live voice disabled"
    }

    func sendComposerText() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard !text.isEmpty || !attachments.isEmpty else { return }
        composerText = ""
        pendingAttachments = []
        let messageText = text.isEmpty ? "Please analyze the attached files." : text
        Task {
            await processUserText(messageText, prefix: "💬", attachments: attachments)
        }
    }

    func addAttachments(urls: [URL]) {
        let mapped = urls.map { AttachmentItem(url: $0) }
        for item in mapped where !pendingAttachments.contains(where: { $0.path == item.path }) {
            pendingAttachments.append(item)
        }
    }

    func removeAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    func speakText(_ text: String) {
        Task { await speak(text: text) }
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "Copied"
    }

    func resendToOpenClaw(text: String) {
        Task {
            await processUserText(text, prefix: "💬", attachments: [])
        }
    }

    func startNewChat() {
        clearTranscript()
        OpenClawRelay.rotateSession()
        statusMessage = "Started new chat"
        persistSession()
    }

    func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    func refreshSetupChecks() async {
        isCheckingSetup = true
        defer {
            isCheckingSetup = false
            setupLastCheckedAt = Date()
        }

        var checks: [SetupCheck] = []
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasValidKey = trimmedKey.hasPrefix("sk-") && trimmedKey.count > 20
        let apiKeyLevel = Self.apiKeySetupLevel(apiKey: trimmedKey)
        let keyDetail: String
        if let keychainIssue = keychainStartupIssue {
            keyDetail = "Keychain access blocked: \(keychainIssue)"
        } else {
            keyDetail = hasValidKey ? "Stored in Keychain." : (trimmedKey.isEmpty ? "No key stored in Keychain." : "Key looks invalid (must start with sk-).")
        }
        let keyHint = keychainStartupIssue == nil ? "Open Settings and save a valid OpenAI API key." : "Allow ClawBar to access com.openclaw.clawbar in Keychain Access, then reopen ClawBar."
        checks.append(
            SetupCheck(
                key: "api_key",
                title: "OpenAI API Key",
                level: keychainStartupIssue == nil ? apiKeyLevel : .warning,
                detail: keyDetail,
                hint: keyHint
            )
        )

        let micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        let micLevel = Self.microphoneSetupLevel(status: micAuth)
        let micCheck: SetupCheck
        switch micAuth {
        case .authorized:
            micCheck = SetupCheck(key: "microphone", title: "Microphone Permission", level: micLevel, detail: "Granted.", hint: nil)
        case .notDetermined:
            micCheck = SetupCheck(key: "microphone", title: "Microphone Permission", level: micLevel, detail: "Not requested yet.", hint: "Enable live voice once to trigger permission prompt.")
        case .denied, .restricted:
            micCheck = SetupCheck(key: "microphone", title: "Microphone Permission", level: micLevel, detail: "Denied or restricted.", hint: "Enable microphone access for ClawBar in System Settings > Privacy & Security > Microphone.")
        @unknown default:
            micCheck = SetupCheck(key: "microphone", title: "Microphone Permission", level: micLevel, detail: "Unknown state.", hint: nil)
        }
        checks.append(micCheck)

        let relayDiagnostics = await OpenClawRelay.diagnostics()
        checks.append(
            SetupCheck(
                key: "openclaw_cli",
                title: "OpenClaw CLI",
                level: relayDiagnostics.cliPath == nil ? .error : .ok,
                detail: relayDiagnostics.cliPath ?? "Not found in known locations or PATH.",
                hint: relayDiagnostics.cliPath == nil ? "Install OpenClaw CLI or set OPENCLAW_CLI_PATH to the binary path." : nil
            )
        )
        checks.append(
            SetupCheck(
                key: "node_runtime",
                title: "Node Runtime",
                level: relayDiagnostics.nodePath == nil ? .error : .ok,
                detail: relayDiagnostics.nodePath ?? "node not found for OpenClaw launcher.",
                hint: relayDiagnostics.nodePath == nil ? "Install Node.js or add it to PATH (for example ~/.n/bin)." : nil
            )
        )
        checks.append(
            SetupCheck(
                key: "openclaw_gateway",
                title: "OpenClaw Gateway",
                level: relayDiagnostics.relayReachable ? .ok : .warning,
                detail: relayDiagnostics.relayReachable ? "Reachable via `openclaw status --json`." : (relayDiagnostics.detail ?? "Unavailable."),
                hint: relayDiagnostics.relayReachable ? nil : "Run `openclaw status --json` in Terminal to inspect service health."
            )
        )

        setupChecks = checks
        applyStartupSelfHealBanner(from: checks)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isUpdatingLaunchAtLogin else { return }
        isUpdatingLaunchAtLogin = true
        Task.detached(priority: .userInitiated) {
            do {
                if enabled {
                    try LaunchAgentManager.enable()
                } else {
                    try LaunchAgentManager.disable()
                }
                let actual = LaunchAgentManager.isEnabled()
                await MainActor.run {
                    self.launchAtLoginEnabled = actual
                    self.isUpdatingLaunchAtLogin = false
                    self.statusMessage = actual ? "Launch at login enabled" : "Launch at login disabled"
                }
            } catch {
                let actual = LaunchAgentManager.isEnabled()
                await MainActor.run {
                    self.launchAtLoginEnabled = actual
                    self.isUpdatingLaunchAtLogin = false
                    self.showError(title: "Launch at Login", message: error.localizedDescription)
                }
            }
        }
    }

    func applySTTPreset(_ preset: STTSensitivityPreset) {
        sttPreset = preset
        sttSensitivity = preset.sensitivity
        persistSpeechDetectionSettings()
    }

    func updateSTTSensitivity(_ value: Double) {
        sttSensitivity = min(max(value, 0), 1)
        if let matched = STTSensitivityPreset.matchingPreset(for: sttSensitivity) {
            sttPreset = matched
        } else {
            sttPreset = .custom
        }
        persistSpeechDetectionSettings()
    }

    func recommendedCommand(for check: SetupCheck) -> String? {
        switch check.key {
        case "openclaw_cli":
            return "brew install openclaw"
        case "node_runtime":
            return "brew install node"
        case "openclaw_gateway":
            return "openclaw status --json"
        default:
            return nil
        }
    }

    func copySetupCommand(for check: SetupCheck) {
        guard let command = recommendedCommand(for: check) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        statusMessage = "Copied setup command"
    }

    func copyDiagnosticsReport() {
        let report = diagnosticsReport()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        statusMessage = "Diagnostics copied"
    }

    func diagnosticsReport() -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        var lines: [String] = []
        lines.append("ClawBar Diagnostics")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("Version: \(version) (\(build))")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Live Voice: \(isLiveVoiceEnabled ? "enabled" : "disabled")")
        lines.append("Live Voice Mode: \(liveVoiceMode.title)")
        lines.append("Status: \(statusMessage)")
        lines.append("Last Transcribe ms: \(lastTranscribeDurationMs.map(String.init) ?? "n/a")")
        lines.append("Last Relay ms: \(lastRelayDurationMs.map(String.init) ?? "n/a")")
        lines.append("Last Relay retries: \(lastRelayRetryCount)")
        lines.append("")
        lines.append("Setup Checks:")
        for check in setupChecks {
            lines.append("- \(check.title): \(check.level.rawValue.uppercased()) | \(check.detail)")
            if let hint = check.hint, !hint.isEmpty {
                lines.append("  Hint: \(hint)")
            }
        }
        lines.append("")
        lines.append("Recent Errors:")
        if recentErrors.isEmpty {
            lines.append("- none")
        } else {
            for error in recentErrors.suffix(12) {
                lines.append("- \(error)")
            }
        }
        return lines.joined(separator: "\n")
    }

    var assistantStateText: String? {
        if isRecording { return "Listening…" }
        if isTranscribing { return "Thinking…" }
        if isSpeaking { return "Speaking…" }
        if isLiveVoiceEnabled, liveVoiceMode == .pushToTalk { return "Tap mic to talk" }
        return nil
    }

    private func startRecording() {
        guard !isRecording else { return }
        Task {
            let granted = await AudioCaptureManager.requestPermission()
            guard granted else {
                showError(title: "Mic Access", message: "Microphone permission is required.")
                return
            }
            do {
                try audioCapture.startRecording()
                isRecording = true
                statusMessage = isLiveVoiceEnabled ? "Listening…" : "Recording…"
                if isLiveVoiceEnabled {
                    composerText = liveVoiceMode == .pushToTalk ? "Recording… tap mic to send" : "Listening…"
                }
                scheduleLiveAutoStopIfNeeded()
            } catch {
                showError(title: "Recording Error", message: error.localizedDescription)
            }
        }
    }

    private func stopRecording() {
        liveAutoStopTask?.cancel()
        liveAutoStopTask = nil
        guard let url = audioCapture.stopRecording() else {
            statusMessage = "No recording found"
            isRecording = false
            return
        }
        isRecording = false
        isTranscribing = true
        statusMessage = "Transcribing…"

        Task {
            await transcribe(fileURL: url)
            audioCapture.cleanup()
            if isLiveVoiceEnabled, liveVoiceMode == .continuous, !isRecording, !isSpeaking, !isTranscribing {
                startRecording()
            } else if isLiveVoiceEnabled, liveVoiceMode == .pushToTalk {
                composerText = "Tap mic to talk"
            }
        }
    }

    private func scheduleLiveAutoStopIfNeeded() {
        liveAutoStopTask?.cancel()
        guard isLiveVoiceEnabled, liveVoiceMode == .continuous else { return }
        liveAutoStopTask = Task { [weak self] in
            let maxDuration = self?.liveTurnMaxSeconds ?? .seconds(6)
            try? await Task.sleep(for: maxDuration)
            guard !Task.isCancelled, let self, self.isRecording else { return }
            self.stopRecording()
        }
    }

    // MARK: - Whisper STT

    private func transcribe(fileURL: URL) async {
        defer { isTranscribing = false }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.hasPrefix("sk-"), trimmedKey.count > 20 else {
            showError(title: "API Key", message: "OpenAI API key looks invalid. Paste a key that starts with sk-.")
            statusMessage = "Transcription failed"
            return
        }

        do {
            let start = Date()
            let text = try await WhisperService.transcribe(fileURL: fileURL, apiKey: trimmedKey)
            lastTranscribeDurationMs = Int(Date().timeIntervalSince(start) * 1000)
            await processUserText(text, prefix: "🎤", attachments: [])
        } catch ClawBarError.audioTooShort {
            statusMessage = isLiveVoiceEnabled ? "Listening…" : "No speech detected"
        } catch ClawBarError.emptyTranscription {
            statusMessage = isLiveVoiceEnabled ? "Listening…" : "No speech detected"
        } catch ClawBarError.noSpeechDetected {
            statusMessage = isLiveVoiceEnabled ? "Listening…" : "No speech detected"
        } catch {
            showError(title: "Transcription Error", message: error.localizedDescription)
            statusMessage = "Transcription failed"
        }
    }

    private func processUserText(_ text: String, prefix: String, attachments: [AttachmentItem]) async {
        latestTranscript = text
        if !transcript.isEmpty { transcript += "\n" }
        transcript += "\(prefix) \(text)"
        if !attachments.isEmpty {
            transcript += "\n📎 " + attachments.map(\.fileName).joined(separator: ", ")
        }
        appendChat(role: .user, text: text, attachments: attachments)
        statusMessage = "Transcribed ✓"
        if isLiveVoiceEnabled {
            composerText = "You: \(text)"
        }

        if relayToOpenClaw {
            await relayText(text, attachments: attachments)
        } else if isLiveVoiceEnabled {
            await speak(text: text)
        }
    }

    // MARK: - OpenClaw Relay

    private func relayText(_ text: String, attachments: [AttachmentItem]) async {
        statusMessage = "Relaying to OpenClaw…"
        do {
            let result = try await OpenClawRelay.send(text: text, attachments: attachments)
            lastRelayDurationMs = result.durationMs
            lastRelayRetryCount = result.retryCount
            if !result.text.isEmpty {
                transcript += "\n🤖 \(result.text)"
                appendChat(role: .assistant, text: result.text, attachments: [])
                latestTranscript = result.text
                statusMessage = "Relay complete ✓"
                if isLiveVoiceEnabled {
                    composerText = "You: \(text)\nOpenClaw: \(result.text)"
                }
                if isLiveVoiceEnabled {
                    await speak(text: result.text)
                }
            } else {
                statusMessage = "Relay complete (no text reply)"
            }
        } catch {
            // Non-fatal — keep transcript and surface the real reason.
            statusMessage = "OpenClaw relay failed: \(error.localizedDescription)"
            appendRecentError("Relay: \(error.localizedDescription)")
        }
    }

    // MARK: - TTS

    func speakLatest() {
        guard !latestTranscript.isEmpty else { return }
        Task {
            await speak(text: latestTranscript)
        }
    }

    private func speak(text: String) async {
        isSpeaking = true
        statusMessage = "Synthesizing speech…"
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let audioData: Data
            let fileExtension: String
            do {
                audioData = try await RealtimeTTSService.synthesize(
                    text: text,
                    apiKey: trimmedKey,
                    voice: selectedVoice,
                    instructions: voiceStylePrompt
                )
                fileExtension = "wav"
            } catch {
                // Fallback to non-realtime TTS if websocket synthesis fails.
                audioData = try await TTSService.synthesize(
                    text: text,
                    apiKey: trimmedKey,
                    model: "gpt-4o-mini-tts",
                    voice: selectedVoice
                )
                fileExtension = "mp3"
            }

            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("clawbar-tts-\(UUID().uuidString).\(fileExtension)")
            try audioData.write(to: tempURL)
            let player = try AVAudioPlayer(contentsOf: tempURL)
            self.audioPlayer = player
            player.play()
            statusMessage = "Speaking…"

            while player.isPlaying {
                try await Task.sleep(for: .milliseconds(200))
            }
            isSpeaking = false
            statusMessage = isLiveVoiceEnabled ? "Listening…" : "Idle"
        } catch {
            isSpeaking = false
            showError(title: "TTS Error", message: error.localizedDescription)
            statusMessage = "TTS failed"
            appendRecentError("TTS: \(error.localizedDescription)")
        }
    }

    // MARK: - Utilities

    func clearTranscript() {
        transcript = ""
        chatEntries = []
        latestTranscript = ""
        pendingAttachments = []
        persistSession()
    }

    private func appendChat(role: ChatRole, text: String, attachments: [AttachmentItem]) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty || !attachments.isEmpty else { return }
        chatEntries.append(ChatEntry(role: role, text: cleaned, attachments: attachments, timestamp: Date()))
        persistSession()
    }

    private func showError(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showErrorAlert = true
        appendRecentError("\(title): \(message)")
    }

    private func appendRecentError(_ message: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        recentErrors.append("[\(ts)] \(message)")
        if recentErrors.count > 30 {
            recentErrors.removeFirst(recentErrors.count - 30)
        }
    }

    private func loadSpeechDetectionSettings() {
        let defaults = UserDefaults.standard
        let storedSensitivity = WhisperService.speechSensitivity()
        sttSensitivity = storedSensitivity

        if let raw = defaults.string(forKey: sttPresetSettingKey),
           let preset = STTSensitivityPreset(rawValue: raw)
        {
            sttPreset = preset
        } else {
            sttPreset = STTSensitivityPreset.matchingPreset(for: storedSensitivity) ?? .custom
        }
    }

    private func loadLiveVoiceSettings() {
        let defaults = UserDefaults.standard
        showReliabilityHUD = defaults.bool(forKey: showReliabilityHUDSettingKey)
        if let raw = defaults.string(forKey: liveVoiceModeSettingKey),
           let mode = LiveVoiceMode(rawValue: raw)
        {
            liveVoiceMode = mode
        } else {
            liveVoiceMode = .continuous
        }
    }

    func setLiveVoiceMode(_ mode: LiveVoiceMode) {
        liveVoiceMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: liveVoiceModeSettingKey)
        if isLiveVoiceEnabled {
            if mode == .continuous, !isRecording, !isTranscribing, !isSpeaking {
                startRecording()
            } else if mode == .pushToTalk {
                liveAutoStopTask?.cancel()
                liveAutoStopTask = nil
                if composerText.isEmpty || composerText == "Listening…" {
                    composerText = "Tap mic to talk"
                }
            }
        }
    }

    func setShowReliabilityHUD(_ enabled: Bool) {
        showReliabilityHUD = enabled
        UserDefaults.standard.set(enabled, forKey: showReliabilityHUDSettingKey)
    }

    private func persistSpeechDetectionSettings() {
        let defaults = UserDefaults.standard
        defaults.set(sttPreset.rawValue, forKey: sttPresetSettingKey)
        WhisperService.setSpeechSensitivity(sttSensitivity)
        statusMessage = "Speech detection updated"
    }

    private func restoreSession() {
        guard let session = sessionStore.load() else { return }
        transcript = session.transcript
        latestTranscript = session.latestTranscript
        chatEntries = session.entries.map { $0.toChatEntry() }
    }

    private func persistSession() {
        let payload = PersistedSession(
            transcript: transcript,
            latestTranscript: latestTranscript,
            entries: chatEntries.map { PersistedChatEntry(from: $0) }
        )
        sessionStore.save(payload)
    }

    private func applyStartupSelfHealBanner(from checks: [SetupCheck]) {
        if keychainStartupIssue != nil {
            setupBanner = "Keychain access blocked. Click Open Keychain to grant ClawBar access."
            return
        }
        if let blocker = checks.first(where: { $0.level == .error }) {
            setupBanner = "Setup needed: \(blocker.title)"
            return
        }
        if let warning = checks.first(where: { $0.level == .warning }) {
            setupBanner = "Setup check: \(warning.title)"
            return
        }
        setupBanner = nil
    }

    public nonisolated static func apiKeySetupLevel(apiKey: String) -> SetupCheckLevel {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("sk-") && trimmed.count > 20 ? .ok : .warning
    }

    public nonisolated static func microphoneSetupLevel(status: AVAuthorizationStatus) -> SetupCheckLevel {
        switch status {
        case .authorized:
            return .ok
        case .notDetermined:
            return .warning
        case .denied, .restricted:
            return .error
        @unknown default:
            return .warning
        }
    }
}

private struct VoiceCallProfile {
    let voice: String
    let stylePrompt: String?

    static func load() -> VoiceCallProfile {
        let defaultProfile = VoiceCallProfile(voice: "cedar", stylePrompt: nil)
        guard let configURL = resolveOpenClawConfigURL(),
              let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugins"] as? [String: Any],
              let entries = plugins["entries"] as? [String: Any],
              let voiceCall = entries["voice-call"] as? [String: Any],
              let config = voiceCall["config"] as? [String: Any] else {
            return defaultProfile
        }

        var voice = defaultProfile.voice
        if let tts = config["tts"] as? [String: Any],
           let openai = tts["openai"] as? [String: Any],
           let configuredVoice = openai["voice"] as? String,
           !configuredVoice.isEmpty {
            voice = configuredVoice
        }

        let stylePrompt = config["responseSystemPrompt"] as? String
        return VoiceCallProfile(voice: voice, stylePrompt: stylePrompt)
    }

    private static func resolveOpenClawConfigURL() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var candidates: [URL] = []

        if let openclawHome = ProcessInfo.processInfo.environment["OPENCLAW_HOME"],
           !openclawHome.isEmpty
        {
            candidates.append(URL(fileURLWithPath: openclawHome).appendingPathComponent("openclaw.json"))
        }

        candidates.append(home.appendingPathComponent(".openclaw/openclaw.json"))
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("openclaw.json"))

        return candidates.first(where: { fm.fileExists(atPath: $0.path) })
    }
}

public enum SetupCheckLevel: Equatable {
    case ok
    case warning
    case error

    var rawValue: String {
        switch self {
        case .ok:
            return "ok"
        case .warning:
            return "warning"
        case .error:
            return "error"
        }
    }
}

enum STTSensitivityPreset: String, CaseIterable, Identifiable {
    case quietRoom = "quiet_room"
    case normal = "normal"
    case noisyRoom = "noisy_room"
    case custom = "custom"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quietRoom:
            return "Quiet Room"
        case .normal:
            return "Normal"
        case .noisyRoom:
            return "Noisy Room"
        case .custom:
            return "Custom"
        }
    }

    var sensitivity: Double {
        switch self {
        case .quietRoom:
            return 0.78
        case .normal:
            return 0.50
        case .noisyRoom:
            return 0.25
        case .custom:
            return WhisperService.speechSensitivity()
        }
    }

    static var selectableCases: [STTSensitivityPreset] {
        [.quietRoom, .normal, .noisyRoom]
    }

    static func matchingPreset(for sensitivity: Double) -> STTSensitivityPreset? {
        let value = min(max(sensitivity, 0), 1)
        if abs(value - quietRoom.sensitivity) < 0.02 { return .quietRoom }
        if abs(value - normal.sensitivity) < 0.02 { return .normal }
        if abs(value - noisyRoom.sensitivity) < 0.02 { return .noisyRoom }
        return nil
    }
}

enum LiveVoiceMode: String, CaseIterable, Identifiable {
    case continuous = "continuous"
    case pushToTalk = "push_to_talk"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .continuous:
            return "Continuous"
        case .pushToTalk:
            return "Push-to-talk"
        }
    }
}

struct SetupCheck: Identifiable {
    let key: String
    let title: String
    let level: SetupCheckLevel
    let detail: String
    let hint: String?

    var id: String { key }
}

enum ChatRole {
    case user
    case assistant

    var persistedValue: String {
        switch self {
        case .user:
            return "user"
        case .assistant:
            return "assistant"
        }
    }

    init(persistedValue: String) {
        self = persistedValue == "assistant" ? .assistant : .user
    }
}

struct ChatEntry: Identifiable {
    let id = UUID()
    let role: ChatRole
    let text: String
    let attachments: [AttachmentItem]
    let timestamp: Date
}

struct AttachmentItem: Identifiable, Equatable {
    let id: UUID
    let fileName: String
    let path: String
    let typeLabel: String
    let fileSize: Int64?

    init(url: URL) {
        id = UUID()
        fileName = url.lastPathComponent
        path = url.path

        let ext = url.pathExtension
        if let utType = UTType(filenameExtension: ext),
           let preferred = utType.preferredMIMEType {
            typeLabel = preferred
        } else if !ext.isEmpty {
            typeLabel = ext.lowercased()
        } else {
            typeLabel = "file"
        }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize {
            fileSize = Int64(size)
        } else {
            fileSize = nil
        }
    }

    init(id: UUID, fileName: String, path: String, typeLabel: String, fileSize: Int64?) {
        self.id = id
        self.fileName = fileName
        self.path = path
        self.typeLabel = typeLabel
        self.fileSize = fileSize
    }
}

private struct PersistedSession: Codable {
    let transcript: String
    let latestTranscript: String
    let entries: [PersistedChatEntry]
}

private struct PersistedChatEntry: Codable {
    let role: String
    let text: String
    let attachments: [PersistedAttachment]
    let timestamp: Date

    init(from entry: ChatEntry) {
        role = entry.role.persistedValue
        text = entry.text
        attachments = entry.attachments.map(PersistedAttachment.init)
        timestamp = entry.timestamp
    }

    func toChatEntry() -> ChatEntry {
        ChatEntry(
            role: ChatRole(persistedValue: role),
            text: text,
            attachments: attachments.map(\.toAttachmentItem),
            timestamp: timestamp
        )
    }
}

private struct PersistedAttachment: Codable {
    let id: UUID
    let fileName: String
    let path: String
    let typeLabel: String
    let fileSize: Int64?

    init(_ item: AttachmentItem) {
        id = item.id
        fileName = item.fileName
        path = item.path
        typeLabel = item.typeLabel
        fileSize = item.fileSize
    }

    var toAttachmentItem: AttachmentItem {
        AttachmentItem(
            id: id,
            fileName: fileName,
            path: path,
            typeLabel: typeLabel,
            fileSize: fileSize
        )
    }
}

private struct SessionStore {
    private let fileName = "session-v1.json"

    func load() -> PersistedSession? {
        guard let url = storeURL(),
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return try? JSONDecoder().decode(PersistedSession.self, from: data)
    }

    func save(_ session: PersistedSession) {
        guard let url = storeURL() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(session) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func storeURL() -> URL? {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        return appSupport
            .appendingPathComponent("ClawBar", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}
