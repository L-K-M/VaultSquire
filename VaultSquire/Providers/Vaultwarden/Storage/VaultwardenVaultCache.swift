import CryptoKit
import Foundation

enum VaultwardenVaultCacheError: Error, Equatable, Sendable {
    /// The device sealing key could not be obtained (Keychain unavailable).
    case storeUnavailable
    /// The on-disk blob could not be opened: wrong key, tampering, or a context
    /// that does not match the account it was sealed under.
    case corrupt
    /// The cache directory or file could not be read or written.
    case ioFailed
}

/// The durable, device-sealed cache of one Vaultwarden account's synced vault.
///
/// A snapshot is JSON-encoded, sealed with `CacheEnvelopeCipher` (ChaCha20-
/// Poly1305) under a device-only Keychain key, and written atomically to a
/// per-account file in Application Support. The seal authenticates the account
/// identity, so a file copied into another account's slot fails closed instead
/// of opening. The payload stays encrypted at rest; unlock re-derives keys from
/// the master password and decrypts individual items in memory.
///
/// This is VaultSquire's native realization of the deferred at-rest store:
/// CryptoKit and Foundation only, no SQLCipher and no third-party dependency.
struct VaultwardenVaultCache: Sendable {
    /// Supplies the device-only sealing key. Production reads it from the Data
    /// Protection Keychain; tests inject a fixed key so the seal/open and file
    /// logic can be exercised on hosts without Keychain access.
    private let keyProvider: @Sendable () throws -> SymmetricKey
    private let keyInvalidator: @Sendable () throws -> Void
    private let directory: URL?
    // FileManager is thread-safe for the file operations used here but is not
    // marked Sendable; vouch for it so the cache stays Sendable.
    nonisolated(unsafe) private let fileManager: FileManager

    /// The envelope layout version, folded into the seal's authenticated data.
    private static let schemaVersion = 1
    private static let maximumSealedBytes = 128 * 1024 * 1024

    init(
        keyStore: DeviceDataKeyStore = DeviceDataKeyStore(label: "vaultwarden-vault-cache"),
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.init(
            keyProvider: {
                do {
                    return try keyStore.loadOrCreate()
                } catch DeviceDataKeyStoreError.unavailable {
                    throw VaultwardenVaultCacheError.storeUnavailable
                } catch {
                    throw VaultwardenVaultCacheError.ioFailed
                }
            },
            keyInvalidator: {
                do {
                    try keyStore.delete()
                } catch DeviceDataKeyStoreError.unavailable {
                    throw VaultwardenVaultCacheError.storeUnavailable
                } catch {
                    throw VaultwardenVaultCacheError.ioFailed
                }
            },
            directory: directory,
            fileManager: fileManager
        )
    }

    init(
        keyProvider: @escaping @Sendable () throws -> SymmetricKey,
        keyInvalidator: @escaping @Sendable () throws -> Void = {
            throw VaultwardenVaultCacheError.storeUnavailable
        },
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.keyProvider = keyProvider
        self.keyInvalidator = keyInvalidator
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            self.directory = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: "group.ch.lkmc.VaultSquire"
            )?.appendingPathComponent("VaultwardenVaults", isDirectory: true)
        }
    }

    func save(_ snapshot: VaultwardenVaultSnapshot, for account: AccountID) throws {
        guard snapshot.isStructurallyValid, let directory else {
            throw VaultwardenVaultCacheError.storeUnavailable
        }
        let key = try sealingKey()
        var plaintext: Data
        do {
            plaintext = try JSONEncoder().encode(snapshot)
        } catch {
            throw VaultwardenVaultCacheError.ioFailed
        }
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        guard plaintext.count <= Self.maximumSealedBytes else {
            throw VaultwardenVaultCacheError.ioFailed
        }
        let sealed = try seal(plaintext, key: key, account: account)
        guard sealed.count <= Self.maximumSealedBytes else {
            throw VaultwardenVaultCacheError.ioFailed
        }

        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try Self.writeSealed(sealed, to: fileURL(for: account, directory: directory))
        } catch {
            throw VaultwardenVaultCacheError.ioFailed
        }
    }

    /// Writes the sealed payload, preferring complete file protection but
    /// falling back to a plain atomic write when the data-protection option is
    /// rejected. The payload is already AEAD-sealed, so the fallback loses only
    /// a redundant OS-level protection an unentitled macOS build can't apply,
    /// never confidentiality.
    private static func writeSealed(_ sealed: Data, to url: URL) throws {
        do {
            try sealed.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            try sealed.write(to: url, options: [.atomic])
        }
    }

    func load(for account: AccountID) throws -> VaultwardenVaultSnapshot? {
        guard let directory else { throw VaultwardenVaultCacheError.storeUnavailable }
        let url = fileURL(for: account, directory: directory)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let key = try sealingKey()

        let sealed: Data
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.intValue > 0,
                  size.intValue <= Self.maximumSealedBytes else {
                throw VaultwardenVaultCacheError.corrupt
            }
            sealed = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch let error as VaultwardenVaultCacheError {
            throw error
        } catch {
            throw VaultwardenVaultCacheError.ioFailed
        }
        var plaintext = try open(sealed, key: key, account: account)
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        guard plaintext.count <= Self.maximumSealedBytes else {
            throw VaultwardenVaultCacheError.corrupt
        }
        do {
            let snapshot = try JSONDecoder().decode(VaultwardenVaultSnapshot.self, from: plaintext)
            guard snapshot.isStructurallyValid else {
                throw VaultwardenVaultCacheError.corrupt
            }
            return snapshot
        } catch let error as VaultwardenVaultCacheError {
            throw error
        } catch {
            throw VaultwardenVaultCacheError.corrupt
        }
    }

    func exists(for account: AccountID) -> Bool {
        guard let directory else { return false }
        return fileManager.fileExists(atPath: fileURL(for: account, directory: directory).path)
    }

    func wipe(for account: AccountID) throws {
        guard let directory else { throw VaultwardenVaultCacheError.storeUnavailable }
        let url = fileURL(for: account, directory: directory)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw VaultwardenVaultCacheError.ioFailed
        }
    }

    /// Last-resort fail-closed path for a security-marker write and cache wipe
    /// that both fail: deleting the device-only sealing key makes every old
    /// Vaultwarden cache ciphertext inaccessible after process restart.
    func invalidateSealingKey() throws {
        try keyInvalidator()
    }

    // MARK: - Private

    private func sealingKey() throws -> SymmetricKey {
        try keyProvider()
    }

    private func seal(_ plaintext: Data, key: SymmetricKey, account: AccountID) throws -> Data {
        do {
            return try CacheEnvelopeCipher.seal(
                plaintext,
                key: key,
                context: CacheEnvelopeContext(account: account, schemaVersion: Self.schemaVersion)
            )
        } catch {
            throw VaultwardenVaultCacheError.ioFailed
        }
    }

    private func open(_ sealed: Data, key: SymmetricKey, account: AccountID) throws -> Data {
        do {
            return try CacheEnvelopeCipher.open(
                sealed,
                key: key,
                context: CacheEnvelopeContext(account: account, schemaVersion: Self.schemaVersion)
            )
        } catch {
            throw VaultwardenVaultCacheError.corrupt
        }
    }

    private func fileURL(for account: AccountID, directory: URL) -> URL {
        // Hash the account identity into the filename: opaque, filesystem-safe,
        // and leaking nothing even if a raw value ever carried readable text.
        let material = "\(account.provider.rawValue)|\(account.rawValue)"
        let digest = SHA256.hash(data: Data(material.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).vaultcache", isDirectory: false)
    }
}
