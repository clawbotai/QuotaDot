import Foundation
import Security

@MainActor protocol AntigravityCredentialStoring {
    func load() throws -> AntigravityCredential?
    func save(_ credential: AntigravityCredential) throws
    func delete() throws
}

enum AntigravityCredentialError: Error, Sendable, Equatable {
    case keychain(OSStatus)
    case invalidEncoding
}

struct KeychainAntigravityCredentialStore: AntigravityCredentialStoring {
    static let service = "com.cmsjcm.QuotaDot.antigravity-oauth"
    static let account = "default"

    func load() throws -> AntigravityCredential? {
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AntigravityCredentialError.keychain(status) }
        guard let data = item as? Data else {
            throw AntigravityCredentialError.invalidEncoding
        }
        return try JSONDecoder().decode(AntigravityCredential.self, from: data)
    }

    func save(_ credential: AntigravityCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ] as CFDictionary
        )
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw AntigravityCredentialError.keychain(status) }

        var item = baseQuery
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw AntigravityCredentialError.keychain(addStatus) }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AntigravityCredentialError.keychain(status)
        }
    }

    private var baseQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account
        ]
    }
}

