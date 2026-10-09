import Foundation
import Security

public enum KeychainError: LocalizedError {
    case status(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .status(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Keychain error \(status): \(message)"
        }
    }
}

public enum Keychain {
    private static let service = "ch.rallymail.mail"
    /// Service name used before the app was renamed; items are copied over on first read.
    private static let legacyService = "ch.mylbox.mail"

    public static func set(_ value: String, for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    public static func get(_ key: String) -> String? {
        if let value = get(key, service: service) { return value }
        guard let legacy = get(key, service: legacyService) else { return nil }
        try? set(legacy, for: key)
        return legacy
    }

    private static func get(_ key: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(_ key: String) {
        for service in [service, legacyService] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    public static func passwordKey(_ account: UUID) -> String { "\(account.uuidString).password" }
    public static func refreshTokenKey(_ account: UUID) -> String { "\(account.uuidString).refresh" }
}
