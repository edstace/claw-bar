import AppKit
import AVFoundation
import Combine
import CryptoKit
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
    @Published var voiceStyle: String = ""
    @Published var voiceAccent: String = ""
    @Published var voiceTone: String = ""
    @Published var voiceIntonation: String = ""
    @Published var voicePace: String = ""
    @Published var voiceCustomInstructions: String = ""
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
    @Published var availableUpdateChecksumURL: URL?
    @Published var updateReleaseNotes: String = ""
    @Published var updateCheckErrorMessage: String?
    @Published var skippedUpdateVersion: String?
    @Published var isDownloadingUpdate: Bool = false
    @Published var lastUpdateCheckAt: Date?

    // MARK: - Private

    let audioCapture = AudioCaptureManager()
    var audioPlayer: AVAudioPlayer?
    var autoSaveTask: Task<Void, Never>?
    var liveAutoStopTask: Task<Void, Never>?
    var lastSavedAPIKey: String = ""
    let liveTurnMaxSeconds: Duration = .seconds(6)
    let voiceProfile = VoiceCallProfile.load()
    let voiceSettingKey = "clawbar.settings.voice"
    let voiceStyleSettingsKey = "clawbar.settings.voiceStyleSettings.v2"
    let legacyStylePromptSettingKey = "clawbar.settings.stylePrompt"
    let sttPresetSettingKey = "clawbar.settings.sttPreset"
    let liveVoiceModeSettingKey = "clawbar.settings.liveVoiceMode"
    let showReliabilityHUDSettingKey = "clawbar.settings.showReliabilityHUD"
    let updateLastCheckedAtKey = "clawbar.updates.lastCheckedAt"
    let updateSkippedVersionKey = "clawbar.updates.skippedVersion"
    let updateRemindAfterKey = "clawbar.updates.remindAfter"
    let sessionStore = SessionStore()
    var lifecyclePauseDepth: Int = 0
    var shouldResumeLiveVoiceAfterLifecyclePause: Bool = false

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
        skippedUpdateVersion = UserDefaults.standard.string(forKey: updateSkippedVersionKey)
        launchAtLoginEnabled = LaunchAgentManager.isEnabled()
        restoreSession()
        Task { [weak self] in
            await self?.checkForUpdatesIfDue()
            await self?.refreshSetupChecks()
        }
    }
}

struct VoiceCallProfile {
    let voice: String
    let styleSettings: VoiceStyleSettings

    static func load() -> VoiceCallProfile {
        let defaultProfile = VoiceCallProfile(
            voice: "cedar",
            styleSettings: VoiceStyleSettings()
        )
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

        let stylePrompt = (config["responseSystemPrompt"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = VoiceStyleSettings(
            style: "",
            accent: "",
            tone: "",
            intonation: "",
            pace: "",
            customInstructions: stylePrompt ?? ""
        )
        return VoiceCallProfile(voice: voice, styleSettings: settings)
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

struct VoiceStyleSettings: Codable {
    var style: String
    var accent: String
    var tone: String
    var intonation: String
    var pace: String
    var customInstructions: String

    init(
        style: String = "",
        accent: String = "",
        tone: String = "",
        intonation: String = "",
        pace: String = "",
        customInstructions: String = ""
    ) {
        self.style = style
        self.accent = accent
        self.tone = tone
        self.intonation = intonation
        self.pace = pace
        self.customInstructions = customInstructions
    }

    func composedPrompt() -> String {
        var lines: [String] = []

        if !style.isEmpty {
            lines.append("Voice style: \(style)")
        }
        if !accent.isEmpty {
            lines.append("Accent: \(accent)")
        }
        if !tone.isEmpty {
            lines.append("Tone: \(tone)")
        }
        if !intonation.isEmpty {
            lines.append("Intonation: \(intonation)")
        }
        if !pace.isEmpty {
            lines.append("Pace: \(pace)")
        }
        if !customInstructions.isEmpty {
            lines.append(customInstructions)
        }

        return lines.joined(separator: "\n")
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

struct PersistedSession: Codable {
    let transcript: String
    let latestTranscript: String
    let entries: [PersistedChatEntry]
}

struct PersistedChatEntry: Codable {
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

struct PersistedAttachment: Codable {
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

struct SessionStore {
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
