import CryptoKit
import Foundation
import Security

enum DeviceDataKeyStoreError: Error, Equatable, Sendable {
    /// The Keychain is not usable in this environment (for example an
    /// ad-hoc-signed test host with no keychain-access-group entitlement).
    /// Callers treat this as "storage unavailable" and skip rather than fail.
    case unavailable(OSStatus)
    /// A stored key record was the wrong size to be a 256-bit key.
    case malformedKey
    /// An unexpected platform failure.
    case unexpected(OSStatus)
}

/// A device-only symmetric key held in the Data Protection Keychain, used to
/// seal an at-rest data blob (the encrypted vault cache). The key is generated
/// once per label, is accessible only while the device is unlocked, is bound to
/// this device, and never synchronizes to iCloud. The raw bytes never leave the
/// Keychain except to key an in-process AEAD, exactly like the database key the
/// deferred SQLCipher store would use.
struct DeviceDataKeyStore: Sendable {
    let service: String
    let label: String

    init(
        service: String = "ch.lkmc.VaultSquire.device-data-keys",
        label: String
    ) {
        self.service = service
        self.label = label
    }

    /// Returns the existing key, or generates, stores, and returns a new one.
    /// The generate-then-store is not atomic across processes; VaultSquire runs
    /// one instance per user, so a lost-write race cannot occur here.
    func loadOrCreate() throws -> SymmetricKey {
        if let existing = try load() {
            return existing
        }
        let key = SymmetricKey(size: .bits256)
        let bytes = key.withUnsafeBytes { Data($0) }
        try store(bytes)
        return key
    }

    /// Returns the stored key, or nil if none exists.
    func load() throws -> SymmetricKey? {
        var query = baseQuery()
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == 32 else {
                throw DeviceDataKeyStoreError.malformedKey
            }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw Self.mapError(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw Self.mapError(status)
        }
    }

    private func store(_ bytes: Data) throws {
        var query = baseQuery()
        query[kSecValueData] = bytes
        query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecAttrSynchronizable] = kCFBooleanFalse
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw Self.mapError(status)
        }
    }

    private func baseQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain: kCFBooleanTrue as Any,
            kSecAttrService: service,
            kSecAttrAccount: label,
        ]
    }

    private static func mapError(_ status: OSStatus) -> DeviceDataKeyStoreError {
        if status == errSecMissingEntitlement
            || status == errSecInteractionNotAllowed
            || status == errSecNotAvailable {
            return .unavailable(status)
        }
        return .unexpected(status)
    }
}
