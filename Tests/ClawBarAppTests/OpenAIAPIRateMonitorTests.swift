import XCTest
@testable import ClawBarApp

final class OpenAIAPIRateMonitorTests: XCTestCase {
    func testTTSCostEstimatorUsesModelSpecificDefaults() {
        let chars = 1_000
        let tts1 = OpenAICostEstimator.ttsEstimate(characters: chars, model: "tts-1")
        let ttsHD = OpenAICostEstimator.ttsEstimate(characters: chars, model: "tts-1-hd")
        let mini = OpenAICostEstimator.ttsEstimate(characters: chars, model: "gpt-4o-mini-tts")

        XCTAssertEqual(tts1, 0.015, accuracy: 0.000_001)
        XCTAssertEqual(ttsHD, 0.03, accuracy: 0.000_001)
        XCTAssertGreaterThan(mini, 0)
    }

    func testSnapshotComputesRateWindowsAndCostBuckets() async {
        let monitor = OpenAIAPIRateMonitor()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let headers: [String: String] = [
            "x-ratelimit-limit-requests": "500",
            "x-ratelimit-remaining-requests": "497",
        ]

        await monitor.record(
            statusCode: 200,
            headers: headers,
            endpoint: "audio/transcriptions",
            estimatedCostUSD: 0.01,
            at: now.addingTimeInterval(-20)
        )
        await monitor.record(
            statusCode: 200,
            headers: headers,
            endpoint: "audio/speech",
            estimatedCostUSD: 0.02,
            at: now.addingTimeInterval(-120)
        )
        await monitor.record(
            statusCode: 429,
            headers: headers,
            endpoint: "audio/speech",
            estimatedCostUSD: 0.03,
            at: now.addingTimeInterval(-10)
        )

        let snapshot = await monitor.snapshot(now: now)
        XCTAssertEqual(snapshot.requestsLast60Seconds, 2)
        XCTAssertEqual(snapshot.requestsLast60Minutes, 3)
        XCTAssertEqual(snapshot.lastStatusCode, 429)
        XCTAssertEqual(snapshot.lastEndpoint, "audio/speech")
        XCTAssertNotNil(snapshot.last429At)
        XCTAssertEqual(snapshot.requestLimit, "500")
        XCTAssertEqual(snapshot.requestRemaining, "497")
        XCTAssertEqual(snapshot.estimatedCostLastRequestUSD, 0)
        XCTAssertEqual(snapshot.estimatedCostTodayUSD, 0.03, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.estimatedCostWeekUSD, 0.03, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.estimatedCostMonthUSD, 0.03, accuracy: 0.000_001)
    }

    func testNonSuccessStatusDoesNotAddEstimatedCost() async {
        let monitor = OpenAIAPIRateMonitor()
        let now = Date()
        await monitor.record(
            statusCode: 500,
            headers: [:],
            endpoint: "audio/transcriptions",
            estimatedCostUSD: 0.25,
            at: now
        )

        let snapshot = await monitor.snapshot(now: now)
        XCTAssertEqual(snapshot.estimatedCostTodayUSD, 0, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.estimatedCostLastRequestUSD ?? -1, 0, accuracy: 0.000_001)
    }
}
