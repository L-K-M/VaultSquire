import Foundation
import Security

/// Keychain-backed credential store. Every record uses the Data Protection
/// Keychain, is accessible only when the device is unlocked, is bound to this
/// device, and is never synchronized to iCloud. One generic-password item per
/// account holds the encoded credentials; the refresh token is replaced with
/// an atomic `SecItemUpdate`.
struct KeychainCredentialStore: VaultwardenCredentialStore {
    /// Service under which all Vaultwarden credential records are grouped.
    let service: String
    /// A non-secret record descriptor carrying the layout version, satisfying
    /// the rule to label records with an algorithm/version.
    private let recordDescription = "vaultwarden-credentials-v1"

    init(service: String = "ch.lkmc.VaultSquire.vaultwarden-credentials") {
        self.service = service
    }

    func save(
        _ credentials: VaultwardenStoredCredentials,
        for account: VaultwardenAccountKey
    ) throws {
        let value = try JSONEncoder().encode(credentials)

        var query = baseQuery(for: account)
        let attributes: [CFString: Any] = [
            kSecValueData: value,
            kSecAttrDescription: recordDescription,
        ]

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break
        default:
            throw Self.mapWriteError(updateStatus)
        }

        // No existing record: add one with the full protection attributes.
        for (key, attributeValue) in attributes {
            query[key] = attributeValue
        }
        query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecAttrSynchronizable] = kCFBooleanFalse
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw Self.mapWriteError(addStatus)
        }
    }

    func load(for account: VaultwardenAccountKey) throws -> VaultwardenStoredCredentials? {
        var query = baseQuery(for: account)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw VaultwardenCredentialStoreError.malformedRecord
            }
            do {
                return try JSONDecoder().decode(
                    VaultwardenStoredCredentials.self, from: data
                )
            } catch {
                throw VaultwardenCredentialStoreError.malformedRecord
            }
        case errSecItemNotFound:
            return nil
        default:
            throw Self.mapReadError(status)
        }
    }

    func replaceRefreshToken(
        _ token: String,
        for account: VaultwardenAccountKey
    ) throws {
        // Update an existing record only; do not create one. The remembered
        // second-factor token and layout version are preserved. The
        // SecItemUpdate writes the whole record in one operation (no torn
        // token); the load-then-update is not atomic across threads, so callers
        // serialize concurrent writes for one account.
        guard let existing = try load(for: account) else {
            throw VaultwardenCredentialStoreError.recordNotFound
        }
        let updated = VaultwardenStoredCredentials(
            refreshToken: token,
            rememberedTwoFactorToken: existing.rememberedTwoFactorToken,
            version: existing.version
        )
        let value = try JSONEncoder().encode(updated)
        let attributes: [CFString: Any] = [
            kSecValueData: value,
            kSecAttrDescription: recordDescription,
        ]
        let status = SecItemUpdate(
            baseQuery(for: account) as CFDictionary,
            attributes as CFDictionary
        )
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            throw VaultwardenCredentialStoreError.recordNotFound
        default:
            throw Self.mapWriteError(status)
        }
    }

    func delete(for account: VaultwardenAccountKey) throws {
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw Self.mapWriteError(status)
        }
    }

    private func baseQuery(for account: VaultwardenAccountKey) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain: kCFBooleanTrue as Any,
            kSecAttrService: service,
            kSecAttrAccount: account.rawValue,
        ]
    }

    /// Distinguishes "the store is not usable in this environment" (missing
    /// entitlement or interaction not allowed) from a genuine failure, so
    /// callers and tests can treat the former as unavailable rather than
    /// broken.
    private static func mapWriteError(_ status: OSStatus) -> VaultwardenCredentialStoreError {
        if isUnavailable(status) {
            return .storeUnavailable(status)
        }
        return .unexpected(status)
    }

    private static func mapReadError(_ status: OSStatus) -> VaultwardenCredentialStoreError {
        if isUnavailable(status) {
            return .storeUnavailable(status)
        }
        return .unexpected(status)
    }

    private static func isUnavailable(_ status: OSStatus) -> Bool {
        status == errSecMissingEntitlement
            || status == errSecInteractionNotAllowed
            || status == errSecNotAvailable
    }
}
