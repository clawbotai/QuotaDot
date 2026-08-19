import Foundation
import Observation
import Security

protocol GLMCredentialStoring: Sendable {
    func loadAPIKey() throws -> String?
    func saveAPIKey(_ apiKey: String) throws
    func deleteAPIKey() throws
}

enum GLMCredentialError: Error, Sendable, Equatable {
    case keychain(OSStatus)
    case invalidEncoding
}

struct KeychainGLMCredentialStore: GLMCredentialStoring {
    static let service = "com.cmsjcm.QuotaDot.glm-api-key"
    static let account = "default"

    func loadAPIKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw GLMCredentialError.keychain(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw GLMCredentialError.invalidEncoding
        }
        return value
    }

    func saveAPIKey(_ apiKey: String) throws {
        let data = Data(apiKey.utf8)
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ] as CFDictionary
        )
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw GLMCredentialError.keychain(status) }

        var item = baseQuery
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw GLMCredentialError.keychain(addStatus) }
    }

    func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GLMCredentialError.keychain(status)
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

@MainActor @Observable
final class GLMCredentialManager {
    private(set) var hasStoredAPIKey: Bool
    private let store: any GLMCredentialStoring

    init(store: any GLMCredentialStoring = KeychainGLMCredentialStore()) {
        self.store = store
        hasStoredAPIKey = (try? store.loadAPIKey()) != nil
    }

    func loadAPIKey() throws -> String? {
        let value = try store.loadAPIKey()
        hasStoredAPIKey = value != nil
        return value
    }

    func saveAPIKey(_ apiKey: String) throws {
        try store.saveAPIKey(apiKey)
        hasStoredAPIKey = true
    }

    func deleteAPIKey() throws {
        try store.deleteAPIKey()
        hasStoredAPIKey = false
    }
}
