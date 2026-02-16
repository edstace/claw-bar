import Foundation
import Security

/// Stores and retrieves the OpenAI API key in the macOS Keychain.
enum KeychainManager {
    private static let service = "com.openclaw.voicebridge"
    private static let account = "openai-api-key"

    static func save(apiKey: String) throws {
        guard let data = apiKey.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        // Delete any existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    static func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.unhandledError(status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    enum KeychainError: LocalizedError {
        case encodingFailed
        case unhandledError(status: OSStatus)

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "Failed to encode API key"
            case .unhandledError(let status):
                switch status {
                case errSecInteractionNotAllowed:
                    return "Keychain access was blocked. Approve ClawBar access in the keychain prompt or Keychain Access."
                case errSecAuthFailed:
                    return "Keychain authentication failed. Enter your login keychain password to grant access."
                case errSecUserCanceled:
                    return "Keychain access was canceled."
                default:
                    return "Keychain error: \(status)"
                }
            }
        }
    }
}
