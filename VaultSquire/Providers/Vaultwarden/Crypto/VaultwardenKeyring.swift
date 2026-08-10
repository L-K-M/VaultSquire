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

    /// Decrypts one EncString field under the item's key. Returns nil for a nil
    /// or undecryptable field, so a single bad field never aborts a whole item;
    /// the caller shows what decrypted and omits what did not.
    func decrypt(_ encString: String?, organizationID: String?) -> String? {
        guard let encString,
              let key = key(forOrganization: organizationID),
              let parsed = try? VaultwardenEncString.parse(encString),
              let data = try? VaultwardenCipher.decrypt(parsed, key: key) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
