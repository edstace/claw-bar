import AppKit
import AVFoundation
import Foundation

extension ClawBarViewModel {
    // MARK: - Voice Settings

    func saveVoiceSettings() {
        let voice = selectedVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !voice.isEmpty else { return }
        selectedVoice = voice
        let styleSettings = VoiceStyleSettings(
            style: voiceStyle.trimmingCharacters(in: .whitespacesAndNewlines),
            accent: voiceAccent.trimmingCharacters(in: .whitespacesAndNewlines),
            tone: voiceTone.trimmingCharacters(in: .whitespacesAndNewlines),
            intonation: voiceIntonation.trimmingCharacters(in: .whitespacesAndNewlines),
            pace: voicePace.trimmingCharacters(in: .whitespacesAndNewlines),
            customInstructions: voiceCustomInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        applyVoiceStyleSettings(styleSettings)
        let defaults = UserDefaults.standard
        defaults.set(voice, forKey: voiceSettingKey)
        if let data = try? JSONEncoder().encode(styleSettings),
           let encoded = String(data: data, encoding: .utf8) {
            defaults.set(encoded, forKey: voiceStyleSettingsKey)
        }
        statusMessage = "Voice settings saved"
    }

    func resetVoiceSettingsToProfile() {
        selectedVoice = voiceProfile.voice
        applyVoiceStyleSettings(voiceProfile.styleSettings)
        saveVoiceSettings()
    }

    func loadVoiceSettings() {
        let defaults = UserDefaults.standard
        if let savedVoice = defaults.string(forKey: voiceSettingKey), !savedVoice.isEmpty {
            selectedVoice = savedVoice
        } else {
            selectedVoice = voiceProfile.voice
        }

        if let encodedSettings = defaults.string(forKey: voiceStyleSettingsKey),
           let data = encodedSettings.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(VoiceStyleSettings.self, from: data) {
            applyVoiceStyleSettings(decoded)
        } else if let legacyPrompt = defaults.string(forKey: legacyStylePromptSettingKey) {
            applyVoiceStyleSettings(VoiceStyleSettings(customInstructions: legacyPrompt))
        } else {
            applyVoiceStyleSettings(voiceProfile.styleSettings)
        }
    }

    private func applyVoiceStyleSettings(_ settings: VoiceStyleSettings) {
        voiceStyle = settings.style
        voiceAccent = settings.accent
        voiceTone = settings.tone
        voiceIntonation = settings.intonation
        voicePace = settings.pace
        voiceCustomInstructions = settings.customInstructions
    }

    private func voiceInstructionsPrompt() -> String? {
        let prompt = VoiceStyleSettings(
            style: voiceStyle,
            accent: voiceAccent,
            tone: voiceTone,
            intonation: voiceIntonation,
            pace: voicePace,
            customInstructions: voiceCustomInstructions
        ).composedPrompt()
        return prompt.isEmpty ? nil : prompt
    }

    // MARK: - Gateway Settings

    func loadGatewaySettings() {
        gatewayEnabled = GatewayRelay.isEnabled
        gatewayURL = GatewayRelay.gatewayURL
        gatewayToken = GatewayRelay.gatewayToken
        gatewayAgentId = GatewayRelay.agentId
    }

    func saveGatewaySettings() {
        GatewayRelay.setEnabled(gatewayEnabled)
        GatewayRelay.gatewayURL = gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        GatewayRelay.gatewayToken = gatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)
        GatewayRelay.agentId = gatewayAgentId.trimmingCharacters(in: .whitespacesAndNewlines)
        statusMessage = gatewayEnabled ? "Gateway mode enabled" : "CLI mode enabled"
        Task { await refreshSetupChecks() }
    }

    func testGatewayConnection() {
        isTestingGateway = true
        gatewayTestResult = nil

        // Temporarily apply settings for the test
        GatewayRelay.setEnabled(true)
        GatewayRelay.gatewayURL = gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        GatewayRelay.gatewayToken = gatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)
        GatewayRelay.agentId = gatewayAgentId.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            let reachable = await GatewayRelay.ping()
            // Restore actual enabled state
            GatewayRelay.setEnabled(gatewayEnabled)

            isTestingGateway = false
            if reachable {
                gatewayTestResult = "✅ Connected successfully"
                statusMessage = "Gateway connection test passed"
            } else {
                gatewayTestResult = "❌ Connection failed — check URL and token"
                statusMessage = "Gateway connection test failed"
            }
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

    func handleLifecyclePause(reason: String) {
        lifecyclePauseDepth += 1
        guard lifecyclePauseDepth == 1 else { return }

        shouldResumeLiveVoiceAfterLifecyclePause = isLiveVoiceEnabled
        liveAutoStopTask?.cancel()
        liveAutoStopTask = nil

        if isRecording {
            _ = audioCapture.stopRecording()
            audioCapture.cleanup()
            isRecording = false
        }

        if isSpeaking {
            audioPlayer?.stop()
            audioPlayer = nil
            isSpeaking = false
        }

        if isLiveVoiceEnabled {
            isLiveVoiceEnabled = false
        }

        if composerText == "Listening…" || composerText == "Recording… tap mic to send" {
            composerText = liveVoiceMode == .pushToTalk ? "Tap mic to talk" : "Live voice paused"
        }
        statusMessage = reason
    }

    func handleLifecycleResume() {
        guard lifecyclePauseDepth > 0 else { return }
        lifecyclePauseDepth -= 1
        guard lifecyclePauseDepth == 0 else { return }

        guard shouldResumeLiveVoiceAfterLifecyclePause else { return }
        shouldResumeLiveVoiceAfterLifecyclePause = false
        enableLiveVoice()
    }

