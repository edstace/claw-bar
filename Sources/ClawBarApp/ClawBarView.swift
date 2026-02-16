import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClawBarView: View {
    @ObservedObject var model: ClawBarViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingSettings = false
    @State private var replacementKey = ""
    @State private var micPulse = false
    @State private var isNearBottom = true
    @State private var pendingUnread = false
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var isDropTargeted = false
    @State private var showingQuitConfirmation = false
    @State private var settingsTab: SettingsTab = .general
    @AppStorage("clawbar.didShowKeyNudge") private var didShowKeyNudge = false

    private let bottomAnchorId = "chat-bottom-anchor"

    var body: some View {
        VStack(spacing: 12) {
            topBar
            statusSection
            chatWindowSection
        }
        .padding(14)
        .frame(width: 395)
        .alert(model.alertTitle, isPresented: $model.showErrorAlert, actions: {}) {
            Text(model.alertMessage)
        }
        .sheet(isPresented: $showingSettings) {
            settingsSheet
        }
        .confirmationDialog(
            "Quit ClawBar?",
            isPresented: $showingQuitConfirmation,
            titleVisibility: .visible
        ) {
            Button("Quit ClawBar", role: .destructive) {
                model.quitApp()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will close ClawBar and stop live voice until you reopen it.")
        }
        .onAppear {
            if !model.hasSavedAPIKey && !didShowKeyNudge {
                didShowKeyNudge = true
                showingSettings = true
            }
            updateMicPulseAnimation()
        }
        .onChange(of: isListeningOrSpeaking) { _, _ in
            updateMicPulseAnimation()
        }
        .onChange(of: showingSettings) { _, isPresented in
            guard isPresented else { return }
            Task { await model.refreshSetupChecks() }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Text("ClawBar")
                .font(.headline)

            Spacer()

            Button {
                model.startNewChat()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("New chat")

            Button {
                replacementKey = ""
                showingSettings = true
            } label: {
                Image(systemName: model.hasSavedAPIKey ? "slider.horizontal.3" : "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("API key settings")
            .foregroundColor(model.hasSavedAPIKey ? .secondary : .orange)

            Button {
                showingQuitConfirmation = true
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Quit ClawBar")
            .foregroundStyle(.secondary)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.isRecording || model.isTranscribing || model.isSpeaking {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            if model.showReliabilityHUD {
                reliabilityHUD
            }
            if let version = model.availableUpdateVersion {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                    Text("Update available: v\(version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(model.isDownloadingUpdate ? "Downloading…" : "Install") {
                        model.installAvailableUpdate()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                    .disabled(model.isDownloadingUpdate)
                }
                .padding(.top, 2)
            }
            if let banner = model.setupBanner {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(banner)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(model.keychainStartupIssue == nil ? "Fix" : "Open Keychain") {
                        if model.keychainStartupIssue == nil {
                            replacementKey = ""
                            showingSettings = true
                        } else {
                            model.openKeychainAccess()
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chatWindowSection: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { scrollViewportHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, newHeight in
                                scrollViewportHeight = newHeight
                            }
                    }

                    ScrollView {
                        if model.chatEntries.isEmpty {
                            Text("Say something or type a message…")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                        } else {
                            LazyVStack(spacing: 11) {
                                ForEach(model.chatEntries) { message in
                                    bubbleRow(for: message)
                                }

                                if let state = model.assistantStateText {
                                    assistantStateRow(state)
                                }

                                Color.clear
                                    .frame(height: 1)
                                    .id(bottomAnchorId)
                                    .background(
                                        GeometryReader { g in
                                            Color.clear.preference(
                                                key: BottomSentinelPreferenceKey.self,
                                                value: g.frame(in: .named("chat-scroll")).maxY
                                            )
                                        }
                                    )
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                        }
                    }
                    .coordinateSpace(name: "chat-scroll")
                    .onPreferenceChange(BottomSentinelPreferenceKey.self) { maxY in
                        Task { @MainActor in
                            let nearBottomNow = maxY <= scrollViewportHeight + 36
                            isNearBottom = nearBottomNow
                            if nearBottomNow {
                                pendingUnread = false
                            }
                        }
                    }
                    .onChange(of: model.chatEntries.count) { _, _ in
                        if isNearBottom {
                            scrollToBottom(proxy, animated: true)
                        } else {
                            pendingUnread = true
                        }
                    }
                    .onAppear {
                        DispatchQueue.main.async {
                            scrollToBottom(proxy, animated: false)
                        }
                    }

                    if pendingUnread && !isNearBottom {
                        Button {
                            scrollToBottom(proxy, animated: true)
                            pendingUnread = false
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down")
                                Text("Jump to latest")
                            }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.black.opacity(colorScheme == .dark ? 0.55 : 0.35)))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .padding(.bottom, 8)
                    }
                }
            }
            .frame(minHeight: 220, maxHeight: 270)

            Divider()
                .overlay(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.15))

            if !model.pendingAttachments.isEmpty {
                attachmentTray
            }

            composerSection
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: chatGradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: chatBorderColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    )
                    .overlay(
                        VStack(spacing: 6) {
                            Image(systemName: "tray.and.arrow.down.fill")
                                .font(.system(size: 18, weight: .semibold))
                            Text("Drop files to attach")
                                .font(.callout.weight(.semibold))
                        }
                        .foregroundStyle(colorScheme == .dark ? Color.white : Color.black.opacity(0.85))
                    )
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: handleFileDrop(providers:))
        .shadow(color: .black.opacity(0.24), radius: 16, x: 0, y: 10)
    }

    private var composerSection: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack(alignment: .topLeading) {
                ChatComposerTextView(
                    text: $model.composerText,
                    isEditable: !model.isLiveVoiceEnabled,
                    onSend: model.sendComposerText,
                    onToggleLiveVoice: model.toggleLiveVoice
                )
                .frame(minHeight: 54, idealHeight: 74, maxHeight: 120)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(inputBackgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(inputBorderColor)
                )

                if model.composerText.isEmpty {
                    Text("Message OpenClaw…")
                        .font(.body)
                        .foregroundStyle(.secondary.opacity(0.8))
                        .padding(.top, 12)
                        .padding(.leading, 12)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            HStack(spacing: 6) {
                Button(action: openAttachmentPicker) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Attach files")
                .foregroundStyle(.secondary)
                .disabled(model.isLiveVoiceEnabled)

                Button(action: model.handleMicButtonTap) {
                    ZStack {
                        if isListeningOrSpeaking {
                            Circle()
                                .stroke((model.isRecording ? Color.red : Color.orange).opacity(0.5), lineWidth: 1.4)
                                .frame(width: 28, height: 28)
                                .scaleEffect(micPulse ? 1.35 : 1.0)
                                .opacity(micPulse ? 0.0 : 1.0)

                            Circle()
                                .stroke((model.isRecording ? Color.red : Color.orange).opacity(0.35), lineWidth: 1.2)
                                .frame(width: 28, height: 28)
                                .scaleEffect(micPulse ? 1.65 : 1.08)
                                .opacity(micPulse ? 0.0 : 0.7)
                        }

                        Image(systemName: model.isLiveVoiceEnabled ? "mic.fill" : "mic")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                }
                .buttonStyle(.plain)
                .help(micButtonHelpText)
                .foregroundStyle(model.isLiveVoiceEnabled ? .red : .secondary)
                .disabled(model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isTranscribing)
                .keyboardShortcut("l", modifiers: [.command])

                Button(action: model.sendComposerText) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(canSendText ? Color.accentColor : Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSendText ? Color.white : Color.secondary)
                .disabled(!canSendText)
                .help("Send (Enter)")
            }
            .padding(.trailing, 20)
            .padding(.bottom, 18)
        }
    }

    @ViewBuilder
    private func bubbleRow(for message: ChatEntry) -> some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                HStack {
                    Spacer(minLength: 36)
                    VStack(alignment: .leading, spacing: 6) {
                        if !message.text.isEmpty {
                            Text(message.text)
                                .font(.callout)
                                .foregroundStyle(.white)
                        }
                        if !message.attachments.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(message.attachments) { item in
                                    HStack(spacing: 6) {
                                        Image(systemName: iconName(for: item))
                                            .font(.system(size: 11, weight: .semibold))
                                        Text(item.fileName)
                                            .font(.caption)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                            .foregroundStyle(.white.opacity(0.95))
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.20, green: 0.46, blue: 0.95), Color(red: 0.18, green: 0.35, blue: 0.86)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 2)
                    .frame(maxWidth: 295, alignment: .trailing)
                }
                Text(Self.timeFormatter.string(from: message.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
            }

        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.7) : Color.black.opacity(0.45))
                        .padding(.top, 5)

                    Text(message.text)
                        .font(.callout)
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.95) : Color.black.opacity(0.88))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                HStack(spacing: 12) {
                    Button {
                        model.speakText(message.text)
                    } label: {
                        Label("Speak", systemImage: "speaker.wave.2")
                    }
                    .buttonStyle(.plain)

                    Button {
                        model.copyToClipboard(message.text)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.plain)

                    Button {
                        model.resendToOpenClaw(text: message.text)
                    } label: {
                        Label("Resend", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text(Self.timeFormatter.string(from: message.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
            }
        }
    }

    private var attachmentTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.pendingAttachments) { file in
                    HStack(spacing: 6) {
                        Image(systemName: iconName(for: file))
                            .font(.system(size: 11, weight: .semibold))
                        Text(file.fileName)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            model.removeAttachment(id: file.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(colorScheme == .dark ? 0.1 : 0.7)))
                    .overlay(Capsule().strokeBorder(Color.black.opacity(colorScheme == .dark ? 0 : 0.08)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func openAttachmentPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .image,
            .audio,
            .movie,
            .pdf,
            .text,
            .plainText,
            .json,
            .xml,
            .rtf,
            .data,
        ]
        if panel.runModal() == .OK {
            model.addAttachments(urls: panel.urls)
        }
    }

    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var resolvedURL: URL?
                if let data = item as? Data {
                    resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
                } else if let url = item as? URL {
                    resolvedURL = url
                } else if let str = item as? String {
                    resolvedURL = URL(string: str) ?? URL(fileURLWithPath: str)
                } else if let nsURL = item as? NSURL {
                    resolvedURL = nsURL as URL
                }

                if let resolvedURL, resolvedURL.isFileURL {
                    DispatchQueue.main.async {
                        model.addAttachments(urls: [resolvedURL])
                    }
                }
            }
        }
        return true
    }

    private func iconName(for item: AttachmentItem) -> String {
        let type = item.typeLabel.lowercased()
        if type.contains("image") { return "photo" }
        if type.contains("audio") { return "waveform" }
        if type.contains("video") || type.contains("movie") { return "video" }
        if type.contains("pdf") { return "doc.richtext" }
        if type.contains("text") { return "doc.text" }
        return "doc"
    }

    private func assistantStateRow(_ text: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var reliabilityHUD: some View {
        HStack(spacing: 10) {
            Label("STT \(model.lastTranscribeDurationMs.map { "\($0)ms" } ?? "n/a")", systemImage: "waveform")
            Label("Relay \(model.lastRelayDurationMs.map { "\($0)ms" } ?? "n/a")", systemImage: "network")
            Label("Retry \(model.lastRelayRetryCount)", systemImage: "arrow.clockwise")
            Spacer(minLength: 0)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(bottomAnchorId, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchorId, anchor: .bottom)
        }
    }

    private var canSendText: Bool {
        !model.isLiveVoiceEnabled &&
            (!model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.pendingAttachments.isEmpty) &&
            !model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !model.isTranscribing
    }

    private var isListeningOrSpeaking: Bool {
        model.isRecording || model.isSpeaking
    }

    private var statusDotColor: Color {
        if model.isRecording { return .red }
        if model.isTranscribing || model.isSpeaking { return .orange }
        if model.isLiveVoiceEnabled { return .green }
        return .secondary
    }

    private func updateMicPulseAnimation() {
        if isListeningOrSpeaking {
            micPulse = false
            withAnimation(.easeOut(duration: 1.05).repeatForever(autoreverses: false)) {
                micPulse = true
            }
        } else {
            micPulse = false
        }
    }

    private var chatGradientColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.14, green: 0.16, blue: 0.21),
                Color(red: 0.10, green: 0.11, blue: 0.14),
            ]
        }
        return [
            Color(red: 0.96, green: 0.97, blue: 0.99),
            Color(red: 0.91, green: 0.93, blue: 0.97),
        ]
    }

    private var chatBorderColors: [Color] {
        if colorScheme == .dark {
            return [
                Color.white.opacity(0.18),
                Color.white.opacity(0.05),
            ]
        }
        return [
            Color.black.opacity(0.12),
            Color.black.opacity(0.03),
        ]
    }

    private var inputBackgroundColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.86)
    }

    private var inputBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    private var settingsSheet: some View {
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

                                    Button("Check with Sparkle") {
                                        model.checkViaSparkle()
                                    }
                                    .buttonStyle(.bordered)

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

                                Text("Style Prompt")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                TextEditor(text: $model.voiceStylePrompt)
                                    .font(.callout)
                                    .frame(height: 84)
                                    .padding(6)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.18)))

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
                        }

                        HStack {
                            if settingsTab != .diagnostics {
                                Button("Recheck Setup") {
                                    settingsTab = .diagnostics
                                    Task { await model.refreshSetupChecks() }
                                }
                                .buttonStyle(.bordered)
                            }
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

    private var micButtonHelpText: String {
        if model.isLiveVoiceEnabled {
            return model.liveVoiceMode == .pushToTalk
                ? (model.isRecording ? "Stop and send turn" : "Record one turn")
                : "Disable live voice"
        }
        return "Enable live voice"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

private struct BottomSentinelPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .zero
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case voice
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return "General"
        case .voice:
            return "Voice"
        case .diagnostics:
            return "Diagnostics"
        }
    }

    var icon: String {
        switch self {
        case .general:
            return "gearshape.fill"
        case .voice:
            return "waveform.badge.mic"
        case .diagnostics:
            return "wrench.and.screwdriver.fill"
        }
    }
}

private struct ChatComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var onSend: () -> Void
    var onToggleLiveVoice: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = KeyAwareTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = NSColor.labelColor
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.onSend = onSend
        textView.onToggleLiveVoice = onToggleLiveVoice
        textView.string = text
        textView.isEditable = isEditable
        textView.isSelectable = true

        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? KeyAwareTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.onSend = onSend
        textView.onToggleLiveVoice = onToggleLiveVoice
        textView.isEditable = isEditable
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposerTextView

        init(_ parent: ChatComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

private final class KeyAwareTextView: NSTextView {
    var onSend: (() -> Void)?
    var onToggleLiveVoice: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturnKey = event.keyCode == 36 || event.keyCode == 76
        if isReturnKey {
            if event.modifierFlags.contains(.shift) {
                super.keyDown(with: event)
            } else {
                onSend?()
            }
            return
        }

        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "l" {
            onToggleLiveVoice?()
            return
        }

        super.keyDown(with: event)
    }
}
