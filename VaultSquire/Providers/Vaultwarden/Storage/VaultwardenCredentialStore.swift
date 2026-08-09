import CryptoKit
import Foundation

/// The persisted network-session credentials for one Vaultwarden account: the
/// refresh token and, when the user chose to be remembered, the remembered
/// second-factor token. The access token is never persisted (it stays in
/// memory), and the master password is never stored in any form.
struct VaultwardenStoredCredentials: Hashable, Sendable, Codable {
    /// Layout version stored alongside the record, so a later format change can
    /// recognize and migrate older records.
    var version: Int
    var refreshToken: String
    var rememberedTwoFactorToken: String?

    init(
        refreshToken: String,
        rememberedTwoFactorToken: String? = nil,
        version: Int = VaultwardenStoredCredentials.currentVersion
    ) {
        self.version = version
        self.refreshToken = refreshToken
        self.rememberedTwoFactorToken = rememberedTwoFactorToken
    }

    static let currentVersion = 1
}

/// A stable, non-reversible key identifying one account's credential record.
/// No email or account identifier appears in Keychain metadata.
struct VaultwardenAccountKey: Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The single configured account. The installation exposes one account
    /// total until the multi-account workstream, so a fixed key avoids storing
    /// the email to recompute a per-account key.
    static let primary = VaultwardenAccountKey(rawValue: "vaultwarden-primary")

    /// A per-account key derived from the server host and normalized email, for
    /// the later multi-account workstream. The email is hashed, so it never
    /// appears in Keychain metadata.
    static func derived(serverHost: String, normalizedEmail: String) -> VaultwardenAccountKey {
        let material = "vaultwarden|\(serverHost.lowercased())|\(normalizedEmail)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return VaultwardenAccountKey(
            rawValue: digest.map { String(format: "%02x", $0) }.joined()
        )
    }
}

enum VaultwardenCredentialStoreError: Error, Equatable, Sendable {
    /// The platform credential store is unavailable in this environment (for
    /// example, an ad-hoc-signed test host without Keychain entitlements).
    /// Tests skip rather than fail on this.
    case storeUnavailable(OSStatus)
    /// The stored record could not be decoded.
    case malformedRecord
    /// A refresh-token replacement was requested for an account that has no
    /// stored record. Replacement updates an existing record; it does not
    /// create one.
    case recordNotFound
    /// An unexpected platform failure with its status code.
    case unexpected(OSStatus)
}

/// Persists and retrieves one account's network-session credentials. The real
/// implementation is Keychain-backed; an in-memory implementation supports
/// logic tests. Each write is atomic: a torn write can never leave a partial
/// token.
protocol VaultwardenCredentialStore: Sendable {
    func save(_ credentials: VaultwardenStoredCredentials, for account: VaultwardenAccountKey) throws
    func load(for account: VaultwardenAccountKey) throws -> VaultwardenStoredCredentials?
    /// Reports whether a record exists without exposing it. The Keychain
    /// implementation answers from item metadata so secret bytes never load
    /// for a mere existence check.
    func hasCredentials(for account: VaultwardenAccountKey) throws -> Bool
    /// Replaces only the refresh token of an existing record, preserving any
    /// remembered second-factor token, and throws `recordNotFound` when no
    /// record exists. The write itself is atomic (no torn token), but the
    /// read-then-write is not atomic across threads, so callers must serialize
    /// concurrent writes for one account.
    func replaceRefreshToken(_ token: String, for account: VaultwardenAccountKey) throws
    func delete(for account: VaultwardenAccountKey) throws
}

extension VaultwardenCredentialStore {
    /// Default existence check by loading the record. Suitable for in-memory
    /// stores; the Keychain store overrides it to avoid touching secret bytes.
    func hasCredentials(for account: VaultwardenAccountKey) throws -> Bool {
        try load(for: account) != nil
    }
}
