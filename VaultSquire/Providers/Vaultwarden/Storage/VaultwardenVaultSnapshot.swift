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
    /// Provider bootstrap revision used to detect hierarchy invalidation before
    /// a newly synced candidate can replace the last known-good snapshot.
    var securityStamp: String? = nil
    var organizations: [Organization]
    var folders: [Folder]
    var ciphers: [VaultwardenCipherModel]
    /// Exact bounded sync bytes retain fields and unknown cipher forms this
    /// build cannot model yet. They are provider ciphertext, never a write
    /// source, and remain sealed with the snapshot.
    var rawSyncResponse: Data? = nil
    /// Durable lockout marker set when bootstrap material changes or the
    /// provider rejects the refresh session. Both master-password and biometric
    /// offline unlock fail until a complete login transaction replaces this
    /// snapshot.
    var reauthenticationRequired: Bool? = nil
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

    var isStructurallyValid: Bool {
        guard version == Self.currentVersion,
              generation > 0,
              syncedAt.timeIntervalSince1970.isFinite,
              email == VaultwardenKeyDerivation.normalizedEmail(email),
              !email.isEmpty, email.utf8.count <= 320,
              serverBaseURL.utf8.count <= 2_048,
              wrappedUserKey.utf8.count <= VaultwardenEncString.maximumSerializedBytes,
              wrappedPrivateKey.map({
                  $0.utf8.count <= VaultwardenEncString.maximumSerializedBytes
              }) != false,
              securityStamp.map({ $0.utf8.count <= 4_096 }) != false,
              rawSyncResponse.map({ $0.count <= 50 * 1024 * 1024 }) != false,
              organizations.count <= 256,
              folders.count <= 10_000,
              ciphers.count <= 50_000,
              (try? kdf.configuration().validate()) != nil,
              (try? VaultwardenEnvironment(configuredURL: serverBaseURL)) != nil,
              Self.isValidServiceURL(identityBaseURL),
              apiBaseURL.map(Self.isValidServiceURL) != false else {
            return false
        }

        let organizationIDs = organizations.map(\.id)
        let folderIDs = folders.map(\.id)
        let cipherIDs = ciphers.map(\.id)
        guard Set(organizationIDs).count == organizationIDs.count,
              Set(folderIDs).count == folderIDs.count,
              Set(cipherIDs).count == cipherIDs.count else {
            return false
        }
        return organizations.allSatisfy {
            !$0.id.isEmpty && $0.id.utf8.count <= 512
                && $0.name.map({ $0.utf8.count <= 4_096 }) != false
                && $0.wrappedKey.utf8.count <= VaultwardenEncString.maximumSerializedBytes
        } && folders.allSatisfy {
            !$0.id.isEmpty && $0.id.utf8.count <= 512
                && $0.name.utf8.count <= VaultwardenEncString.maximumSerializedBytes
        } && ciphers.allSatisfy(\.isStructurallyValid)
    }

    private static func isValidServiceURL(_ raw: String) -> Bool {
        let lowered = raw.lowercased()
        guard raw.utf8.count <= 2_048,
              raw.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              !lowered.contains("%25"),
              !lowered.contains("%2e"),
              !lowered.contains("%2f"),
              !lowered.contains("%5c"),
              !raw.contains("\\"),
              let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return false
        }
        let encodedPath = components.percentEncodedPath.lowercased()
        guard !encodedPath.contains("%25"),
              !encodedPath.contains("%2e"),
              !encodedPath.contains("%2f"),
              !encodedPath.contains("%5c"),
              !encodedPath.contains("\\") else {
            return false
        }
        return !components.path
            .split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0 == "." || $0 == ".." })
    }
}
