import Foundation
import Security
import LocalAuthentication

public struct SavedNASCredentials: Codable, Equatable, Sendable {
    public var password: String?
    public var deviceID: String?
    public init(password: String?, deviceID: String? = nil) { self.password = password; self.deviceID = deviceID }
}

public enum CredentialStore {
    // Separate service prevents reading/reusing the original client's credentials.
    private static let service = "cloud.synology-note.notestation.password.v1"

    private static let credentialPrefix = Data("synology-note-credentials:v2\n".utf8)

    public static func save(password: String, account: String) throws {
        try saveCredentials(SavedNASCredentials(password: password), account: account)
    }

    // Tests can exercise the real Security.framework operations against an
    // isolated temporary keychain, including on headless CI runners.
    static func save(password: String, account: String, testKeychain: SecKeychain) throws {
        try saveCredentials(SavedNASCredentials(password: password), account: account, testKeychain: testKeychain)
    }

    public static func saveCredentials(_ credentials: SavedNASCredentials, account: String, allowInteraction: Bool = false) throws {
        try saveCredentials(credentials, account: account, allowInteraction: allowInteraction, keychain: nil)
    }

    static func saveCredentials(_ credentials: SavedNASCredentials, account: String, testKeychain: SecKeychain) throws {
        try saveCredentials(credentials, account: account, allowInteraction: false, keychain: testKeychain)
    }

    private static func saveCredentials(_ credentials: SavedNASCredentials, account: String, allowInteraction: Bool, keychain: SecKeychain?) throws {
        let query = try query(account: account, allowInteraction: allowInteraction, keychain: keychain)
        var data = credentialPrefix
        data.append(try JSONEncoder().encode(credentials))
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            // Another caller may have created the item between update and add.
            if added == errSecDuplicateItem {
                try check(SecItemUpdate(query as CFDictionary, attributes as CFDictionary))
            } else { try check(added) }
        } else { try check(status) }
    }

    public static func load(account: String) throws -> String? {
        try loadCredentials(account: account)?.password
    }

    static func load(account: String, testKeychain: SecKeychain) throws -> String? {
        try loadCredentials(account: account, testKeychain: testKeychain)?.password
    }

    public static func loadCredentials(account: String, allowInteraction: Bool = false) throws -> SavedNASCredentials? {
        try loadCredentials(account: account, allowInteraction: allowInteraction, keychain: nil)
    }

    static func loadCredentials(account: String, testKeychain: SecKeychain) throws -> SavedNASCredentials? {
        try loadCredentials(account: account, allowInteraction: false, keychain: testKeychain)
    }

    private static func loadCredentials(account: String, allowInteraction: Bool, keychain: SecKeychain?) throws -> SavedNASCredentials? {
        var query = try query(account: account, allowInteraction: allowInteraction, keychain: keychain)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw CredentialStoreError.invalidData }
        if data.starts(with: credentialPrefix) {
            guard let credentials = try? JSONDecoder().decode(SavedNASCredentials.self, from: data.dropFirst(credentialPrefix.count)) else {
                throw CredentialStoreError.invalidData
            }
            return credentials
        }
        // Existing installations stored only the UTF-8 password.
        guard let password = String(data: data, encoding: .utf8) else { throw CredentialStoreError.invalidData }
        return SavedNASCredentials(password: password)
    }

    public static func loadCredentialsAsync(account: String) async throws -> SavedNASCredentials? {
        try await boundedLoad(timeout: 3) { try loadCredentials(account: account) }
    }

    // A legacy macOS ACL request can wait inside Security.framework even with
    // interaction disabled. Do not let that wait block startup or manual login.
    static func boundedLoad(timeout: TimeInterval, operation: @escaping @Sendable () throws -> SavedNASCredentials?) async throws -> SavedNASCredentials? {
        try await withCheckedThrowingContinuation { continuation in
            let result = CredentialLoadResult(continuation)
            DispatchQueue.global(qos: .userInitiated).async { result.finish(Result { try operation() }) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                result.finish(.failure(CredentialStoreError.keychain(status: errSecInteractionNotAllowed)))
            }
        }
    }

    public static func remove(account: String, allowInteraction: Bool = false) throws {
        try remove(account: account, allowInteraction: allowInteraction, keychain: nil)
    }

    static func remove(account: String, testKeychain: SecKeychain) throws {
        try remove(account: account, allowInteraction: false, keychain: testKeychain)
    }

    private static func remove(account: String, allowInteraction: Bool, keychain: SecKeychain?) throws {
        let status = SecItemDelete(try query(account: account, allowInteraction: allowInteraction, keychain: keychain) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func query(account: String, allowInteraction: Bool = false, keychain: SecKeychain? = nil) throws -> [String: Any] {
        guard !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CredentialStoreError.invalidAccount }
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        var attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false,
                // macOS keychain ACL prompts can block even when LAContext
                // forbids biometric interaction. Automatic access must fail
                // instead of waiting for SecurityAgent authorization.
                kSecUseAuthenticationUI as String: allowInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail,
                kSecUseAuthenticationContext as String: context]
        if let keychain {
            attributes[kSecUseKeychain as String] = keychain
            attributes[kSecMatchSearchList as String] = [keychain]
        }
        return attributes
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status: status) }
    }
}

private final class CredentialLoadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SavedNASCredentials?, Error>?
    init(_ continuation: CheckedContinuation<SavedNASCredentials?, Error>) { self.continuation = continuation }
    func finish(_ result: Result<SavedNASCredentials?, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

public enum CredentialStoreError: Error, Equatable, Sendable, LocalizedError {
    case invalidAccount
    case invalidData
    case keychain(status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidAccount: return "Keychain 계정 식별자가 필요합니다."
        case .invalidData: return "Keychain 비밀번호 데이터를 읽을 수 없습니다."
        case .keychain(let status): return "Keychain 작업에 실패했습니다 (\(status))."
        }
    }
}
