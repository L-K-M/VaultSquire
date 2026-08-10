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

/// A device-only symmetric key held in the Keychain, used to seal an at-rest
/// data blob (the encrypted vault cache). The key is generated once per label,
/// is accessible only while the device is unlocked, is bound to this device, and
/// never synchronizes to iCloud. The raw bytes never leave the Keychain except
/// to key an in-process AEAD, exactly like the database key the deferred
/// SQLCipher store would use.
///
/// The Data Protection Keychain is preferred, but a locally built or Developer
/// ID app on macOS may not carry the entitlement it needs; in that case the
/// store falls back to the legacy Keychain, which is available to any signed
/// app. A stale record left by an earlier build is overwritten rather than
/// allowed to wedge the seal, so a re-add always produces a usable key.
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

    /// Returns the stored key from whichever Keychain holds it, or nil if none
    /// exists in a reachable Keychain. Throws only when no Keychain is reachable.
    func load() throws -> SymmetricKey? {
        var reachableKeychains = 0
        for useDataProtection in [true, false] {
            do {
                if let key = try loadOne(useDataProtection: useDataProtection) {
                    return key
                }
                reachableKeychains += 1
            } catch let error as DeviceDataKeyStoreError {
                // An unavailable Keychain is not fatal: try the other one.
                if case .unavailable = error { continue }
                throw error
            }
        }
        if reachableKeychains == 0 {
            throw DeviceDataKeyStoreError.unavailable(errSecNotAvailable)
        }
        return nil
    }

    func delete() throws {
        for useDataProtection in [true, false] {
            let status = SecItemDelete(baseQuery(useDataProtection: useDataProtection) as CFDictionary)
            switch status {
            case errSecSuccess, errSecItemNotFound:
                continue
            default:
                throw Self.mapError(status)
            }
        }
    }

    // MARK: - Private

    private func loadOne(useDataProtection: Bool) throws -> SymmetricKey? {
        var query = baseQuery(useDataProtection: useDataProtection)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            // A wrong-sized record (corrupt or from an incompatible earlier
            // build) is treated as absent so a fresh key overwrites it, rather
            // than throwing and wedging every seal.
            guard let data = result as? Data, data.count == 32 else {
                return nil
            }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw Self.mapError(status)
        }
    }

    private func store(_ bytes: Data) throws {
        var lastUnavailable: DeviceDataKeyStoreError?
        for useDataProtection in [true, false] {
            do {
                try storeOne(bytes, useDataProtection: useDataProtection)
                return
            } catch let error as DeviceDataKeyStoreError {
                if case .unavailable = error {
                    lastUnavailable = error
                    continue
                }
                throw error
            }
        }
        throw lastUnavailable ?? DeviceDataKeyStoreError.unavailable(errSecNotAvailable)
    }

    private func storeOne(_ bytes: Data, useDataProtection: Bool) throws {
        var query = baseQuery(useDataProtection: useDataProtection)
        query[kSecValueData] = bytes
        query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecAttrSynchronizable] = kCFBooleanFalse
        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // A record already exists under this identity (for example from an
            // earlier build with slightly different attributes that a load could
            // not read back). Overwrite its data so the seal is not wedged by a
            // stale item. Any data sealed under a lost prior key was already
            // unreadable, so nothing recoverable is discarded.
            let attributes: [CFString: Any] = [kSecValueData: bytes]
            let updateStatus = SecItemUpdate(
                baseQuery(useDataProtection: useDataProtection) as CFDictionary,
                attributes as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw Self.mapError(updateStatus)
            }
        default:
            throw Self.mapError(status)
        }
    }

    private func baseQuery(useDataProtection: Bool) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: label,
        ]
        if useDataProtection {
            query[kSecUseDataProtectionKeychain] = kCFBooleanTrue
        }
        return query
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
