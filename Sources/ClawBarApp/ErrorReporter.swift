import Foundation
import Sentry

@MainActor
enum ErrorReporter {
    private static var configured = false

    static func configureIfPossible() {
        guard !configured else { return }

        let bundleValue = Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String
        let envValue = ProcessInfo.processInfo.environment["SENTRY_DSN"]
        let dsn = (bundleValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? bundleValue : envValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let dsn, !dsn.isEmpty else { return }

        SentrySDK.start { options in
            options.dsn = dsn
            options.enableAppHangTracking = true
            options.debug = false
        }
        configured = true
    }

    static func capture(message: String) {
        guard configured else { return }
        SentrySDK.capture(message: message)
    }

    static func capture(error: Error) {
        guard configured else { return }
        SentrySDK.capture(error: error)
    }
}
