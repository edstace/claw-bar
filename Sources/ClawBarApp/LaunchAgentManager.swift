import Foundation
import Darwin

enum LaunchAgentManager {
    static let label = "com.openclaw.clawbar"

    static func launchAgentPath() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func isEnabled() -> Bool {
        let uid = String(getuid())
        let result = runLaunchctl(["print", "gui/\(uid)/\(label)"])
        return result.exitCode == 0
    }

    static func enable() throws {
        let plistURL = launchAgentPath()
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: launchAgentPlist(), format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)

        let uid = String(getuid())
        _ = runLaunchctl(["bootout", "gui/\(uid)", plistURL.path])
        let bootstrap = runLaunchctl(["bootstrap", "gui/\(uid)", plistURL.path])
        guard bootstrap.exitCode == 0 else {
            throw ClawBarError.networkError("Failed to enable launch at login: \(bootstrap.stderrText)")
        }
        _ = runLaunchctl(["enable", "gui/\(uid)/\(label)"])
    }

    static func disable() throws {
        let plistURL = launchAgentPath()
        let uid = String(getuid())
        _ = runLaunchctl(["disable", "gui/\(uid)/\(label)"])
        _ = runLaunchctl(["bootout", "gui/\(uid)", plistURL.path])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private static func launchAgentPlist() -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [programPath()],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "WorkingDirectory": NSHomeDirectory(),
            "StandardOutPath": "\(NSHomeDirectory())/Library/Logs/ClawBar.log",
            "StandardErrorPath": "\(NSHomeDirectory())/Library/Logs/ClawBar.log",
        ]
    }

    private static func programPath() -> String {
        let main = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/ClawBarApp")
            .path
        if FileManager.default.isExecutableFile(atPath: main) {
            return main
        }
        return "/Applications/ClawBar.app/Contents/MacOS/ClawBarApp"
    }

    private static func runLaunchctl(_ args: [String]) -> (exitCode: Int32, stdoutText: String, stderrText: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, "", error.localizedDescription)
        }

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines), err.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
