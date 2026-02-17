import Foundation

struct OpenAIAPIRateSnapshot: Equatable {
    var requestsLast60Seconds: Int
    var requestsLast60Minutes: Int
    var lastStatusCode: Int?
    var lastErrorStatusCode: Int?
    var last429At: Date?
    var lastRequestAt: Date?
    var lastEndpoint: String?
    var requestLimit: String?
    var requestRemaining: String?
    var requestReset: String?
    var tokenLimit: String?
    var tokenRemaining: String?
    var tokenReset: String?
    var estimatedCostLastRequestUSD: Double?
    var estimatedCostTodayUSD: Double
    var estimatedCostWeekUSD: Double
    var estimatedCostMonthUSD: Double

    static let empty = OpenAIAPIRateSnapshot(
        requestsLast60Seconds: 0,
        requestsLast60Minutes: 0,
        lastStatusCode: nil,
        lastErrorStatusCode: nil,
        last429At: nil,
        lastRequestAt: nil,
        lastEndpoint: nil,
        requestLimit: nil,
        requestRemaining: nil,
        requestReset: nil,
        tokenLimit: nil,
        tokenRemaining: nil,
        tokenReset: nil,
        estimatedCostLastRequestUSD: nil,
        estimatedCostTodayUSD: 0,
        estimatedCostWeekUSD: 0,
        estimatedCostMonthUSD: 0
    )
}

actor OpenAIAPIRateMonitor {
    struct Event {
        let at: Date
        let statusCode: Int
        let endpoint: String
        let estimatedCostUSD: Double
    }

    private var events: [Event] = []
    private var lastHeaders: [String: String] = [:]

    func record(response: HTTPURLResponse, endpoint: String, estimatedCostUSD: Double = 0, at: Date = Date()) {
        let headers = normalize(headers: response.allHeaderFields)
        record(
            statusCode: response.statusCode,
            headers: headers,
            endpoint: endpoint,
            estimatedCostUSD: estimatedCostUSD,
            at: at
        )
    }

    func record(statusCode: Int, headers: [AnyHashable: Any], endpoint: String, estimatedCostUSD: Double = 0, at: Date = Date()) {
        let normalizedHeaders = normalize(headers: headers)
        record(statusCode: statusCode, headers: normalizedHeaders, endpoint: endpoint, estimatedCostUSD: estimatedCostUSD, at: at)
    }

    func record(statusCode: Int, headers: [String: String], endpoint: String, estimatedCostUSD: Double = 0, at: Date = Date()) {
        let billedEstimate = (200...299).contains(statusCode) ? max(0, estimatedCostUSD) : 0
        events.append(Event(at: at, statusCode: statusCode, endpoint: endpoint, estimatedCostUSD: billedEstimate))
        lastHeaders = headers
        prune(now: at)
    }

    func snapshot(now: Date = Date()) -> OpenAIAPIRateSnapshot {
        prune(now: now)
        let calendar = Calendar.current
        let lastMinuteCutoff = now.addingTimeInterval(-60)
        let lastHourCutoff = now.addingTimeInterval(-3600)
        let requestsLast60Seconds = events.filter { $0.at >= lastMinuteCutoff }.count
        let requestsLast60Minutes = events.filter { $0.at >= lastHourCutoff }.count
        let last = events.last
        let lastError = events.last(where: { $0.statusCode >= 400 })
        let last429 = events.last(where: { $0.statusCode == 429 })?.at
        let startOfDay = calendar.startOfDay(for: now)
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfDay
        let startOfMonth = calendar.dateInterval(of: .month, for: now)?.start ?? startOfDay
        let costToday = events.reduce(0.0) { partial, event in
            partial + (event.at >= startOfDay ? event.estimatedCostUSD : 0)
        }
        let costWeek = events.reduce(0.0) { partial, event in
            partial + (event.at >= startOfWeek ? event.estimatedCostUSD : 0)
        }
        let costMonth = events.reduce(0.0) { partial, event in
            partial + (event.at >= startOfMonth ? event.estimatedCostUSD : 0)
        }
        return OpenAIAPIRateSnapshot(
            requestsLast60Seconds: requestsLast60Seconds,
            requestsLast60Minutes: requestsLast60Minutes,
            lastStatusCode: last?.statusCode,
            lastErrorStatusCode: lastError?.statusCode,
            last429At: last429,
            lastRequestAt: last?.at,
            lastEndpoint: last?.endpoint,
            requestLimit: lastHeaders["x-ratelimit-limit-requests"],
            requestRemaining: lastHeaders["x-ratelimit-remaining-requests"],
            requestReset: lastHeaders["x-ratelimit-reset-requests"],
            tokenLimit: lastHeaders["x-ratelimit-limit-tokens"],
            tokenRemaining: lastHeaders["x-ratelimit-remaining-tokens"],
            tokenReset: lastHeaders["x-ratelimit-reset-tokens"],
            estimatedCostLastRequestUSD: last?.estimatedCostUSD,
            estimatedCostTodayUSD: costToday,
            estimatedCostWeekUSD: costWeek,
            estimatedCostMonthUSD: costMonth
        )
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-(60 * 60 * 24 * 45))
        if let firstValidIndex = events.firstIndex(where: { $0.at >= cutoff }) {
            if firstValidIndex > 0 {
                events.removeFirst(firstValidIndex)
            }
        } else {
            events.removeAll(keepingCapacity: true)
        }
    }

    private func normalize(headers: [AnyHashable: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in headers {
            let keyString = String(describing: key).lowercased()
            out[keyString] = String(describing: value)
        }
        return out
    }
}

