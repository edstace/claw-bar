import AppKit
import Foundation

extension ClawBarViewModel {
    // MARK: - API Key

    func saveAPIKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showError(title: "API Key", message: "API key cannot be empty.")
            return
        }
        apiKey = trimmed
        do {
            try KeychainManager.save(apiKey: trimmed)
            lastSavedAPIKey = trimmed
            hasSavedAPIKey = true
            keychainStartupIssue = nil
            statusMessage = "API key saved to Keychain ✓"
        } catch {
            showError(title: "Keychain Error", message: error.localizedDescription)
        }
    }

    func scheduleAPIKeyAutosave() {
        autoSaveTask?.cancel()
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sk-"), trimmed.count > 20, trimmed != lastSavedAPIKey else {
            return
        }

        autoSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self else { return }

            let latest = self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard latest == trimmed else { return }
            do {
                try KeychainManager.save(apiKey: latest)
                lastSavedAPIKey = latest
                hasSavedAPIKey = true
                keychainStartupIssue = nil
                statusMessage = "API key auto-saved to Keychain ✓"
            } catch {
                statusMessage = "API key auto-save failed"
            }
        }
    }

    func replaceAPIKey(_ newKey: String) {
        let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sk-"), trimmed.count > 20 else {
            showError(title: "API Key", message: "Enter a valid OpenAI API key (starts with sk-).")
            return
        }
        apiKey = trimmed
        saveAPIKey()
    }

    func removeAPIKey() {
        do {
            try KeychainManager.delete()
            apiKey = ""
            lastSavedAPIKey = ""
            hasSavedAPIKey = false
            keychainStartupIssue = nil
            statusMessage = "API key removed from Keychain"
        } catch {
            showError(title: "Keychain Error", message: error.localizedDescription)
        }
    }

    func openKeychainAccess() {
        let keychainURL = URL(fileURLWithPath: "/System/Applications/Utilities/Keychain Access.app")
        NSWorkspace.shared.openApplication(at: keychainURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}
