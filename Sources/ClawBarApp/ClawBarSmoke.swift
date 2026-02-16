import Foundation

enum ClawBarSmoke {
    static func run() -> Int32 {
        guard Bundle.main.bundleIdentifier == "com.openclaw.clawbar" else {
            fputs("smoke: unexpected bundle identifier\n", stderr)
            return 1
        }

        UserDefaults.standard.set("ok", forKey: "clawbar.smoke.settingsPath")
        guard UserDefaults.standard.string(forKey: "clawbar.smoke.settingsPath") == "ok" else {
            fputs("smoke: failed settings roundtrip\n", stderr)
            return 1
        }
        return 0
    }
}
