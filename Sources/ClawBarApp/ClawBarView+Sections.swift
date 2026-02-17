import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension ClawBarView {
    var topBar: some View {
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

    var statusSection: some View {
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

    var chatWindowSection: some View {
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

    var isListeningOrSpeaking: Bool {
        model.isRecording || model.isSpeaking
    }

    private var statusDotColor: Color {
        if model.isRecording { return .red }
        if model.isTranscribing || model.isSpeaking { return .orange }
        if model.isLiveVoiceEnabled { return .green }
        return .secondary
    }

    func updateMicPulseAnimation() {
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

    private var micButtonHelpText: String {
        if model.isLiveVoiceEnabled {
            return model.liveVoiceMode == .pushToTalk
                ? (model.isRecording ? "Stop and send turn" : "Record one turn")
                : "Disable live voice"
        }
        return "Enable live voice"
    }
}
