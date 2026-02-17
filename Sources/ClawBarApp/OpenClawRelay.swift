import Foundation

public struct OpenClawDiagnostics: Sendable {
    let cliPath: String?
    let nodePath: String?
    let relayReachable: Bool
    let detail: String?
}

public struct OpenClawRelayResult: Sendable {
    let text: String
    let retryCount: Int
    let durationMs: Int
}

/// Relays transcribed text to a running OpenClaw instance via its local API.
@MainActor
public enum OpenClawRelay {
    private static let relayAgentId = "main"
    private static var relaySessionId = "clawbar-relay-v1"
    private static var cachedExecutablePath: String?

    /// Send a text message to OpenClaw and return the first text reply.
    /// Prefer the CLI bridge because OpenClaw's gateway is not a simple REST endpoint.
    static func send(text: String, attachments: [AttachmentItem]) async throws -> OpenClawRelayResult {
        try await sendViaCLI(text: text, attachments: attachments)
    }

    static func rotateSession() {
        relaySessionId = "clawbar-relay-\(UUID().uuidString)"
    }

    private static func sendViaCLI(text: String, attachments: [AttachmentItem]) async throws -> OpenClawRelayResult {
        let relayText = buildRelayText(text: text, attachments: attachments)
        let start = Date()
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                let data = try await runOpenClawCommand(arguments: [
                    "agent",
                    "--agent", relayAgentId,
                    "--session-id", relaySessionId,
                    "--message", relayText,
                    "--json",
                ])
                let decoded = try decodeAgentResult(from: data)
                let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
                if let text = decoded.firstNonEmptyText {
                    return OpenClawRelayResult(text: text, retryCount: attempt, durationMs: elapsedMs)
                }
                return OpenClawRelayResult(text: "", retryCount: attempt, durationMs: elapsedMs)
            } catch {
                lastError = error
                if attempt == 0, isRetryableRelayError(message: error.localizedDescription) {
                    continue
                }
                throw error
            }
        }
        throw lastError ?? ClawBarError.networkError("OpenClaw relay failed with unknown error.")
    }

    private static func buildRelayText(text: String, attachments: [AttachmentItem]) -> String {
        guard !attachments.isEmpty else { return text }
        var lines: [String] = []
        lines.append(text)
        lines.append("")
        lines.append("Attached files:")
        for file in attachments {
            lines.append("- \(file.fileName) [\(file.typeLabel)] path: \(file.path)")
        }
        lines.append("")
        lines.append("Analyze these attachments and respond to the user request.")
        return lines.joined(separator: "\n")
    }

    private static func runOpenClawCommand(arguments: [String], timeoutSeconds: TimeInterval = 18) async throws -> Data {
        let executablePath = try resolveOpenClawExecutablePath()
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.environment = buildProcessEnvironment(executablePath: executablePath)

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            let state = ProcessContinuationState()

            process.terminationHandler = { proc in
                state.lock.lock()
                defer { state.lock.unlock() }
                guard !state.resumed else { return }
                state.resumed = true
                let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                if state.timedOut {
                    continuation.resume(throwing: ClawBarError.networkError("OpenClaw CLI timed out after \(Int(timeoutSeconds))s"))
                } else if proc.terminationStatus == 0 {
                    continuation.resume(returning: outputData)
                } else {
                    let detail = String(data: errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
                    continuation.resume(throwing: ClawBarError.networkError("OpenClaw CLI failed: \(detail)"))
                }
            }

            do {
                try process.run()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                    state.lock.lock()
                    defer { state.lock.unlock() }
                    guard !state.resumed, process.isRunning else { return }
                    state.timedOut = true
                    process.terminate()
                }
            } catch {
                state.lock.lock()
                defer { state.lock.unlock() }
                guard !state.resumed else { return }
                state.resumed = true
                continuation.resume(throwing: ClawBarError.networkError("Failed to launch OpenClaw CLI at \(executablePath): \(error.localizedDescription)"))
            }
        }
    }

    static func buildProcessEnvironment(executablePath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        let home = NSHomeDirectory()

        var pathEntries: [String] = []
        if let existing = env["PATH"], !existing.isEmpty {
            pathEntries.append(contentsOf: existing.split(separator: ":").map(String.init))
        }

        // Ensure node/openclaw shims are reachable when app is launched without shell init.
        pathEntries.insert(contentsOf: [
            "\(home)/.n/bin",
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ], at: 0)

        // Include the executable's directory as a final guarantee.
        pathEntries.insert((executablePath as NSString).deletingLastPathComponent, at: 0)

        var seen = Set<String>()
        let normalized = pathEntries.filter { entry in
            guard !entry.isEmpty else { return false }
            guard seen.insert(entry).inserted else { return false }
            return fm.fileExists(atPath: entry)
        }

        env["PATH"] = normalized.joined(separator: ":")
        env["HOME"] = env["HOME"] ?? home
        return env
    }

    public nonisolated static func candidateExecutablePaths(environment: [String: String], home: String) -> [String] {
        var candidates: [String] = []

        if let envOverride = environment["OPENCLAW_CLI_PATH"], !envOverride.isEmpty {
            candidates.append(envOverride)
        }
        if let path = environment["PATH"], !path.isEmpty {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/openclaw" })
        }
        candidates.append(contentsOf: [
            "\(home)/.n/bin/openclaw",
            "\(home)/.local/bin/openclaw",
            "\(home)/.npm-global/bin/openclaw",
            "\(home)/.yarn/bin/openclaw",
            "\(home)/Library/pnpm/openclaw",
            "\(home)/bin/openclaw",
            "/opt/homebrew/bin/openclaw",
            "/opt/homebrew/sbin/openclaw",
            "/usr/local/bin/openclaw",
            "/usr/local/sbin/openclaw",
            "/usr/bin/openclaw",
            "/bin/openclaw",
        ])
        return candidates
    }

    private static func resolveOpenClawExecutablePath() throws -> String {
        let fm = FileManager.default
        if let cachedExecutablePath, fm.isExecutableFile(atPath: cachedExecutablePath) {
            return cachedExecutablePath
        }

        let home = NSHomeDirectory()
        let candidates = candidateExecutablePaths(environment: ProcessInfo.processInfo.environment, home: home)

        for candidate in candidates {
            if fm.isExecutableFile(atPath: candidate) {
                cachedExecutablePath = candidate
                return candidate
            }
        }

        if let shellPath = resolveOpenClawFromLoginShell(), fm.isExecutableFile(atPath: shellPath) {
            cachedExecutablePath = shellPath
            return shellPath
        }

        throw ClawBarError.networkError(
            """
            OpenClaw CLI not found.
            Install with `brew install openclaw`, or set OPENCLAW_CLI_PATH to the full executable path.
            Checked common paths and login shell resolution (`zsh -lc 'command -v openclaw'`).
            """
        )
    }

    private static func resolveOpenClawFromLoginShell() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v openclaw 2>/dev/null || true"]
        process.environment = ProcessInfo.processInfo.environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !output.isEmpty else { return nil }
            return output
        } catch {
            return nil
        }
    }

    public nonisolated static func decodeAgentResult(from data: Data) throws -> OpenClawAgentResult {
        if let decoded = try? JSONDecoder().decode(OpenClawAgentResult.self, from: data) {
            return decoded
        }

        // Some installations may print log lines before JSON.
        guard let jsonData = extractJSONObjectData(from: data) else {
            throw ClawBarError.networkError("OpenClaw returned non-JSON output.")
        }
        return try JSONDecoder().decode(OpenClawAgentResult.self, from: jsonData)
    }

    public nonisolated static func extractJSONObjectData(from data: Data) -> Data? {
        guard let raw = String(data: data, encoding: .utf8) else {
            return nil
        }

        var cursor = raw.startIndex
        while cursor < raw.endIndex {
            guard raw[cursor] == "{" else {
                cursor = raw.index(after: cursor)
                continue
            }

            if let end = matchingBraceEnd(in: raw, from: cursor) {
                let jsonSlice = raw[cursor...end]
                if let jsonData = jsonSlice.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: jsonData),
                   object is [String: Any] {
                    return jsonData
                }
            }
            cursor = raw.index(after: cursor)
        }
        return nil
    }

    private nonisolated static func matchingBraceEnd(in text: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var isEscaped = false

        var index = start
        while index < text.endIndex {
            let ch = text[index]

            if inString {
                if isEscaped {
                    isEscaped = false
                } else if ch == "\\" {
                    isEscaped = true
                } else if ch == "\"" {
                    inString = false
                }
                index = text.index(after: index)
                continue
            }

            if ch == "\"" {
                inString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return index
                }
                if depth < 0 {
                    return nil
                }
            }

            index = text.index(after: index)
        }

        return nil
    }

    /// Quick health check — is OpenClaw gateway reachable? (best-effort)
    static func ping() async -> Bool {
        do {
            _ = try await runOpenClawCommand(arguments: ["status", "--json"])
            return true
        } catch {
            return false
        }
    }

    static func diagnostics() async -> OpenClawDiagnostics {
        do {
            let cliPath = try resolveOpenClawExecutablePath()
            let env = buildProcessEnvironment(executablePath: cliPath)
            let nodePath = findBinary(named: "node", inPATH: env["PATH"])
            let reachable = await ping()
            return OpenClawDiagnostics(
                cliPath: cliPath,
                nodePath: nodePath,
                relayReachable: reachable,
                detail: reachable ? nil : "OpenClaw status check failed."
            )
        } catch {
            return OpenClawDiagnostics(
                cliPath: nil,
                nodePath: nil,
                relayReachable: false,
                detail: error.localizedDescription
            )
        }
    }

    private static func findBinary(named: String, inPATH path: String?) -> String? {
        guard let path else { return nil }
        let fm = FileManager.default
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(named)"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    public nonisolated static func isRetryableRelayError(message: String) -> Bool {
        let value = message.lowercased()
        return value.contains("timed out") ||
            value.contains("temporar") ||
            value.contains("resource temporarily unavailable") ||
            value.contains("connection reset") ||
            value.contains("network error")
    }
}

private final class ProcessContinuationState: @unchecked Sendable {
    let lock = NSLock()
    var resumed = false
    var timedOut = false
}

public struct OpenClawAgentResult: Decodable {
    let result: ResultPayload?

    public var firstNonEmptyText: String? {
        result?.payloads?
            .compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    public struct ResultPayload: Decodable {
        let payloads: [Payload]?
    }

    public struct Payload: Decodable {
        let text: String?
    }
}
