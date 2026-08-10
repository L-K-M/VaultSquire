import CryptoKit
import Foundation

/// A complete, decrypted, lossy capture of one Proton account's accessible
/// vaults and items, as produced by the official CLI and immediately re-sealed
/// by VaultSquire. It is never provider-native ciphertext: `lossy` is always
/// true, and the CLI version and capture time are authenticated so a stale or
/// mismatched snapshot is visible. Only bounded display, search, and offline
/// read fields are retained.
struct ProtonSnapshot: Equatable, Sendable, Codable {
    static let currentVersion = 1

    let version: Int
    /// The exact CLI version whose output produced this capture.
    let cliVersion: String
    let capturedAt: Date
    let vaults: [ProtonVault]
    let items: [ProtonItem]
    /// Always true. Recorded so a reader can never treat this as a lossless
    /// write source.
    let lossy: Bool

    init(cliVersion: String, capturedAt: Date, vaults: [ProtonVault], items: [ProtonItem]) {
        self.version = Self.currentVersion
        self.cliVersion = cliVersion
        self.capturedAt = capturedAt
        self.vaults = vaults
        self.items = items
        self.lossy = true
    }
}

enum ProtonSnapshotCacheError: Error, Equatable, Sendable {
    /// The device sealing key could not be obtained (Keychain unavailable).
    case storeUnavailable
    /// The sealed blob could not be opened: wrong key, tampering, or a context
    /// that does not match the account it was sealed under.
    case corrupt
    /// The cache directory or file could not be read or written.
    case ioFailed
}

/// The durable, device-sealed cache of one Proton account's captured snapshot.
///
/// The snapshot is JSON-encoded, sealed with `CacheEnvelopeCipher` (ChaCha20-
/// Poly1305) under a device-only Keychain key, and written atomically to a
/// per-account file. The seal authenticates the account identity, so a file
/// moved into another account's slot fails closed instead of opening. This is
/// the AEAD wrapper the research requires around lossy CLI output before it ever
/// rests; the payload is decrypted output, not Proton ciphertext, and is never
/// used to reconstruct or retry a remote write.
struct ProtonSnapshotCache: Sendable {
    private let keyProvider: @Sendable () throws -> SymmetricKey
    private let directory: URL
    // FileManager is thread-safe for the operations used here but is not
    // Sendable; vouch for it so the cache stays Sendable.
    nonisolated(unsafe) private let fileManager: FileManager

    /// The envelope layout version, folded into the seal's authenticated data.
    /// Distinct from the Vaultwarden cache's version space; the account's
    /// provider is authenticated too, so the two can never be confused.
    private static let schemaVersion = 1

    init(
        keyStore: DeviceDataKeyStore = DeviceDataKeyStore(label: "proton-snapshot-cache"),
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.init(
            keyProvider: {
                do {
                    return try keyStore.loadOrCreate()
                } catch DeviceDataKeyStoreError.unavailable {
                    throw ProtonSnapshotCacheError.storeUnavailable
                } catch {
                    throw ProtonSnapshotCacheError.ioFailed
                }
            },
            directory: directory,
            fileManager: fileManager
        )
    }

    init(
        keyProvider: @escaping @Sendable () throws -> SymmetricKey,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.keyProvider = keyProvider
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let base = (try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )) ?? fileManager.temporaryDirectory
            self.directory = base
                .appendingPathComponent("VaultSquire", isDirectory: true)
                .appendingPathComponent("ProtonSnapshots", isDirectory: true)
        }
    }

    func save(_ snapshot: ProtonSnapshot, for account: AccountID) throws {
        let key = try sealingKey()
        let plaintext: Data
        do {
            plaintext = try JSONEncoder().encode(snapshot)
        } catch {
            throw ProtonSnapshotCacheError.ioFailed
        }
        let sealed = try seal(plaintext, key: key, account: account)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try sealed.write(to: fileURL(for: account), options: [.atomic, .completeFileProtection])
        } catch {
            throw ProtonSnapshotCacheError.ioFailed
        }
    }

    func load(for account: AccountID) throws -> ProtonSnapshot? {
        let url = fileURL(for: account)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let key = try sealingKey()
        let sealed: Data
        do {
            sealed = try Data(contentsOf: url)
        } catch {
            throw ProtonSnapshotCacheError.ioFailed
        }
        let plaintext = try open(sealed, key: key, account: account)
        do {
            return try JSONDecoder().decode(ProtonSnapshot.self, from: plaintext)
        } catch {
            throw ProtonSnapshotCacheError.corrupt
        }
    }

    func exists(for account: AccountID) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: account).path)
    }

    func wipe(for account: AccountID) throws {
        let url = fileURL(for: account)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw ProtonSnapshotCacheError.ioFailed
        }
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
            throw ProtonSnapshotCacheError.ioFailed
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
            throw ProtonSnapshotCacheError.corrupt
        }
    }

    private func fileURL(for account: AccountID) -> URL {
        // Hash the account identity into the filename: opaque, filesystem-safe,
        // and leaking nothing even if a raw value ever carried readable text.
        let material = "\(account.provider.rawValue)|\(account.rawValue)"
        let digest = SHA256.hash(data: Data(material.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).protoncache", isDirectory: false)
    }
}
