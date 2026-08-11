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
        self.items = items.map(\.withoutSecretContent)
        self.lossy = true
    }

    /// Rebuilds a decoded legacy payload through the invariant-preserving
    /// initializer. This strips any password, TOTP seed, or note an older build
    /// may have admitted before the value can reach an open session again.
    var withoutSecretContent: ProtonSnapshot {
        ProtonSnapshot(
            cliVersion: cliVersion,
            capturedAt: capturedAt,
            vaults: vaults,
            items: items
        )
    }

    var isStructurallyValid: Bool {
        guard version == Self.currentVersion, lossy,
              !cliVersion.isEmpty,
              Self.isDisplayString(cliVersion, maximumBytes: 128),
              capturedAt.timeIntervalSince1970.isFinite,
              vaults.count <= 50, items.count <= 100_000,
              Self.hasBoundedContent(vaults: vaults, items: items),
              items.allSatisfy({ $0.password == nil && $0.totp == nil && $0.note == nil }) else {
            return false
        }
        let shareIDs = vaults.map(\.shareID)
        let itemIDs = items.map { "\($0.shareID)|\($0.itemID)" }
        let shareIDSet = Set(shareIDs)
        guard shareIDSet.count == shareIDs.count,
              Set(itemIDs).count == itemIDs.count,
              items.allSatisfy({ shareIDSet.contains($0.shareID) }) else {
            return false
        }
        return vaults.allSatisfy {
            ProtonCLIRunner.isValidOpaqueIdentifier($0.shareID)
                && $0.vaultID.map(ProtonCLIRunner.isValidOpaqueIdentifier) != false
                && Self.isDisplayString($0.name)
        } && items.allSatisfy {
            ProtonCLIRunner.isValidOpaqueIdentifier($0.itemID)
                && ProtonCLIRunner.isValidOpaqueIdentifier($0.shareID)
                && Self.isDisplayString($0.vaultName)
                && Self.isDisplayString($0.title)
                && $0.username.map(Self.isDisplayString) != false
                && $0.urls.count <= 100
                && $0.urls.allSatisfy { Self.isDisplayString($0, maximumBytes: 2_048) }
        }
    }

    private static func hasBoundedContent(
        vaults: [ProtonVault],
        items: [ProtonItem]
    ) -> Bool {
        var total = 0
        func add(_ value: String?) -> Bool {
            guard let value else { return true }
            let (next, overflow) = total.addingReportingOverflow(value.utf8.count)
            guard !overflow, next <= 4 * 1024 * 1024 else { return false }
            total = next
            return true
        }
        for vault in vaults {
            guard add(vault.shareID), add(vault.vaultID), add(vault.name) else { return false }
        }
        for item in items {
            guard add(item.itemID), add(item.shareID), add(item.vaultName),
                  add(item.title), add(item.username),
                  item.urls.allSatisfy({ add($0) }) else {
                return false
            }
        }
        return true
    }

    private static func isDisplayString(
        _ value: String,
        maximumBytes: Int = 4_096
    ) -> Bool {
        value.utf8.count <= maximumBytes
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
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
    private let directory: URL?
    // FileManager is thread-safe for the operations used here but is not
    // Sendable; vouch for it so the cache stays Sendable.
    nonisolated(unsafe) private let fileManager: FileManager

    /// The envelope layout version, folded into the seal's authenticated data.
    /// Distinct from the Vaultwarden cache's version space; the account's
    /// provider is authenticated too, so the two can never be confused.
    private static let schemaVersion = 1
    private static let maximumSealedBytes = 8 * 1024 * 1024

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
            self.directory = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: "group.ch.lkmc.VaultSquire"
            )?.appendingPathComponent("ProtonSnapshots", isDirectory: true)
        }
    }

    func save(_ snapshot: ProtonSnapshot, for account: AccountID) throws {
        guard let directory else { throw ProtonSnapshotCacheError.storeUnavailable }
        let sanitized = snapshot.withoutSecretContent
        guard sanitized.isStructurallyValid else { throw ProtonSnapshotCacheError.corrupt }
        let key = try sealingKey()
        var plaintext: Data
        do {
            plaintext = try JSONEncoder().encode(sanitized)
        } catch {
            throw ProtonSnapshotCacheError.ioFailed
        }
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        guard plaintext.count <= Self.maximumSealedBytes else {
            throw ProtonSnapshotCacheError.ioFailed
        }
        let sealed = try seal(plaintext, key: key, account: account)
        guard sealed.count <= Self.maximumSealedBytes else {
            throw ProtonSnapshotCacheError.ioFailed
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.writeSealed(sealed, to: fileURL(for: account, directory: directory))
        } catch {
            throw ProtonSnapshotCacheError.ioFailed
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

    func load(for account: AccountID) throws -> ProtonSnapshot? {
        guard let directory else { throw ProtonSnapshotCacheError.storeUnavailable }
        let url = fileURL(for: account, directory: directory)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let key = try sealingKey()
        let sealed: Data
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.intValue > 0,
                  size.intValue <= Self.maximumSealedBytes else {
                throw ProtonSnapshotCacheError.corrupt
            }
            sealed = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch let error as ProtonSnapshotCacheError {
            throw error
        } catch {
            throw ProtonSnapshotCacheError.ioFailed
        }
        var plaintext = try open(sealed, key: key, account: account)
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        guard plaintext.count <= Self.maximumSealedBytes else {
            throw ProtonSnapshotCacheError.corrupt
        }
        do {
            let decoded = try JSONDecoder().decode(ProtonSnapshot.self, from: plaintext)
            let sanitized = decoded.withoutSecretContent
            guard sanitized.isStructurallyValid else {
                throw ProtonSnapshotCacheError.corrupt
            }
            return sanitized
        } catch let error as ProtonSnapshotCacheError {
            throw error
        } catch {
            throw ProtonSnapshotCacheError.corrupt
        }
    }

    func exists(for account: AccountID) -> Bool {
        guard let directory else { return false }
        return fileManager.fileExists(atPath: fileURL(for: account, directory: directory).path)
    }

    func wipe(for account: AccountID) throws {
        guard let directory else { throw ProtonSnapshotCacheError.storeUnavailable }
        let url = fileURL(for: account, directory: directory)
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

    private func fileURL(for account: AccountID, directory: URL) -> URL {
        // Hash the account identity into the filename: opaque, filesystem-safe,
        // and leaking nothing even if a raw value ever carried readable text.
        let material = "\(account.provider.rawValue)|\(account.rawValue)"
        let digest = SHA256.hash(data: Data(material.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).protoncache", isDirectory: false)
    }
}
