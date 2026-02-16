import AVFoundation
import Foundation

/// Captures microphone audio to a temporary WAV file using AVFoundation.
final class AudioCaptureManager: @unchecked Sendable {
    private var audioEngine: AVAudioEngine?
    private var outputFile: AVAudioFile?
    private(set) var recordingURL: URL?

    var isRecording: Bool { audioEngine?.isRunning ?? false }

    /// Request microphone permission (macOS 14+).
    static func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    /// Start recording from the default input device.
    func startRecording() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Whisper wants 16-kHz mono, but we record at native rate
        // and let the API handle resampling (it accepts up to 25 MB files).
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("clawbar-\(UUID().uuidString).wav")

        let file = try AVAudioFile(
            forWriting: url,
            settings: recordingFormat.settings
        )

        // Smaller buffers reduce short-clip truncation at start/stop boundaries.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            do {
                try file.write(from: buffer)
            } catch {
                NSLog("ClawBar failed to write audio buffer: \(error.localizedDescription)")
            }
        }

        engine.prepare()
        try engine.start()

        self.audioEngine = engine
        self.outputFile = file
        self.recordingURL = url
    }

    /// Stop recording and return the file URL.
    @discardableResult
    func stopRecording() -> URL? {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        outputFile = nil
        return recordingURL
    }

    /// Clean up temporary recording file.
    func cleanup() {
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }
    }
}
