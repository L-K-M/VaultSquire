import Foundation

/// The set of symmetric keys an unlocked Vaultwarden account can decrypt with:
/// the user key for personal items, and one key per organization the user
/// belongs to. Held only while unlocked; the session drops it on lock.
struct VaultwardenKeyring: Sendable {
    let userKey: VaultwardenSymmetricKey
    /// Organization id -> that organization's decrypted symmetric key. An
    /// organization whose key could not be unwrapped is simply absent, so its
    /// items decrypt to nothing rather than under the wrong key.
    let organizationKeys: [String: VaultwardenSymmetricKey]

    init(
        userKey: VaultwardenSymmetricKey,
        organizationKeys: [String: VaultwardenSymmetricKey] = [:]
    ) {
        self.userKey = userKey
        self.organizationKeys = organizationKeys
    }

    /// The key an item under `organizationID` (nil = personal) decrypts with, or
    /// nil when the organization's key is unavailable.
    func key(forOrganization organizationID: String?) -> VaultwardenSymmetricKey? {
        guard let organizationID else { return userKey }
        return organizationKeys[organizationID]
    }

    /// Resolves the actual content key for a cipher. Modern personal and
    /// organization ciphers carry an individual 64-byte key wrapped under the
    /// owner key; legacy ciphers without one use the owner key directly. A
    /// present but malformed wrapper never falls back to the owner key.
    func key(for cipher: VaultwardenCipherModel) -> VaultwardenSymmetricKey? {
        guard let ownerKey = key(forOrganization: cipher.organizationID) else {
            return nil
        }
        guard let wrapped = cipher.key else { return ownerKey }
        guard let parsed = try? VaultwardenEncString.parse(wrapped),
              var bytes = try? VaultwardenCipher.decrypt(parsed, key: ownerKey) else {
            return nil
        }
        defer { VaultwardenCryptoZeroize.zero(&bytes) }
        return try? VaultwardenSymmetricKey(keyData: bytes)
    }

    /// Decrypts one EncString under an already-resolved content key. Returns
    /// nil for a nil, unauthenticated, non-UTF-8, or otherwise unsupported
    /// field; no caller guesses a fallback algorithm.
    func decrypt(
        _ encString: String?,
        key: VaultwardenSymmetricKey?,
        maximumUTF8Bytes: Int = VaultwardenEncString.maximumPlaintextBytes
    ) -> String? {
        guard maximumUTF8Bytes >= 0,
              let encString,
              let key,
              let parsed = try? VaultwardenEncString.parse(encString),
              var data = try? VaultwardenCipher.decrypt(parsed, key: key) else {
            return nil
        }
        defer { VaultwardenCryptoZeroize.zero(&data) }
        guard data.count <= maximumUTF8Bytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Owner-key decryption remains appropriate for account-level values such
    /// as folder names, which never use an individual cipher key.
    func decrypt(
        _ encString: String?,
        organizationID: String?,
        maximumUTF8Bytes: Int = VaultwardenEncString.maximumPlaintextBytes
    ) -> String? {
        decrypt(
            encString,
            key: key(forOrganization: organizationID),
            maximumUTF8Bytes: maximumUTF8Bytes
        )
    }
}
