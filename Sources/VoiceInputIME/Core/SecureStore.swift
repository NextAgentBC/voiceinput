import Foundation
import Security
import os.log

private let secureLog = Logger(subsystem: "com.voiceinput.app", category: "SecureStore")

enum SecureStore {
    private static let service = "com.voiceinput.app"

    static func get(_ account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            if status != errSecItemNotFound {
                secureLog.error("SecItemCopyMatching failed for \(account, privacy: .public): \(status, privacy: .public)")
            }
            return nil
        }
        return value
    }

    static func set(_ account: String, _ value: String?) {
        guard let value = value, !value.isEmpty else {
            delete(account)
            return
        }
        guard let data = value.data(using: .utf8) else { return }

        // Try update first; if not found, insert.
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertQuery = query
            insertQuery[kSecValueData] = data
            status = SecItemAdd(insertQuery as CFDictionary, nil)
        }
        if status != errSecSuccess {
            secureLog.error("SecureStore set failed for \(account, privacy: .public): \(status, privacy: .public)")
        }
    }

    static func delete(_ account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            secureLog.error("SecureStore delete failed for \(account, privacy: .public): \(status, privacy: .public)")
        }
    }
}
