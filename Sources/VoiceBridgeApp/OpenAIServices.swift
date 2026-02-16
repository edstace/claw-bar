import AVFoundation
import Foundation

/// Calls OpenAI Whisper (speech-to-text) via the REST API.
enum WhisperService {
    static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    static let minimumAudioDuration: TimeInterval = 0.12
    static let sensitivityDefaultsKey = "voicebridge.settings.sttSensitivity"

    /// Transcribe a local audio file to text using Whisper.
    static func transcribe(fileURL: URL, apiKey: String, model: String = "whisper-1") async throws -> String {
        let gate = currentGate()
        let signal = try audioSignalStats(fileURL: fileURL, activeSampleThreshold: gate.activeSampleThreshold)
        let duration = signal.duration
        guard duration >= minimumAudioDuration else {
            throw VoiceBridgeError.audioTooShort(duration: duration, minimumRequired: minimumAudioDuration)
        }
        guard signal.rms >= gate.minimumRMSForSpeech || signal.peak >= gate.minimumPeakForSpeech else {
            throw VoiceBridgeError.noSpeechDetected
        }
        guard signal.activeRatio >= gate.minimumActiveSpeechRatio else {
            throw VoiceBridgeError.noSpeechDetected
        }

        let boundary = "VoiceBridge-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 35

        let audioData = try Data(contentsOf: fileURL)

        var body = Data()
        // model field
        body.appendMultipart(boundary: boundary, name: "model", value: model)
        // constrain language to reduce hallucinations from low-information noise
        body.appendMultipart(boundary: boundary, name: "language", value: "en")
        // deterministic decoding for short clips
        body.appendMultipart(boundary: boundary, name: "temperature", value: "0")
        // response_format
        body.appendMultipart(boundary: boundary, name: "response_format", value: "text")
        // file field
        body.appendMultipart(boundary: boundary, name: "file", filename: fileURL.lastPathComponent,
                             mimeType: "audio/wav", fileData: audioData)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw VoiceBridgeError.networkError("Transcription timed out. Check API key/network and try again.")
        } catch {
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            throw VoiceBridgeError.networkError("No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "unknown"
            throw VoiceBridgeError.apiError(statusCode: http.statusCode, detail: detail)
        }

        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw VoiceBridgeError.emptyTranscription
        }
        if isLikelyInstructionLeak(text) {
            throw VoiceBridgeError.noSpeechDetected
        }
        return text
    }

    static func setSpeechSensitivity(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        UserDefaults.standard.set(clamped, forKey: sensitivityDefaultsKey)
    }

    static func speechSensitivity() -> Double {
        let value = UserDefaults.standard.double(forKey: sensitivityDefaultsKey)
        if UserDefaults.standard.object(forKey: sensitivityDefaultsKey) == nil {
            return 0.5
        }
        return min(max(value, 0), 1)
    }

    private static func currentGate() -> SpeechGate {
        let sensitivity = speechSensitivity()
        // Lower thresholds when sensitivity increases.
        let minimumRMSForSpeech = max(0.003, 0.010 - (0.006 * sensitivity))
        let minimumPeakForSpeech = max(0.022, 0.050 - (0.022 * sensitivity))
        let minimumActiveSpeechRatio = max(0.008, 0.030 - (0.020 * sensitivity))
        let activeSampleThreshold = max(0.012, 0.030 - (0.012 * sensitivity))
        return SpeechGate(
            minimumRMSForSpeech: minimumRMSForSpeech,
            minimumPeakForSpeech: minimumPeakForSpeech,
            minimumActiveSpeechRatio: minimumActiveSpeechRatio,
            activeSampleThreshold: activeSampleThreshold
        )
    }

    private static func isLikelyInstructionLeak(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized.contains("if there is no clear speech") ||
            normalized.contains("return an empty transcription") ||
            normalized.contains("transcribe only clear spoken")
    }

    private static func audioSignalStats(fileURL: URL, activeSampleThreshold: Double) throws -> (duration: TimeInterval, rms: Double, peak: Double, activeRatio: Double) {
        let file = try AVAudioFile(forReading: fileURL)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return (0, 0, 0, 0) }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            return (Double(file.length) / sampleRate, 0, 0, 0)
        }
        try file.read(into: buffer)

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            return (Double(file.length) / sampleRate, 0, 0, 0)
        }

        var sumSquares = 0.0
        var peak = 0.0
        var activeSamples = 0

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            if let channels = buffer.floatChannelData {
                let channelCount = Int(buffer.format.channelCount)
                for c in 0..<channelCount {
                    let data = channels[c]
                    for i in 0..<frameCount {
                        let v = Double(data[i])
                        let a = abs(v)
                        sumSquares += v * v
                        if a > peak { peak = a }
                        if a >= activeSampleThreshold { activeSamples += 1 }
                    }
                }
                let n = Double(frameCount * channelCount)
                let rms = n > 0 ? sqrt(sumSquares / n) : 0
                let activeRatio = n > 0 ? Double(activeSamples) / n : 0
                return (Double(file.length) / sampleRate, rms, peak, activeRatio)
            }

        case .pcmFormatInt16:
            if let channels = buffer.int16ChannelData {
                let channelCount = Int(buffer.format.channelCount)
                for c in 0..<channelCount {
                    let data = channels[c]
                    for i in 0..<frameCount {
                        let v = Double(data[i]) / Double(Int16.max)
                        let a = abs(v)
                        sumSquares += v * v
                        if a > peak { peak = a }
                        if a >= activeSampleThreshold { activeSamples += 1 }
                    }
                }
                let n = Double(frameCount * channelCount)
                let rms = n > 0 ? sqrt(sumSquares / n) : 0
                let activeRatio = n > 0 ? Double(activeSamples) / n : 0
                return (Double(file.length) / sampleRate, rms, peak, activeRatio)
            }

        default:
            break
        }

        return (Double(file.length) / sampleRate, 0, 0, 0)
    }
}

