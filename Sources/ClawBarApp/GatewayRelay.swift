import Foundation

/// Connects directly to an OpenClaw Gateway WebSocket for chat.send / chat events.
/// Replaces the CLI subprocess relay when a remote gateway URL is configured.
///
/// Protocol (v3):
///   1. Connect WS → receive connect.challenge event
///   2. Send type:"req" method:"connect" with auth token, client info, protocol version
///   3. Receive type:"res" hello-ok
///   4. Send type:"req" method:"chat.send" with agentId + message
///   5. Listen for type:"event" event:"chat" until done
@MainActor
public enum GatewayRelay {
    // MARK: - Configuration

    private static let gatewayURLKey = "clawbar.gateway.url"
    private static let gatewayTokenKey = "clawbar.gateway.token"
    private static let gatewayAgentKey = "clawbar.gateway.agent"
    private static let gatewaySessionKey = "clawbar.gateway.sessionKey"
    private static let gatewayEnabledKey = "clawbar.gateway.enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: gatewayEnabledKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: gatewayEnabledKey)
    }

    static var gatewayURL: String {
        get { UserDefaults.standard.string(forKey: gatewayURLKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: gatewayURLKey) }
    }

    static var gatewayToken: String {
        get { UserDefaults.standard.string(forKey: gatewayTokenKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: gatewayTokenKey) }
    }

    static var agentId: String {
        get {
            let val = UserDefaults.standard.string(forKey: gatewayAgentKey) ?? "main"
            return val.isEmpty ? "main" : val
        }
        set { UserDefaults.standard.set(newValue, forKey: gatewayAgentKey) }
    }

    static var sessionKey: String {
        get {
            let val = UserDefaults.standard.string(forKey: gatewaySessionKey) ?? "clawbar-ws-v1"
            return val.isEmpty ? "clawbar-ws-v1" : val
        }
        set { UserDefaults.standard.set(newValue, forKey: gatewaySessionKey) }
    }

    static func rotateSession() {
        sessionKey = "clawbar-ws-\(UUID().uuidString)"
    }

    // MARK: - Protocol Constants

    private static let protocolVersion = 3
    private static let clientId = "openclaw-control-ui"
    private static let clientMode = "webchat"
    private static let clientVersion = "0.1.0"

    // MARK: - Send

    /// Send a message to the gateway via WebSocket and wait for the full response.
    static func send(text: String, attachments: [AttachmentItem]) async throws -> OpenClawRelayResult {
        let urlString = gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else {
            throw ClawBarError.networkError("Gateway URL is not configured. Open Settings → Connection.")
        }

        guard let url = URL(string: urlString) else {
            throw ClawBarError.networkError("Invalid gateway URL: \(urlString)")
        }

        let start = Date()
        let token = gatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let agent = agentId
        let session = sessionKey

        // Build the message with attachments
        let messageText = buildMessageText(text: text, attachments: attachments)

        // Connect — set Origin header to match gateway host for control UI auth
        var request = URLRequest(url: url)
        if let scheme = url.scheme, let host = url.host {
            let port = url.port.map { ":\($0)" } ?? ""
            let httpScheme = scheme == "wss" ? "https" : "http"
            request.setValue("\(httpScheme)://\(host)\(port)", forHTTPHeaderField: "Origin")
        }
        let ws = URLSession.shared.webSocketTask(with: request)
        ws.resume()

        defer { ws.cancel(with: .goingAway, reason: nil) }

        // Step 1: Wait for connect.challenge event
        let challengeMsg = try await receiveJSON(on: ws, timeout: 10)
        guard let challengeType = challengeMsg["type"] as? String,
              challengeType == "event",
              let challengeEvent = challengeMsg["event"] as? String,
              challengeEvent == "connect.challenge" else {
            // Some gateways may not send a challenge — proceed anyway
            // But if we got something else unexpected, log it
            let desc = String(describing: challengeMsg)
            throw ClawBarError.networkError("Expected connect.challenge, got: \(desc.prefix(200))")
        }

        // Step 2: Send connect request
        let connectId = UUID().uuidString
        let connectPayload: [String: Any] = [
            "type": "req",
            "id": connectId,
            "method": "connect",
            "params": [
                "minProtocol": protocolVersion,
                "maxProtocol": protocolVersion,
                "client": [
                    "id": clientId,
                    "version": clientVersion,
                    "platform": "macos",
                    "mode": clientMode,
                ] as [String: Any],
                "role": "operator",
                "scopes": ["operator.read", "operator.write"],
                "caps": [] as [String],
                "commands": [] as [String],
                "permissions": [:] as [String: Any],
                "auth": token.isEmpty ? [:] as [String: Any] : ["token": token] as [String: Any],
                "locale": "en-US",
                "userAgent": "clawbar/\(clientVersion)",
            ] as [String: Any],
        ]
        try await sendJSON(connectPayload, on: ws)

        // Step 3: Wait for connect response (hello-ok)
        let connectResponse = try await receiveJSON(on: ws, timeout: 10)
        if let ok = connectResponse["ok"] as? Bool, !ok {
            let errorMsg = (connectResponse["error"] as? [String: Any])?["message"] as? String ?? "Unknown auth error"
            throw ClawBarError.networkError("Gateway auth failed: \(errorMsg)")
        }

        // Step 4: Send chat.send
        let chatSendId = UUID().uuidString
        let chatSendPayload: [String: Any] = [
            "type": "req",
            "id": chatSendId,
            "method": "chat.send",
            "params": [
                "sessionKey": "agent:\(agent):\(session)",
                "message": messageText,
                "idempotencyKey": chatSendId,
            ] as [String: Any],
        ]
        try await sendJSON(chatSendPayload, on: ws)

        // Step 5: Wait for chat.send ack to get the runId
        var runId: String?
        let ackDeadline = Date().addingTimeInterval(15)
        while runId == nil && Date() < ackDeadline {
            guard let msg = try await receiveJSONOptional(on: ws, timeout: 5) else { continue }
            let msgType = msg["type"] as? String ?? ""
            if msgType == "res", let id = msg["id"] as? String, id == chatSendId {
                if let ok = msg["ok"] as? Bool, !ok {
                    let errMsg = (msg["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
                    throw ClawBarError.networkError("chat.send failed: \(errMsg)")
                }
                runId = (msg["payload"] as? [String: Any])?["runId"] as? String
                break
            }
        }

        guard let activeRunId = runId else {
            throw ClawBarError.networkError("No runId received from chat.send")
        }

        // Step 6: Collect response — listen for chat/agent events matching our runId
        // Event format:
        //   chat events: {type:"event", event:"chat", payload:{runId, state:"delta"|"final", message:{content:[{type:"text",text:"..."}]}}}
        //   agent lifecycle: {type:"event", event:"agent", payload:{runId, stream:"lifecycle", data:{phase:"end"}}}
        //   agent assistant: {type:"event", event:"agent", payload:{runId, stream:"assistant", data:{text:"...",delta:"..."}}}
        var responseText = ""
        var completed = false
        let timeout: TimeInterval = 120
        let deadline = Date().addingTimeInterval(timeout)

        while !completed && Date() < deadline {
            guard let msg = try await receiveJSONOptional(on: ws, timeout: 5) else {
                continue
            }

            let msgType = msg["type"] as? String ?? ""

            // Handle events
            if msgType == "event" {
                let event = msg["event"] as? String ?? ""
                let payload = msg["payload"] as? [String: Any] ?? [:]

                // Only process events for our runId
                let eventRunId = payload["runId"] as? String ?? ""
                guard eventRunId == activeRunId else { continue }

                // Chat events — the authoritative source for response text
                if event == "chat" {
                    let state = payload["state"] as? String ?? ""

                    // Extract text from message.content array
                    if let message = payload["message"] as? [String: Any],
                       let content = message["content"] as? [[String: Any]] {
                        for item in content {
                            if let itemType = item["type"] as? String, itemType == "text",
                               let text = item["text"] as? String {
                                responseText = text
                            }
                        }
                    }

                    if state == "final" {
                        completed = true
                    }
                }

                // Agent lifecycle events — backup completion signal
                if event == "agent" {
                    let stream = payload["stream"] as? String ?? ""

                    if stream == "lifecycle",
                       let data = payload["data"] as? [String: Any],
                       let phase = data["phase"] as? String,
                       phase == "end" {
                        completed = true
                    }

                    // Agent assistant stream — backup text source
                    if stream == "assistant",
                       let data = payload["data"] as? [String: Any],
                       let text = data["text"] as? String, !text.isEmpty {
                        responseText = text
                    }
                }
            }
        }

        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)

        if !completed && responseText.isEmpty {
            throw ClawBarError.networkError("Gateway relay timed out after \(Int(timeout))s")
        }

        return OpenClawRelayResult(
            text: responseText.trimmingCharacters(in: .whitespacesAndNewlines),
            retryCount: 0,
            durationMs: elapsedMs
        )
    }

    // MARK: - Ping

    static func ping() async -> Bool {
        let urlString = gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return false }

        let token = gatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            var request = URLRequest(url: url)
            if let scheme = url.scheme, let host = url.host {
                let port = url.port.map { ":\($0)" } ?? ""
                let httpScheme = scheme == "wss" ? "https" : "http"
                request.setValue("\(httpScheme)://\(host)\(port)", forHTTPHeaderField: "Origin")
            }
            let ws = URLSession.shared.webSocketTask(with: request)
            ws.resume()
            defer { ws.cancel(with: .goingAway, reason: nil) }

            // Wait for connect.challenge
            let challenge = try await receiveJSON(on: ws, timeout: 5)
            guard (challenge["event"] as? String) == "connect.challenge" else { return false }

            // Send connect
            let connectId = UUID().uuidString
            let connectPayload: [String: Any] = [
                "type": "req",
                "id": connectId,
                "method": "connect",
                "params": [
                    "minProtocol": protocolVersion,
                    "maxProtocol": protocolVersion,
                    "client": [
                        "id": clientId,
                        "version": clientVersion,
                        "platform": "macos",
                        "mode": clientMode,
                    ] as [String: Any],
                    "role": "operator",
                    "scopes": ["operator.read", "operator.write"],
                    "caps": [] as [String],
                    "commands": [] as [String],
                    "permissions": [:] as [String: Any],
                    "auth": token.isEmpty ? [:] as [String: Any] : ["token": token] as [String: Any],
                    "locale": "en-US",
                    "userAgent": "clawbar/\(clientVersion)",
                ] as [String: Any],
            ]
            try await sendJSON(connectPayload, on: ws)

            // Wait for response
            let response = try await receiveJSON(on: ws, timeout: 5)
            if let ok = response["ok"] as? Bool, ok {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    // MARK: - Diagnostics

    static func diagnostics() async -> GatewayRelayDiagnostics {
        let urlString = gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasURL = !urlString.isEmpty
        let hasToken = !gatewayToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let reachable = hasURL ? await ping() : false

        return GatewayRelayDiagnostics(
            url: hasURL ? urlString : nil,
            hasToken: hasToken,
            reachable: reachable,
            detail: !hasURL ? "No gateway URL configured." : (!reachable ? "Gateway unreachable at \(urlString)" : nil)
        )
    }

    // MARK: - Helpers

    private static func buildMessageText(text: String, attachments: [AttachmentItem]) -> String {
        guard !attachments.isEmpty else { return text }
        var lines: [String] = [text, "", "Attached files:"]
        for file in attachments {
            lines.append("- \(file.fileName) [\(file.typeLabel)] path: \(file.path)")
        }
        lines.append("")
        lines.append("Analyze these attachments and respond to the user request.")
        return lines.joined(separator: "\n")
    }

    private static func sendJSON(_ object: [String: Any], on ws: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ClawBarError.networkError("Failed to encode WebSocket message")
        }
        try await ws.send(.string(text))
    }

    private static func receiveJSON(on ws: URLSessionWebSocketTask, timeout: TimeInterval) async throws -> [String: Any] {
        let receiveTask = Task<Data, Error> {
            let message = try await ws.receive()
            switch message {
            case .string(let text):
                guard let data = text.data(using: .utf8) else {
                    throw ClawBarError.networkError("Invalid text from gateway")
                }
                return data
            case .data(let data):
                return data
            @unknown default:
                throw ClawBarError.networkError("Unknown WebSocket message type")
            }
        }

        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(timeout))
            receiveTask.cancel()
        }

        do {
            let data = try await receiveTask.value
            timeoutTask.cancel()
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ClawBarError.networkError("Invalid JSON from gateway")
            }
            return obj
        } catch {
            timeoutTask.cancel()
            if Task.isCancelled {
                throw ClawBarError.networkError("Gateway response timed out")
            }
            throw error
        }
    }

    private static func receiveJSONOptional(on ws: URLSessionWebSocketTask, timeout: TimeInterval) async throws -> [String: Any]? {
        do {
            return try await receiveJSON(on: ws, timeout: timeout)
        } catch {
            let msg = error.localizedDescription.lowercased()
            if msg.contains("timed out") || msg.contains("cancelled") {
                return nil
            }
            throw error
        }
    }
}

public struct GatewayRelayDiagnostics: Sendable {
    let url: String?
    let hasToken: Bool
    let reachable: Bool
    let detail: String?
}
