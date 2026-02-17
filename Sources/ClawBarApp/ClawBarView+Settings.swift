import SwiftUI

extension ClawBarView {
    var settingsSheet: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.12, green: 0.13, blue: 0.16), Color(red: 0.08, green: 0.09, blue: 0.11)]
                    : [Color(red: 0.97, green: 0.98, blue: 1.0), Color(red: 0.93, green: 0.95, blue: 0.99)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Settings")
                        .font(.title3.weight(.semibold))
                    Text("ClawBar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(spacing: 6) {
                        ForEach(SettingsTab.allCases) { tab in
                            Button {
                                settingsTab = tab
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: tab.icon)
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(tab.title)
                                        .font(.callout.weight(.medium))
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(settingsTab == tab ? Color.accentColor.opacity(0.22) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(settingsTab == tab ? .primary : .secondary)
                        }
                    }
                    Spacer()
                }
                .padding(12)
                .frame(width: 150, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.72))
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        switch settingsTab {
                        case .general:
                            settingsCard("Startup", systemImage: "power.circle") {
                                Toggle(isOn: Binding(
                                    get: { model.launchAtLoginEnabled },
                                    set: { model.setLaunchAtLogin($0) }
                                )) {
                                    Text("Launch ClawBar at Login")
                                }
                                .disabled(model.isUpdatingLaunchAtLogin)
                                .toggleStyle(.switch)
                                Text(model.isUpdatingLaunchAtLogin ? "Updating launch settings…" : "Automatically starts ClawBar when you sign in.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            settingsCard("Updates", systemImage: "arrow.triangle.2.circlepath") {
                                Text("Current version: \(model.currentVersionDisplay)")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)

                                if let available = model.availableUpdateVersion {
                                    Text("New version available: v\(available)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                HStack {
                                    Button(model.isCheckingForUpdates ? "Checking…" : "Check for Updates") {
                                        Task { await model.checkForUpdates(userInitiated: true) }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(model.isCheckingForUpdates)

                                    if model.hasUpdateReady {
                                        Button(model.isDownloadingUpdate ? "Downloading…" : "Install Update") {
                                            model.installAvailableUpdate()
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(model.isDownloadingUpdate)

                                        Button("Skip Version") {
                                            model.skipAvailableUpdate()
                                        }
                                        .buttonStyle(.bordered)

                                        Button("Remind Tomorrow") {
                                            model.remindAboutUpdateTomorrow()
                                        }
                                        .buttonStyle(.bordered)
                                    }

                                    Spacer()

                                    if let checkedAt = model.lastUpdateCheckAt {
                                        Text("Last checked \(Self.timeFormatter.string(from: checkedAt))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                if let updateError = model.updateCheckErrorMessage, !updateError.isEmpty {
                                    Text(updateError)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }

                                if !model.updateReleaseNotes.isEmpty {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Release Notes")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        ScrollView {
                                            Text(model.updateReleaseNotes)
                                                .font(.caption)
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .frame(maxHeight: 130)
                                        .padding(8)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                                    }
                                }
                            }

                            settingsCard("API Key", systemImage: "key.fill") {
                                Text(model.hasSavedAPIKey ? "A key is stored in Keychain." : "No API key stored yet.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Text("Your API key is stored locally in your macOS Keychain and only used to make OpenAI requests from this app.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                                SecureField("Enter new OpenAI API key", text: $replacementKey)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit {
                                        model.replaceAPIKey(replacementKey)
                                        if model.hasSavedAPIKey {
                                            replacementKey = ""
                                        }
                                    }

                                HStack {
                                    Button("Save New Key") {
                                        model.replaceAPIKey(replacementKey)
                                        if model.hasSavedAPIKey {
                                            replacementKey = ""
                                        }
                                        Task { await model.refreshSetupChecks() }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(replacementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                                    Button("Remove Key") {
                                        model.removeAPIKey()
                                        replacementKey = ""
                                        Task { await model.refreshSetupChecks() }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(!model.hasSavedAPIKey)
                                }
                            }

                        case .voice:
                            settingsCard("Live Voice", systemImage: "waveform.badge.mic") {
                                Picker("Mode", selection: Binding(
                                    get: { model.liveVoiceMode },
                                    set: { model.setLiveVoiceMode($0) }
                                )) {
                                    ForEach(LiveVoiceMode.allCases) { mode in
                                        Text(mode.title).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)

                                Toggle(isOn: Binding(
                                    get: { model.showReliabilityHUD },
                                    set: { model.setShowReliabilityHUD($0) }
                                )) {
                                    Text("Show Reliability HUD")
                                }
                                .toggleStyle(.switch)

                                Text("Continuous mode auto-listens in turns. Push-to-talk records only when you tap the mic.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            settingsCard("Speech Detection", systemImage: "waveform.path.ecg") {
                                Picker("Environment", selection: Binding(
                                    get: {
                                        model.sttPreset == .custom ? .normal : model.sttPreset
                                    },
                                    set: { model.applySTTPreset($0) }
                                )) {
                                    ForEach(STTSensitivityPreset.selectableCases) { preset in
                                        Text(preset.title).tag(preset)
                                    }
                                }
                                .pickerStyle(.segmented)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Sensitivity")
                                        Spacer()
                                        Text(String(format: "%.0f%%", model.sttSensitivity * 100))
                                            .foregroundStyle(.secondary)
                                    }
                                    Slider(
                                        value: Binding(
                                            get: { model.sttSensitivity },
                                            set: { model.updateSTTSensitivity($0) }
                                        ),
                                        in: 0...1
                                    )
                                    Text("Higher catches quieter speech. Lower ignores more background noise.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            settingsCard("Voice", systemImage: "speaker.wave.2.fill") {
                                HStack {
                                    Text("Voice")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Picker("Voice", selection: $model.selectedVoice) {
                                        ForEach(model.availableVoices, id: \.self) { voice in
                                            Text(voice.capitalized).tag(voice)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 160)
                                }

                                Group {
                                    Text("Voice Style")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    TextField("e.g. warm, conversational, polished", text: $model.voiceStyle)
                                        .textFieldStyle(.roundedBorder)

                                    Text("Accent")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    TextField("e.g. neutral US, British RP, Australian", text: $model.voiceAccent)
                                        .textFieldStyle(.roundedBorder)

                                    Text("Tone")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    TextField("e.g. friendly, confident, empathetic", text: $model.voiceTone)
                                        .textFieldStyle(.roundedBorder)

                                    Text("Intonation")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    TextField("e.g. expressive but controlled", text: $model.voiceIntonation)
                                        .textFieldStyle(.roundedBorder)

                                    Text("Pace")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    TextField("e.g. medium, deliberate, brisk", text: $model.voicePace)
                                        .textFieldStyle(.roundedBorder)

                                    Text("Extra Instructions")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    TextEditor(text: $model.voiceCustomInstructions)
                                        .font(.callout)
                                        .frame(height: 72)
                                        .padding(6)
                                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.18)))
                                }

                                HStack {
                                    Button("Save Voice Settings") {
                                        model.saveVoiceSettings()
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button("Use Voice-Call Defaults") {
                                        model.resetVoiceSettingsToProfile()
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }

                        case .diagnostics:
                            settingsCard("Setup Check", systemImage: "checklist") {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(model.setupChecks) { check in
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 8) {
                                                Image(systemName: iconName(for: check.level))
                                                    .foregroundStyle(iconColor(for: check.level))
                                                Text(check.title)
                                                    .font(.callout.weight(.semibold))
                                                Spacer()
                                                if check.level != .ok, model.recommendedCommand(for: check) != nil {
                                                    Button("Copy Fix") {
                                                        model.copySetupCommand(for: check)
                                                    }
                                                    .buttonStyle(.borderless)
                                                    .font(.caption2)
                                                }
                                            }
                                            Text(check.detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            if let hint = check.hint, !hint.isEmpty, check.level != .ok {
                                                Text(hint)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .padding(.vertical, 2)
                                    }
                                }

                                HStack(spacing: 8) {
                                    Button(model.isCheckingSetup ? "Checking…" : "Recheck") {
                                        Task { await model.refreshSetupChecks() }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(model.isCheckingSetup)

                                    Button("Copy Diagnostics") {
                                        model.copyDiagnosticsReport()
                                    }
                                    .buttonStyle(.bordered)

                                    if let checkedAt = model.setupLastCheckedAt {
                                        Text("Last checked \(Self.timeFormatter.string(from: checkedAt))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            settingsCard("OpenAI API Rate & Cost", systemImage: "chart.line.uptrend.xyaxis") {
                                let snapshot = model.apiRateSnapshot
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("Requests (60s / 60m)")
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("\(snapshot.requestsLast60Seconds) / \(snapshot.requestsLast60Minutes)")
                                            .font(.callout.weight(.semibold))
                                    }

                                    HStack {
                                        Text("Last status")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(snapshot.lastStatusCode.map(String.init) ?? "n/a")
                                            .font(.caption.weight(.semibold))
                                    }

                                    HStack {
                                        Text("Last endpoint")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(snapshot.lastEndpoint ?? "n/a")
                                            .font(.caption)
                                            .lineLimit(1)
                                    }

                                    HStack {
                                        Text("Last 429")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(relativeTime(snapshot.last429At))
                                            .font(.caption)
                                    }

                                    Divider()

                                    HStack {
                                        Text("Estimated Cost (today / week / month)")
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("\(currency(snapshot.estimatedCostTodayUSD)) / \(currency(snapshot.estimatedCostWeekUSD)) / \(currency(snapshot.estimatedCostMonthUSD))")
                                            .font(.callout.weight(.semibold))
                                    }

                                    HStack {
                                        Text("Last request est.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(currency(snapshot.estimatedCostLastRequestUSD ?? 0))
                                            .font(.caption.weight(.semibold))
                                    }

                                    if let remaining = snapshot.requestRemaining, let limit = snapshot.requestLimit {
                                        HStack {
                                            Text("Request budget")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Text("\(remaining)/\(limit) remaining")
                                                .font(.caption)
                                        }
                                    }

                                    if let remaining = snapshot.tokenRemaining, let limit = snapshot.tokenLimit {
                                        HStack {
                                            Text("Token budget")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Text("\(remaining)/\(limit) remaining")
                                                .font(.caption)
                                        }
                                    }

                                    Text("Cost is estimated from model-specific pricing assumptions (Whisper, tts-1/tts-1-hd, gpt-4o-mini-tts).")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                    HStack {
                                        Button("Refresh API Monitor") {
                                            Task { await model.refreshAPIRateSnapshot() }
                                        }
                                        .buttonStyle(.bordered)

                                        Spacer()

                                        if let lastAt = snapshot.lastRequestAt {
                                            Text("Last request \(Self.timeFormatter.string(from: lastAt))")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }

                        HStack {
                            Spacer()
                            Button("Done") {
                                showingSettings = false
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.horizontal, 4)
                    }
                    .padding(2)
                }
            }
            .padding(14)
        }
        .frame(width: 660, height: 700)
    }

    @ViewBuilder
    private func settingsCard<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            content()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.86))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08))
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.10), radius: 8, x: 0, y: 4)
    }

    private func iconName(for level: SetupCheckLevel) -> String {
        switch level {
        case .ok:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }

    private func iconColor(for level: SetupCheckLevel) -> Color {
        switch level {
        case .ok:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    private func currency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 4
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.4f", value)
    }

    private func relativeTime(_ date: Date?) -> String {
        guard let date else { return "never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
