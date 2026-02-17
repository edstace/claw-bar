import XCTest
@testable import ClawBarApp

final class OpenClawRelayTests: XCTestCase {
    func testCandidateExecutablePathsPrioritizeOverrideAndPath() {
        let env: [String: String] = [
            "OPENCLAW_CLI_PATH": "/custom/openclaw",
            "PATH": "/tmp/bin:/usr/local/bin",
        ]
        let candidates = OpenClawRelay.candidateExecutablePaths(environment: env, home: "/Users/test")

        XCTAssertEqual(candidates.first, "/custom/openclaw")
        XCTAssertTrue(candidates.contains("/tmp/bin/openclaw"))
        XCTAssertTrue(candidates.contains("/Users/test/.n/bin/openclaw"))
    }

    func testExtractJSONObjectDataReturnsObjectWhenPrefixedLogsExist() {
        let prefixed = "[plugins] ready\n{\"result\":{\"payloads\":[{\"text\":\"hello\"}]}}\n"
        let extracted = OpenClawRelay.extractJSONObjectData(from: Data(prefixed.utf8))

        XCTAssertNotNil(extracted)
    }

    func testExtractJSONObjectDataIgnoresNonJSONBracesAndFindsValidObject() {
        let noisy = "log{not json}\n{\"result\":{\"payloads\":[{\"text\":\"ok\"}]}}\ntrailer {oops}"
        let extracted = OpenClawRelay.extractJSONObjectData(from: Data(noisy.utf8))
        XCTAssertNotNil(extracted)

        let decoded = try? JSONDecoder().decode(OpenClawAgentResult.self, from: extracted!)
        XCTAssertEqual(decoded?.firstNonEmptyText, "ok")
    }

    func testIsRetryableRelayErrorMatchesTransientErrors() {
        XCTAssertTrue(OpenClawRelay.isRetryableRelayError(message: "OpenClaw CLI timed out after 18s"))
        XCTAssertFalse(OpenClawRelay.isRetryableRelayError(message: "OpenClaw returned non-JSON output."))
    }
}
