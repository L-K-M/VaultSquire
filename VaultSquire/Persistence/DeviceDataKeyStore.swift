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
    /// An existing record does not carry the required device-only accessibility.
    case insecureKeyRecord
    /// An unexpected platform failure.
    case unexpected(OSStatus)
}

/// A device-only symmetric key held in the Keychain, used to seal an at-rest
/// data blob (the encrypted vault cache). The key is generated once per label,
/// is accessible only while the device is unlocked, is bound to this device, and
/// never synchronizes to iCloud. The raw bytes never leave the Keychain except
/// to key an in-process AEAD, exactly like the database key the deferred
/// SQLCipher store would use.
///
/// The Data Protection Keychain is mandatory. An unentitled build reports the
/// store unavailable instead of silently changing the security boundary. A
/// malformed or weak existing record fails closed; it is never overwritten,
/// because replacing an unknown key would strand every blob sealed under it.
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
        // An older build could have placed this label in the legacy macOS
        // Keychain. It is never read or adopted; delete it before creating the
        // Data Protection record so weak duplicate material cannot linger.
        try deleteLegacyRecord()

        let generated = SymmetricKey(size: .bits256)
        var bytes = generated.withUnsafeBytes { Data($0) }
        defer { bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex) }
        let status = addKeyData(bytes)
        switch status {
        case errSecSuccess:
            return generated
        case errSecDuplicateItem:
            // Another task/process won the generate-and-add race. Adopt its
            // key; never overwrite it with this loser's random bytes.
            guard let winner = try load() else {
                throw DeviceDataKeyStoreError.unexpected(errSecDuplicateItem)
            }
            return winner
        default:
            throw Self.mapError(status)
        }
    }

    func load() throws -> SymmetricKey? {
        try loadOne()
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw Self.mapError(status)
        }
        // Cleanup only: remove a key an older build may have written through
        // its prohibited legacy fallback. No load or store path uses it.
        try deleteLegacyRecord()
    }

    // MARK: - Private

    private func loadOne() throws -> SymmetricKey? {
        var query = baseQuery()
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecReturnAttributes] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let attributes = result as? [CFString: Any],
                  attributes[kSecAttrAccessible] as? CFString
                    == kSecAttrAccessibleWhenUnlockedThisDeviceOnly else {
                throw DeviceDataKeyStoreError.insecureKeyRecord
            }
            guard var data = attributes[kSecValueData] as? Data, data.count == 32 else {
                throw DeviceDataKeyStoreError.malformedKey
            }
            defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw Self.mapError(status)
        }
    }

    private func addKeyData(_ bytes: Data) -> OSStatus {
        var query = baseQuery()
        query[kSecValueData] = bytes
        query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecAttrDescription] = "vaultsquire-device-data-key-v1"
        return SecItemAdd(query as CFDictionary, nil)
    }

    private func deleteLegacyRecord() throws {
        let status = SecItemDelete(legacyQuery() as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw Self.mapError(status)
        }
    }

    private func baseQuery() -> [CFString: Any] {
        var query = legacyQuery()
        query[kSecUseDataProtectionKeychain] = kCFBooleanTrue
        return query
    }

    private func legacyQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: label,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
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
