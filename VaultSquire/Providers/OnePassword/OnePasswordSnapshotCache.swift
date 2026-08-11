import CryptoKit
import Foundation

/// A complete, decrypted, lossy capture of one 1Password account's readable
/// vaults and item summaries, as produced by the official CLI and immediately
/// re-sealed by VaultSquire. It is never provider-native ciphertext: `lossy` is
/// always true, and the CLI version and capture time are authenticated so a
/// stale or mismatched snapshot is visible.
///
/// Only bounded, non-secret display and search fields are retained. No
/// password, one-time-password seed, note, or other concealed value is ever
/// part of a snapshot — those are fetched when an item is opened and held in
/// memory for that session alone.
struct OnePasswordSnapshot: Equatable, Sendable, Codable {
    static let currentVersion = 1

    let version: Int
    /// The exact CLI version whose output produced this capture.
    let cliVersion: String
    /// The opaque account identifier this capture was read from, when one was
    /// resolved. Recorded so a later on-demand item read can be addressed to
    /// the same account instead of whichever one the CLI considers most
    /// recent — which, with two accounts signed in, need not be this one. It is
    /// an opaque identifier, never a credential.
    let accountIdentifier: String?
    let capturedAt: Date
    let vaults: [OnePasswordVault]
    let items: [OnePasswordItem]
    /// Always true. Recorded so a reader can never treat this as a lossless
    /// write source.
    let lossy: Bool

    init(
        cliVersion: String,
        accountIdentifier: String?,
        capturedAt: Date,
        vaults: [OnePasswordVault],
        items: [OnePasswordItem]
    ) {
        self.version = Self.currentVersion
        self.cliVersion = cliVersion
        self.accountIdentifier = accountIdentifier
        self.capturedAt = capturedAt
        self.vaults = vaults
        self.items = items
        self.lossy = true
    }
}

enum OnePasswordSnapshotCacheError: Error, Equatable, Sendable {
    /// The device sealing key could not be obtained (Keychain unavailable).
    case storeUnavailable
    /// The sealed blob could not be opened: wrong key, tampering, or a context
    /// that does not match the account it was sealed under.
    case corrupt
    /// The cache directory or file could not be read or written.
    case ioFailed
}

/// The durable, device-sealed cache of one 1Password account's captured
/// snapshot.
///
/// The snapshot is JSON-encoded, sealed with `CacheEnvelopeCipher` (ChaCha20-
/// Poly1305) under a device-only Keychain key, and written atomically to a
/// per-account file. The seal authenticates the account identity, so a file
/// moved into another account's or another provider's slot fails closed instead
/// of opening. This is the AEAD wrapper the research requires around lossy CLI
/// output before it ever rests; the payload is decrypted output, not 1Password
/// ciphertext, and is never used to reconstruct or retry a remote write.
///
/// Cache wrapping is provider-owned by ARCHITECTURE.md §4, so this is a sibling
/// of the Proton cache rather than a shared type. Both use the one shared
/// `CacheEnvelopeCipher`, so the cryptography itself lives in a single place.
struct OnePasswordSnapshotCache: Sendable {
    private let keyProvider: @Sendable () throws -> SymmetricKey
    private let directory: URL
    // FileManager is thread-safe for the operations used here but is not
    // Sendable; vouch for it so the cache stays Sendable.
    nonisolated(unsafe) private let fileManager: FileManager

    /// The envelope layout version, folded into the seal's authenticated data.
    /// Distinct from the other providers' version spaces; the account's
    /// provider is authenticated too, so they can never be confused.
    private static let schemaVersion = 1

    init(
        keyStore: DeviceDataKeyStore = DeviceDataKeyStore(label: "onepassword-snapshot-cache"),
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.init(
            keyProvider: {
                do {
                    return try keyStore.loadOrCreate()
                } catch DeviceDataKeyStoreError.unavailable {
                    throw OnePasswordSnapshotCacheError.storeUnavailable
                } catch {
                    throw OnePasswordSnapshotCacheError.ioFailed
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
                .appendingPathComponent("OnePasswordSnapshots", isDirectory: true)
        }
    }

    func save(_ snapshot: OnePasswordSnapshot, for account: AccountID) throws {
        let key = try sealingKey()
        let plaintext: Data
        do {
            plaintext = try JSONEncoder().encode(snapshot)
        } catch {
            throw OnePasswordSnapshotCacheError.ioFailed
        }
        let sealed = try seal(plaintext, key: key, account: account)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.writeSealed(sealed, to: fileURL(for: account))
        } catch {
            throw OnePasswordSnapshotCacheError.ioFailed
        }
    }

    /// Prefer complete file protection, falling back to a plain atomic write
    /// when an unentitled macOS build rejects the data-protection option. The
    /// payload is already AEAD-sealed, so only a redundant OS-level protection
    /// is lost, never confidentiality.
    private static func writeSealed(_ sealed: Data, to url: URL) throws {
        do {
            try sealed.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            try sealed.write(to: url, options: [.atomic])
        }
    }

    func load(for account: AccountID) throws -> OnePasswordSnapshot? {
        let url = fileURL(for: account)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let key = try sealingKey()
        let sealed: Data
        do {
            sealed = try Data(contentsOf: url)
        } catch {
            throw OnePasswordSnapshotCacheError.ioFailed
        }
        let plaintext = try open(sealed, key: key, account: account)
        do {
            return try JSONDecoder().decode(OnePasswordSnapshot.self, from: plaintext)
        } catch {
            throw OnePasswordSnapshotCacheError.corrupt
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
            throw OnePasswordSnapshotCacheError.ioFailed
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
            throw OnePasswordSnapshotCacheError.ioFailed
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
            throw OnePasswordSnapshotCacheError.corrupt
        }
    }

    private func fileURL(for account: AccountID) -> URL {
        // Hash the account identity into the filename: opaque, filesystem-safe,
        // and leaking nothing even if a raw value ever carried readable text.
        let material = "\(account.provider.rawValue)|\(account.rawValue)"
        let digest = SHA256.hash(data: Data(material.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).onepasswordcache", isDirectory: false)
    }
}
