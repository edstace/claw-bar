import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClawBarView: View {
    @ObservedObject var model: ClawBarViewModel
    @Environment(\.colorScheme) var colorScheme
    @State var showingSettings = false
    @State var replacementKey = ""
    @State var micPulse = false
    @State var isNearBottom = true
    @State var pendingUnread = false
    @State var scrollViewportHeight: CGFloat = 0
    @State var isDropTargeted = false
    @State var showingQuitConfirmation = false
    @State var settingsTab: SettingsTab = .general
    @AppStorage("clawbar.didShowKeyNudge") var didShowKeyNudge = false

    let bottomAnchorId = "chat-bottom-anchor"

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

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

struct BottomSentinelPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .zero
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case connection
    case voice
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return "General"
        case .connection:
            return "Connection"
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
        case .connection:
            return "network"
        case .voice:
            return "waveform.badge.mic"
        case .diagnostics:
            return "wrench.and.screwdriver.fill"
        }
    }
}

struct ChatComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var colorScheme: ColorScheme
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
        applyAppearance(to: textView)
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
        applyAppearance(to: textView)
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

    private func applyAppearance(to textView: KeyAwareTextView) {
        let isDark = colorScheme == .dark
        let textColor = isDark ? NSColor.white : NSColor.black
        textView.textColor = textColor
        textView.insertionPointColor = isDark ? NSColor.white : NSColor.black
        textView.typingAttributes[.foregroundColor] = textColor
        textView.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
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
