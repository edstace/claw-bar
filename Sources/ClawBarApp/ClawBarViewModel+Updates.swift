import AppKit
import CryptoKit
import Foundation

extension ClawBarViewModel {
    // MARK: - Updates

    var currentVersionDisplay: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    var hasUpdateReady: Bool {
        availableUpdateVersion != nil
    }

    func checkForUpdatesIfDue() async {
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: updateLastCheckedAtKey) as? Date {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < 60 * 60 * 24 {
                lastUpdateCheckAt = last
                return
            }
        }
        await checkForUpdates(userInitiated: false)
    }

    func checkForUpdates(userInitiated: Bool) async {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        updateCheckErrorMessage = nil
        defer {
            isCheckingForUpdates = false
        }

        let now = Date()
        UserDefaults.standard.set(now, forKey: updateLastCheckedAtKey)
        lastUpdateCheckAt = now

        let bundle = Bundle.main
        let currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        do {
            if let update = try await UpdateChecker.check(currentVersion: currentVersion) {
                if !userInitiated, shouldSuppressUpdate(version: update.version) {
                    availableUpdateVersion = nil
                    availableUpdateURL = nil
                    availableUpdateChecksumURL = nil
                    updateReleaseNotes = ""
                    return
                }
                availableUpdateVersion = update.version
                availableUpdateURL = update.downloadURL
                availableUpdateChecksumURL = update.checksumURL
                updateReleaseNotes = update.releaseNotes
                statusMessage = "Update available: v\(update.version)"
            } else {
                availableUpdateVersion = nil
                availableUpdateURL = nil
                availableUpdateChecksumURL = nil
                updateReleaseNotes = ""
                updateCheckErrorMessage = nil
                if userInitiated {
                    statusMessage = "ClawBar is up to date"
                }
            }
        } catch {
            if userInitiated {
                updateCheckErrorMessage = "Update check failed: \(error.localizedDescription)"
                statusMessage = "Update check failed"
            } else {
                appendRecentError("Update check: \(error.localizedDescription)")
            }
        }
    }

    func openAvailableUpdate() {
        if let url = availableUpdateURL {
            NSWorkspace.shared.open(url)
            return
        }
        if let fallback = URL(string: "https://github.com/edstace/claw-bar/releases") {
            NSWorkspace.shared.open(fallback)
        }
    }

    func installAvailableUpdate() {
        guard !isDownloadingUpdate else { return }
        guard let url = availableUpdateURL else {
            openAvailableUpdate()
            return
        }
        guard let checksumURL = availableUpdateChecksumURL else {
            showError(title: "Update Install Failed", message: "Release checksum is missing. Open the release page and install manually.")
            statusMessage = "Update install failed"
            return
        }

        isDownloadingUpdate = true
        statusMessage = "Downloading update…"

        Task {
            defer {
                Task { @MainActor in
                    self.isDownloadingUpdate = false
                }
            }
            do {
                var dmgRequest = URLRequest(url: url)
                dmgRequest.setValue("application/x-apple-diskimage,application/octet-stream", forHTTPHeaderField: "Accept")
                let (data, dmgResponse) = try await URLSession.shared.data(for: dmgRequest)
                try UpdateChecker.validateBinaryDownloadResponse(dmgResponse, data: data, expectedKind: .dmg)

                var checksumRequest = URLRequest(url: checksumURL)
                checksumRequest.setValue("text/plain,application/octet-stream", forHTTPHeaderField: "Accept")
                let (checksumData, checksumResponse) = try await URLSession.shared.data(for: checksumRequest)
                try UpdateChecker.validateBinaryDownloadResponse(checksumResponse, data: checksumData, expectedKind: .checksum)
                let checksumText = String(data: checksumData, encoding: .utf8) ?? ""
                guard let expected = UpdateChecker.expectedSHA256(from: checksumText) else {
                    throw ClawBarError.networkError("Could not parse update checksum.")
                }
                let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard expected == actual else {
                    throw ClawBarError.networkError("Update checksum mismatch. Download was not opened.")
                }

                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("ClawBar-update-\(UUID().uuidString).dmg")
                try data.write(to: tempURL, options: .atomic)
                try UpdateChecker.validateDownloadedDMGAuthenticity(at: tempURL)
                await MainActor.run {
                    NSWorkspace.shared.open(tempURL)
                    statusMessage = "Update downloaded. Opened installer DMG."
                }
            } catch {
                await MainActor.run {
                    showError(title: "Update Install Failed", message: error.localizedDescription)
                    statusMessage = "Update install failed"
                }
            }
        }
    }

    func skipAvailableUpdate() {
        guard let version = availableUpdateVersion else { return }
        skippedUpdateVersion = version
        UserDefaults.standard.set(version, forKey: updateSkippedVersionKey)
        statusMessage = "Skipped update v\(version)"
    }

    func remindAboutUpdateTomorrow() {
        let remindAfter = Date().addingTimeInterval(60 * 60 * 24)
        UserDefaults.standard.set(remindAfter, forKey: updateRemindAfterKey)
        statusMessage = "Will remind about updates tomorrow"
        availableUpdateVersion = nil
        availableUpdateURL = nil
        availableUpdateChecksumURL = nil
        updateReleaseNotes = ""
    }

    private func shouldSuppressUpdate(version: String) -> Bool {
        if let skipped = skippedUpdateVersion, skipped == version {
            return true
        }
        if let remindAfter = UserDefaults.standard.object(forKey: updateRemindAfterKey) as? Date,
           remindAfter > Date() {
            return true
        }
        return false
    }
}
