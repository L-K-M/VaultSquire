import Foundation

/// Everything one Vaultwarden account needs for offline unlock and display,
/// held as a single `Codable` value that the vault cache seals at rest.
///
/// It carries the non-secret account descriptor (server, email, KDF), the
/// wrapped key material (useless without the master password), and the synced
/// ciphers, folders, and organization keys as their raw EncStrings. Nothing
/// here is decrypted: unlock re-derives keys from the password and decrypts on
/// demand. The whole value is sealed with a device-only key before it rests, so
/// a stolen file yields nothing without the device Keychain, and nothing yields
/// the vault without the master password.
struct VaultwardenVaultSnapshot: Sendable, Codable, Hashable {
    /// Layout version, so a later shape change can be recognized and migrated.
    var version: Int
    /// The normalized base URL string the account authenticated against.
    var serverBaseURL: String
    /// The identity base URL approved during login, reused for token refresh.
    var identityBaseURL: String
    /// The API base URL (".../api") approved during login, used for sync and
    /// writes. Optional so snapshots sealed before this field decode; when
    /// absent, the API URL is derived from `serverBaseURL`, which is only
    /// correct for same-origin servers.
    var apiBaseURL: String? = nil
    /// The normalized login email — the KDF salt and the account's display name.
    var email: String
    var kdf: KDF
    /// The user key, wrapped under the stretched master key (a type-2 EncString).
    var wrappedUserKey: String
    /// The user's RSA private key, wrapped under the user key (a type-2
    /// EncString). Absent for accounts with no asymmetric key.
    var wrappedPrivateKey: String?
    var organizations: [Organization]
    var folders: [Folder]
    var ciphers: [VaultwardenCipherModel]
    /// When the sync that produced this snapshot completed.
    var syncedAt: Date
    /// Monotonic capture generation, advanced on every successful sync. It backs
    /// each projection's `ProviderCacheReference`, so a projection can be traced
    /// to the exact snapshot it was decrypted from.
    var generation: UInt64

    static let currentVersion = 1

    struct KDF: Sendable, Codable, Hashable {
        var kind: Int          // 0 = PBKDF2-SHA256, 1 = Argon2id
        var iterations: Int
        var memoryMiB: Int?
        var parallelism: Int?

        init(configuration: VaultwardenKDFConfiguration) {
            switch configuration {
            case .pbkdf2SHA256(let iterations):
                self.kind = 0
                self.iterations = iterations
                self.memoryMiB = nil
                self.parallelism = nil
            case .argon2id(let iterations, let memoryMiB, let parallelism):
                self.kind = 1
                self.iterations = iterations
                self.memoryMiB = memoryMiB
                self.parallelism = parallelism
            }
        }

        func configuration() throws -> VaultwardenKDFConfiguration {
            switch kind {
            case 0:
                return .pbkdf2SHA256(iterations: iterations)
            case 1:
                return .argon2id(
                    iterations: iterations,
                    memoryMiB: memoryMiB ?? 0,
                    parallelism: parallelism ?? 0
                )
            default:
                throw VaultwardenCryptoError.invalidKDFParameters(.unknownAlgorithm)
            }
        }
    }

    struct Organization: Sendable, Codable, Hashable {
        var id: String
        var name: String?
        /// Organization key, RSA-wrapped for this user.
        var wrappedKey: String
    }

    struct Folder: Sendable, Codable, Hashable {
        var id: String
        /// Folder name EncString.
        var name: String
    }
}