enum OpenAICostEstimator {
    // Defaults align with OpenAI API pricing and can be overridden in UserDefaults.
    // Verified against https://platform.openai.com/pricing on 2026-02-17.
    private static let whisperUSDPerMinuteDefault = 0.006
    private static let ttsLegacyUSDPer1MCharsDefault = 15.0
    private static let ttsHDUSDPer1MCharsDefault = 30.0
    private static let ttsMiniUSDPerMinuteDefault = 0.015
    private static let ttsEstimatedCharsPerMinuteDefault = 780.0
    private static let whisperRateKey = "clawbar.cost.whisperUsdPerMinute"
    private static let ttsLegacyRateKey = "clawbar.cost.ttsLegacyUsdPer1MChars"
    private static let ttsHDRateKey = "clawbar.cost.ttsHDUsdPer1MChars"
    private static let ttsMiniRateKey = "clawbar.cost.ttsMiniUsdPerMinute"
    private static let ttsCharsPerMinuteKey = "clawbar.cost.ttsEstimatedCharsPerMinute"

    static func whisperEstimate(durationSeconds: TimeInterval) -> Double {
        let minutes = max(0, durationSeconds) / 60.0
        return minutes * whisperUSDPerMinute()
    }

    static func ttsEstimate(characters: Int, model: String) -> Double {
        let charCount = Double(max(0, characters))
        if model.hasPrefix("gpt-4o-mini-tts") {
            let minutes = charCount / ttsEstimatedCharsPerMinute()
            return minutes * ttsMiniUSDPerMinute()
        }
        if model.hasPrefix("tts-1-hd") {
            return (charCount / 1_000_000.0) * ttsHDUSDPer1MChars()
        }
        return (charCount / 1_000_000.0) * ttsLegacyUSDPer1MChars()
    }

    static func whisperUSDPerMinute() -> Double {
        userDefaultRate(for: whisperRateKey, fallback: whisperUSDPerMinuteDefault)
    }

    static func ttsLegacyUSDPer1MChars() -> Double {
        userDefaultRate(for: ttsLegacyRateKey, fallback: ttsLegacyUSDPer1MCharsDefault)
    }

    static func ttsHDUSDPer1MChars() -> Double {
        userDefaultRate(for: ttsHDRateKey, fallback: ttsHDUSDPer1MCharsDefault)
    }

    static func ttsMiniUSDPerMinute() -> Double {
        userDefaultRate(for: ttsMiniRateKey, fallback: ttsMiniUSDPerMinuteDefault)
    }

    static func ttsEstimatedCharsPerMinute() -> Double {
        userDefaultRate(for: ttsCharsPerMinuteKey, fallback: ttsEstimatedCharsPerMinuteDefault)
    }

    private static func userDefaultRate(for key: String, fallback: Double) -> Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return fallback }
        let value = defaults.double(forKey: key)
        return value > 0 ? value : fallback
    }
}
