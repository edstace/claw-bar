import Foundation

/// Connects directly to an OpenClaw Gateway WebSocket for chat.send / chat events.
/// Replaces the CLI subprocess relay when a remote gateway URL is configured.
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

    // MARK: - Send

    /// Send a message to the gateway via WebSocket and wait for the full response.
    /// Protocol:
    ///   1. Connect to ws(s)://host:port with auth params
    ///   2. Send JSON-RPC `chat.send` with message + session
    ///   3. Listen for `chat` events until we get the complete response
    ///   4. Return the assistant text
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

        // Connect
        let ws = URLSession.shared.webSocketTask(with: url)
        ws.resume()

        defer { ws.cancel(with: .goingAway, reason: nil) }

        // Authenticate via connect message
        let connectPayload: [String: Any] = [
            "method": "connect",
            "id": UUID().uuidString,
            "params": buildConnectParams(token: token),
        ]
        try await sendJSON(connectPayload, on: ws)

        // Wait for connect ack
        let connectResponse = try await receiveJSON(on: ws, timeout: 10)
        if let error = connectResponse["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw ClawBarError.networkError("Gateway auth failed: \(message)")
        }

        // Send chat.send
        let chatSendId = UUID().uuidString
        let chatSendPayload: [String: Any] = [
            "method": "chat.send",
            "id": chatSendId,
            "params": [
                "agentId": agent,
                "sessionKey": session,
                "message": messageText,
            ] as [String: Any],
        ]
        try await sendJSON(chatSendPayload, on: ws)

        // Collect response — listen for chat events until response.done or timeout
        var responseText = ""
        var completed = false
        let timeout: TimeInterval = 120

        let deadline = Date().addingTimeInterval(timeout)

        while !completed && Date() < deadline {
            guard let msg = try await receiveJSONOptional(on: ws, timeout: 5) else {
                continue
            }

            // Handle RPC response to chat.send
            if let id = msg["id"] as? String, id == chatSendId {
                if let error = msg["error"] as? [String: Any],
                   let errMsg = error["message"] as? String {
                    throw ClawBarError.networkError("chat.send failed: \(errMsg)")
                }
                // ack received, continue listening for chat events
                continue
            }

            // Handle chat events (streamed response)
            if let method = msg["method"] as? String, method == "chat" {
                if let params = msg["params"] as? [String: Any] {
                    if let text = params["text"] as? String {
                        responseText = text
                    }
                    if let delta = params["delta"] as? String {
                        responseText += delta
                    }
                    if let done = params["done"] as? Bool, done {
                        completed = true
                    }
                    if let status = params["status"] as? String,
                       status == "complete" || status == "done" || status == "finished" {
                        completed = true
                    }
                }
            }

            // Handle agent events
            if let method = msg["method"] as? String, method == "agent" {
                if let params = msg["params"] as? [String: Any] {
                    if let status = params["status"] as? String,
                       status == "complete" || status == "done" || status == "finished" {
                        completed = true
                    }
                    // Extract text from agent completion
                    if let result = params["result"] as? [String: Any],
                       let payloads = result["payloads"] as? [[String: Any]] {
                        for payload in payloads {
                            if let text = payload["text"] as? String, !text.isEmpty {
                                responseText = text
                            }
                        }
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
            let ws = URLSession.shared.webSocketTask(with: url)
            ws.resume()
            defer { ws.cancel(with: .goingAway, reason: nil) }

            let connectPayload: [String: Any] = [
                "method": "connect",
                "id": UUID().uuidString,
                "params": buildConnectParams(token: token),
            ]
            try await sendJSON(connectPayload, on: ws)

            let response = try await receiveJSON(on: ws, timeout: 5)
            if response["error"] != nil { return false }

            // Send health check
            let healthPayload: [String: Any] = [
                "method": "health",
                "id": UUID().uuidString,
                "params": [:] as [String: Any],
            ]
            try await sendJSON(healthPayload, on: ws)
            let healthResponse = try await receiveJSON(on: ws, timeout: 5)
            return healthResponse["error"] == nil
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

    private static func buildConnectParams(token: String) -> [String: Any] {
        var params: [String: Any] = [:]
        var auth: [String: Any] = [:]
        if !token.isEmpty {
            auth["token"] = token
        }
        if !auth.isEmpty {
            params["auth"] = auth
        }
        return params
    }

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
        // Receive with a simple timeout via Task.sleep race
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
