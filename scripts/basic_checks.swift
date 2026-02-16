import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func candidateExecutablePaths(environment: [String: String], home: String) -> [String] {
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
        "/opt/homebrew/bin/openclaw",
        "/usr/local/bin/openclaw",
        "/usr/bin/openclaw",
    ])
    return candidates
}

func extractJSONObjectData(from data: Data) -> Data? {
    guard let raw = String(data: data, encoding: .utf8),
          let start = raw.firstIndex(of: "{"),
          let end = raw.lastIndex(of: "}"),
          start < end
    else {
        return nil
    }
    return raw[start...end].data(using: .utf8)
}

func isRetryableRelayError(_ message: String) -> Bool {
    let value = message.lowercased()
    return value.contains("timed out") ||
        value.contains("temporar") ||
        value.contains("resource temporarily unavailable") ||
        value.contains("connection reset") ||
        value.contains("network error")
}

enum SetupCheckLevel { case ok, warning, error }

func apiKeySetupLevel(_ apiKey: String) -> SetupCheckLevel {
    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.hasPrefix("sk-") && trimmed.count > 20 ? .ok : .warning
}

// Path resolution
let env: [String: String] = [
    "OPENCLAW_CLI_PATH": "/custom/openclaw",
    "PATH": "/tmp/bin:/usr/local/bin",
]
let candidates = candidateExecutablePaths(environment: env, home: "/Users/test")
expect(candidates.first == "/custom/openclaw", "override should be first candidate")
expect(candidates.contains("/tmp/bin/openclaw"), "PATH candidate missing")
expect(candidates.contains("/Users/test/.n/bin/openclaw"), "home candidate missing")

// JSON parsing regression
let prefixed = "[plugins] ready\\n{\"result\":{\"payloads\":[{\"text\":\"hello\"}]}}\\n"
let extracted = extractJSONObjectData(from: prefixed.data(using: .utf8)!)
expect(extracted != nil, "should extract JSON object from prefixed output")

// Retry classifier
expect(isRetryableRelayError("Network error: OpenClaw CLI timed out after 18s"), "timeout should be retryable")
expect(!isRetryableRelayError("OpenClaw returned non-JSON output."), "non-json should not be retryable")

// Diagnostics state classifier
expect(apiKeySetupLevel("sk-123456789012345678901234") == .ok, "valid key should be ok")
expect(apiKeySetupLevel("abc") == .warning, "invalid key should be warning")

print("basic_checks: PASS")
