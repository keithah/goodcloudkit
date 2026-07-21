import Foundation
import Security

/// Persists a single Credentials record as a generic-password item,
/// scoped by `service`. account is the item account; refreshToken is the secret.
public struct KeychainCredentialStore: CredentialStore {
    public enum KeychainError: Error, Equatable {
        case status(OSStatus)
        /// The item was found (`errSecSuccess`) but its data/attributes couldn't be decoded — a
        /// distinct case so callers don't see a misleading "status 0 (success)" on a real failure.
        case decodeFailed
    }

    private let service: String
    public init(service: String = "xyz.goodcloud.GoodCloudKit") {
        self.service = service
    }

    public func save(_ credentials: Credentials) throws {
        try delete()
        var query = baseQuery(account: credentials.account)
        query[kSecValueData as String] = Data(credentials.refreshToken.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func load() throws -> Credentials? {
        var query = baseQuery(account: nil)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let dict = item as? [String: Any],
              let data = dict[kSecValueData as String] as? Data,
              let account = dict[kSecAttrAccount as String] as? String,
              let token = String(data: data, encoding: .utf8)
        else { throw KeychainError.decodeFailed }
        return Credentials(account: account, refreshToken: token)
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery(account: nil) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    private func baseQuery(account: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }
}