    func handleAppWillTerminate() {
        liveAutoStopTask?.cancel()
        liveAutoStopTask = nil
        autoSaveTask?.cancel()
        autoSaveTask = nil
        apiRateMonitorTask?.cancel()
        apiRateMonitorTask = nil

        if isRecording {
            _ = audioCapture.stopRecording()
            audioCapture.cleanup()
            isRecording = false
        }

        if isSpeaking {
            audioPlayer?.stop()
            audioPlayer = nil
            isSpeaking = false
        }

        persistSession()
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

        if relayDiagnostics.mode == .gateway {
            // Gateway WebSocket mode — no CLI/Node needed
            checks.append(
                SetupCheck(
                    key: "gateway_connection",
                    title: "Gateway Connection",
                    level: relayDiagnostics.relayReachable ? .ok : .error,
                    detail: relayDiagnostics.relayReachable
                        ? "Connected to \(relayDiagnostics.cliPath ?? "gateway")."
                        : (relayDiagnostics.detail ?? "Gateway unreachable."),
                    hint: relayDiagnostics.relayReachable ? nil : "Check the gateway URL and token in Settings → Connection."
                )
            )
        } else {
            // CLI mode — need openclaw + node
            checks.append(
                SetupCheck(
                    key: "openclaw_cli",
                    title: "OpenClaw CLI",
                    level: relayDiagnostics.cliPath == nil ? .error : .ok,
                    detail: relayDiagnostics.cliPath ?? "Not found in known locations or PATH.",
                    hint: relayDiagnostics.cliPath == nil ? "Install OpenClaw CLI, set OPENCLAW_CLI_PATH, or switch to Gateway mode in Settings → Connection." : nil
                )
            )
            checks.append(
                SetupCheck(
                    key: "node_runtime",
                    title: "Node Runtime",
                    level: relayDiagnostics.nodePath == nil ? .error : .ok,
                    detail: relayDiagnostics.nodePath ?? "node not found for OpenClaw launcher.",
                    hint: relayDiagnostics.nodePath == nil ? "Install Node.js or switch to Gateway mode." : nil
                )
            )
            checks.append(
                SetupCheck(
                    key: "openclaw_gateway",
                    title: "OpenClaw Gateway",
                    level: relayDiagnostics.relayReachable ? .ok : .warning,
                    detail: relayDiagnostics.relayReachable ? "Reachable via `openclaw status --json`." : (relayDiagnostics.detail ?? "Unavailable."),
                    hint: relayDiagnostics.relayReachable ? nil : "Run `openclaw status --json` in Terminal or switch to Gateway mode."
                )
            )
        }

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
        case "gateway_connection":
            return nil // No CLI command — handled via Settings
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

    func refreshAPIRateSnapshot() async {
        apiRateSnapshot = await OpenAIAPI.rateMonitor.snapshot()
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
        lines.append("API req/min (60s): \(apiRateSnapshot.requestsLast60Seconds)")
        lines.append("API req/hour (60m): \(apiRateSnapshot.requestsLast60Minutes)")
        lines.append("API last status: \(apiRateSnapshot.lastStatusCode.map(String.init) ?? "n/a")")
        lines.append("API last endpoint: \(apiRateSnapshot.lastEndpoint ?? "n/a")")
        lines.append("API last 429: \(apiRateSnapshot.last429At.map { ISO8601DateFormatter().string(from: $0) } ?? "n/a")")
        lines.append(String(format: "API est. cost last request (USD): %.6f", apiRateSnapshot.estimatedCostLastRequestUSD ?? 0))
        lines.append(String(format: "API est. cost today (USD): %.6f", apiRateSnapshot.estimatedCostTodayUSD))
        lines.append(String(format: "API est. cost week (USD): %.6f", apiRateSnapshot.estimatedCostWeekUSD))
        lines.append(String(format: "API est. cost month (USD): %.6f", apiRateSnapshot.estimatedCostMonthUSD))
        lines.append(
            String(
                format: "Cost assumptions: Whisper/min=%.6f, TTS legacy/1M chars=%.3f, TTS HD/1M chars=%.3f, gpt-4o-mini-tts/min=%.6f, chars/min=%.1f",
                OpenAICostEstimator.whisperUSDPerMinute(),
                OpenAICostEstimator.ttsLegacyUSDPer1MChars(),
                OpenAICostEstimator.ttsHDUSDPer1MChars(),
                OpenAICostEstimator.ttsMiniUSDPerMinute(),
                OpenAICostEstimator.ttsEstimatedCharsPerMinute()
            )
        )
        if let remaining = apiRateSnapshot.requestRemaining, let limit = apiRateSnapshot.requestLimit {
            lines.append("API request budget: \(remaining)/\(limit) remaining")
        }
        if let remainingTokens = apiRateSnapshot.tokenRemaining, let tokenLimit = apiRateSnapshot.tokenLimit {
            lines.append("API token budget: \(remainingTokens)/\(tokenLimit) remaining")
        }
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
                composerText = ""
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

    private func speakLatest() {
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
                    instructions: voiceInstructionsPrompt()
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

    private func clearTranscript() {
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

    func showError(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showErrorAlert = true
        ErrorReporter.capture(message: "\(title): \(message)")
        appendRecentError("\(title): \(message)")
    }

    func appendRecentError(_ message: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        recentErrors.append("[\(ts)] \(message)")
        ErrorReporter.capture(message: message)
        if recentErrors.count > 30 {
            recentErrors.removeFirst(recentErrors.count - 30)
        }
    }

    func loadSpeechDetectionSettings() {
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

    func loadLiveVoiceSettings() {
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

    func restoreSession() {
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
