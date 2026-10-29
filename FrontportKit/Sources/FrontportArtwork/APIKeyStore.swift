import Foundation
import FrontportCore
import Security

/// Where the SteamGridDB API key is kept. The app uses the Keychain; tests use memory.
public protocol APIKeyStoring: Sendable {
    func read() throws -> String?
    /// Stores the key; nil removes it.
    func write(_ key: String?) throws
}

/// The key as a generic password in the login Keychain.
public struct KeychainAPIKeyStore: APIKeyStoring {
    public static let defaultService = "dev.frontport.Frontport.steamgriddb"

    public let service: String
    public let account: String

    public init(service: String = KeychainAPIKeyStore.defaultService, account: String = "api-key") {
        self.service = service
        self.account = account
    }

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    public func read() throws -> String? {
        var request = query
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Self.failure("read", status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func write(_ key: String?) throws {
        guard let key else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.failure("remove", status) }
            return
        }
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrLabel] = "SteamGridDB API key (Frontport)"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw Self.failure("save", added) }
        } else if status != errSecSuccess {
            throw Self.failure("save", status)
        }
    }

    private static func failure(_ action: String, _ status: OSStatus) -> FrontportError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return .fileOperation("Couldn’t \(action) the SteamGridDB API key in the Keychain: \(message)")
    }
}
