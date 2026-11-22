import Foundation
import Security

enum KeychainService {
    private static let service = "com.swiftpili.app"

    /// Session cookies must survive brief lock/background without requiring an
    /// interactive unlock, but must not leave the device (no iCloud keychain
    /// backup of auth tokens). O3: AfterFirstUnlockThisDeviceOnly.
    /// `CFString` is not `Sendable`; the Security constant is immutable process-wide.
    nonisolated(unsafe) private static let accessibility =
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    @discardableResult
    static func set(key: String, value: String) -> OSStatus {
        guard let data = value.data(using: .utf8) else { return errSecParam }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        // Best-effort delete of any prior item (ignore not-found).
        let deleteStatus = SecItemDelete(query as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            #if DEBUG
            print("[Keychain] delete before set key=\(key) status=\(deleteStatus)")
            #endif
        }

        var newItem = query
        newItem[kSecValueData as String] = data
        newItem[kSecAttrAccessible as String] = accessibility
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        if addStatus != errSecSuccess {
            #if DEBUG
            print("[Keychain] set key=\(key) status=\(addStatus)")
            #endif
        }
        return addStatus
    }

    static func get(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                #if DEBUG
                print("[Keychain] get key=\(key) status=\(status)")
                #endif
            }
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(key: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            #if DEBUG
            print("[Keychain] delete key=\(key) status=\(status)")
            #endif
        }
        return status
    }
}
