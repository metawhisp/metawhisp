import Foundation
import Security

/// What a keychain read found. "Not there" and "there but unreadable" are
/// different answers: treating an access error as "no item" is how a locked
/// or broken keychain looked like a signed-out user (ITER-075 step 0, US-0.4).
enum KeychainRead: Equatable {
    case value(String)
    case notFound
    case failed(OSStatus)
}

/// The four keychain calls `KeychainHelper` makes, so tests can use a fake.
protocol KeychainBackend {
    func copy(service: String, account: String) -> (OSStatus, Data?)
    func add(service: String, account: String, data: Data) -> OSStatus
    func update(service: String, account: String, data: Data) -> OSStatus
    func delete(service: String, account: String) -> OSStatus
}

/// The login keychain, through the Security framework.
struct SystemKeychain: KeychainBackend {
    private func item(_ service: String, _ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func copy(service: String, account: String) -> (OSStatus, Data?) {
        var query = item(service, account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        return (status, out as? Data)
    }

    func add(service: String, account: String, data: Data) -> OSStatus {
        var attributes = item(service, account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(service: String, account: String, data: Data) -> OSStatus {
        SecItemUpdate(item(service, account) as CFDictionary,
                      [kSecValueData as String: data] as CFDictionary)
    }

    func delete(service: String, account: String) -> OSStatus {
        SecItemDelete(item(service, account) as CFDictionary)
    }
}

/// The keychain under XCTest: empty, and it keeps nothing. A real read of an
/// item whose ACL doesn't trust the test binary blocks on a hidden prompt
/// (ITER-053.1), and tests must never touch the user's secrets.
struct EmptyKeychain: KeychainBackend {
    func copy(service: String, account: String) -> (OSStatus, Data?) { (errSecItemNotFound, nil) }
    func add(service: String, account: String, data: Data) -> OSStatus { errSecSuccess }
    func update(service: String, account: String, data: Data) -> OSStatus { errSecSuccess }
    func delete(service: String, account: String) -> OSStatus { errSecSuccess }
}