private struct SpeechGate {
    let minimumRMSForSpeech: Double
    let minimumPeakForSpeech: Double
    let minimumActiveSpeechRatio: Double
    let activeSampleThreshold: Double
}

// MARK: - TTS

/// Calls OpenAI TTS (text-to-speech) via the REST API.
enum TTSService {
    static let endpoint = URL(string: "https://api.openai.com/v1/audio/speech")!

    /// Synthesize speech from text and return the audio data (mp3).
    static func synthesize(
        text: String,
        apiKey: String,
        model: String = "tts-1",
        voice: String = "nova"
    ) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let payload: [String: Any] = [
            "model": model,
            "input": text,
            "voice": voice,
            "response_format": "mp3",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw VoiceBridgeError.networkError("No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "unknown"
            throw VoiceBridgeError.apiError(statusCode: http.statusCode, detail: detail)
        }
        guard !data.isEmpty else {
            throw VoiceBridgeError.emptyAudio
        }
        return data
    }
}

// MARK: - Realtime TTS

/// Uses OpenAI Realtime API over WebSocket for low-latency audio output.
enum RealtimeTTSService {
    static func synthesize(
        text: String,
        apiKey: String,
        voice: String,
        instructions: String?
    ) async throws -> Data {
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime-mini") else {
            throw VoiceBridgeError.networkError("Invalid Realtime URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let ws = URLSession.shared.webSocketTask(with: request)
        ws.resume()
        defer { ws.cancel(with: .goingAway, reason: nil) }

        try await sendJSON([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "output_modalities": ["audio"],
                "output_audio_format": "pcm16",
                "voice": voice,
                "instructions": instructions ?? "",
            ],
        ], on: ws)

        try await sendJSON([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": text,
                    ],
                ],
            ],
        ], on: ws)

        try await sendJSON([
            "type": "response.create",
            "response": [
                "modalities": ["audio"],
                "output_audio_format": "pcm16",
            ],
        ], on: ws)

        var audioPCM = Data()
        var completed = false

        while !completed {
            let message = try await ws.receive()
            let payload: [String: Any]
            switch message {
            case .string(let text):
                guard let data = text.data(using: .utf8),
                      let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                payload = obj
            case .data(let data):
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                payload = obj
            @unknown default:
                continue
            }

            guard let type = payload["type"] as? String else { continue }
            switch type {
            case "response.output_audio.delta":
                if let delta = payload["delta"] as? String,
                   let chunk = Data(base64Encoded: delta) {
                    audioPCM.append(chunk)
                }
            case "response.done":
                completed = true
            case "error":
                let detail = ((payload["error"] as? [String: Any])?["message"] as? String) ?? "Realtime error"
                throw VoiceBridgeError.networkError(detail)
            default:
                break
            }
        }

        guard !audioPCM.isEmpty else {
            throw VoiceBridgeError.emptyAudio
        }
        return makeWAVFromPCM16(pcmData: audioPCM, sampleRate: 24_000, channels: 1)
    }

    private static func sendJSON(_ object: [String: Any], on ws: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw VoiceBridgeError.networkError("Failed to encode Realtime event")
        }
        try await ws.send(.string(text))
    }

    private static func makeWAVFromPCM16(pcmData: Data, sampleRate: Int, channels: Int) -> Data {
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = pcmData.count
        let riffSize = 36 + dataSize

        var wav = Data()
        wav.append("RIFF".data(using: .ascii)!)
        wav.append(UInt32(riffSize).littleEndianData)
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        wav.append(UInt32(16).littleEndianData) // PCM chunk size
        wav.append(UInt16(1).littleEndianData) // Audio format PCM
        wav.append(UInt16(channels).littleEndianData)
        wav.append(UInt32(sampleRate).littleEndianData)
        wav.append(UInt32(byteRate).littleEndianData)
        wav.append(UInt16(blockAlign).littleEndianData)
        wav.append(UInt16(bitsPerSample).littleEndianData)
        wav.append("data".data(using: .ascii)!)
        wav.append(UInt32(dataSize).littleEndianData)
        wav.append(pcmData)
        return wav
    }
}

// MARK: - Helpers

enum VoiceBridgeError: LocalizedError {
    case networkError(String)
    case apiError(statusCode: Int, detail: String)
    case audioTooShort(duration: TimeInterval, minimumRequired: TimeInterval)
    case noSpeechDetected
    case emptyTranscription
    case emptyAudio
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .networkError(let msg): return "Network error: \(msg)"
        case .apiError(let code, let detail): return "API error \(code): \(detail)"
        case .audioTooShort(let duration, let minimumRequired):
            return String(format: "Recording too short (%.2fs). Please record at least %.2fs.", duration, minimumRequired)
        case .noSpeechDetected:
            return "No clear speech detected. Try speaking closer to the mic."
        case .emptyTranscription: return "Whisper returned empty transcription"
        case .emptyAudio: return "TTS returned empty audio"
        case .microphonePermissionDenied: return "Microphone access denied"
        }
    }
}

extension Data {
    mutating func appendMultipart(boundary: String, name: String, value: String) {
        let field = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        append(field.data(using: .utf8)!)
    }

    mutating func appendMultipart(boundary: String, name: String, filename: String, mimeType: String, fileData: Data) {
        var header = "--\(boundary)\r\n"
        header += "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
        header += "Content-Type: \(mimeType)\r\n\r\n"
        append(header.data(using: .utf8)!)
        append(fileData)
        append("\r\n".data(using: .utf8)!)
    }
}

private extension FixedWidthInteger {
    var littleEndianData: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<Self>.size)
    }
}
