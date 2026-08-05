import Foundation
@testable import VaultSquire

/// In-memory `EncryptedStore` for logic tests. Mirrors the atomic,
/// monotonic-generation publication semantics of the real store: a snapshot is
/// published whole or not at all, a non-advancing generation is rejected with
/// the prior snapshot left intact, and a logout wipe removes every trace of an
/// account. Records are returned in the same deterministic order (revision date,
/// then item identifier) the real store guarantees. The reauthentication marker
/// and quick-unlock key live outside the snapshot, so publishing a new snapshot
/// leaves them untouched.
final class InMemoryEncryptedStore: EncryptedStore, @unchecked Sendable {
    private final class Entry {
        var snapshot: AccountSnapshot?
        var reauthenticationRequired = false
        var quickUnlockWrappedKey: Data?
    }

    private let lock = NSLock()
    private var entries: [AccountID: Entry] = [:]

    private var _failNextPublish = false
    private var _forcedIntegrity: StoreIntegrity = .ok

    /// Test hook: when true, the next `publish` throws `.unexpected` without
    /// mutating any state, modeling an engine failure mid-commit so a test can
    /// prove the prior generation survives intact. Guarded by the same lock as
    /// the store's state so `@unchecked Sendable` holds even under TSan.
    func setFailNextPublish(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        _failNextPublish = value
    }

    /// Test hook: the result `checkIntegrity` returns, so a test can model a
    /// corrupt database without a real engine. Guarded by the store's lock.
    func setForcedIntegrity(_ value: StoreIntegrity) {
        lock.lock(); defer { lock.unlock() }
        _forcedIntegrity = value
    }

    /// Requires the lock to be held.
    private func makeEntry(for account: AccountID) -> Entry {
        if let existing = entries[account] { return existing }
        let created = Entry()
        entries[account] = created
        return created
    }

    func publish(_ snapshot: AccountSnapshot) throws {
        lock.lock(); defer { lock.unlock() }
        if Task.isCancelled { throw EncryptedStoreError.cancelled }
        if _failNextPublish {
            _failNextPublish = false
            throw EncryptedStoreError.unexpected
        }
        let entry = makeEntry(for: snapshot.account)
        if let current = entry.snapshot?.generation, snapshot.generation <= current {
            throw EncryptedStoreError.nonMonotonicGeneration(
                current: current,
                offered: snapshot.generation
            )
        }
        entry.snapshot = snapshot
    }

    func currentGeneration(for account: AccountID) throws -> SnapshotGeneration? {
        lock.lock(); defer { lock.unlock() }
        return entries[account]?.snapshot?.generation
    }

    func snapshotDate(for account: AccountID) throws -> Date? {
        lock.lock(); defer { lock.unlock() }
        return entries[account]?.snapshot?.capturedAt
    }

    func records(for account: AccountID) throws -> [EncryptedRecordRow] {
        lock.lock(); defer { lock.unlock() }
        let records = entries[account]?.snapshot?.records ?? []
        return records.sorted { lhs, rhs in
            if lhs.revisionDate != rhs.revisionDate {
                return lhs.revisionDate < rhs.revisionDate
            }
            // Tiebreak on the whole item identity, not just the raw value, so two
            // spaces that share a raw value still order deterministically.
            return Self.stableOrderingKey(lhs.itemID) < Self.stableOrderingKey(rhs.itemID)
        }
    }

    /// A fully-qualified, deterministic ordering key for a record: provider,
    /// account, space scope, then item raw value. `VaultItemID` is not
    /// `Comparable`, so the fake derives a total order here rather than cascading
    /// a `Comparable` conformance through the production identity types.
    private static func stableOrderingKey(_ id: VaultItemID) -> String {
        let scope: String
        switch id.space.scope {
        case .personal:
            scope = "personal"
        case .providerSpace(let space):
            scope = "space:\(space)"
        }
        // Length-prefix each field so a value containing the separator cannot
        // collide with a different split of the same concatenated bytes — the
        // same domain-separation the cache-envelope AAD uses.
        func lengthPrefixed(_ value: String) -> String {
            "\(value.utf8.count):\(value)"
        }
        return [
            id.account.provider.rawValue,
            id.account.rawValue,
            scope,
            id.rawValue,
        ]
        .map(lengthPrefixed)
        .joined(separator: "|")
    }

    func syncState(for account: AccountID) throws -> ProviderSyncState? {
        lock.lock(); defer { lock.unlock() }
        return entries[account]?.snapshot?.syncState
    }

    func cacheEnvelope(for scope: ProviderCacheScope) throws -> ProviderCacheEnvelope? {
        lock.lock(); defer { lock.unlock() }
        return entries[scope.account]?.snapshot?.cacheEnvelopes.first { $0.scope == scope }
    }

    func setReauthenticationRequired(_ required: Bool, for account: AccountID) throws {
        lock.lock(); defer { lock.unlock() }
        makeEntry(for: account).reauthenticationRequired = required
    }

    func reauthenticationRequired(for account: AccountID) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[account]?.reauthenticationRequired ?? false
    }

    func setQuickUnlockWrappedKey(_ wrapped: Data?, for account: AccountID) throws {
        lock.lock(); defer { lock.unlock() }
        makeEntry(for: account).quickUnlockWrappedKey = wrapped
    }

    func quickUnlockWrappedKey(for account: AccountID) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return entries[account]?.quickUnlockWrappedKey
    }

    func checkIntegrity(for account: AccountID) throws -> StoreIntegrity {
        lock.lock(); defer { lock.unlock() }
        return _forcedIntegrity
    }

    func wipe(_ account: AccountID) throws {
        lock.lock(); defer { lock.unlock() }
        entries[account] = nil
    }
}

/// An `EncryptedStore` whose every read and write reports the store as
/// unavailable, for exercising the path where the database cannot be opened or
/// keyed. `wipe` is a no-op so teardown never fails.
struct FailingEncryptedStore: EncryptedStore {
    func publish(_ snapshot: AccountSnapshot) throws {
        throw EncryptedStoreError.storeUnavailable
    }

    func currentGeneration(for account: AccountID) throws -> SnapshotGeneration? {
        throw EncryptedStoreError.storeUnavailable
    }

    func snapshotDate(for account: AccountID) throws -> Date? {
        throw EncryptedStoreError.storeUnavailable
    }

    func records(for account: AccountID) throws -> [EncryptedRecordRow] {
        throw EncryptedStoreError.storeUnavailable
    }

    func syncState(for account: AccountID) throws -> ProviderSyncState? {
        throw EncryptedStoreError.storeUnavailable
    }

    func cacheEnvelope(for scope: ProviderCacheScope) throws -> ProviderCacheEnvelope? {
        throw EncryptedStoreError.storeUnavailable
    }

    func setReauthenticationRequired(_ required: Bool, for account: AccountID) throws {
        throw EncryptedStoreError.storeUnavailable
    }

    func reauthenticationRequired(for account: AccountID) throws -> Bool {
        throw EncryptedStoreError.storeUnavailable
    }

    func setQuickUnlockWrappedKey(_ wrapped: Data?, for account: AccountID) throws {
        throw EncryptedStoreError.storeUnavailable
    }

    func quickUnlockWrappedKey(for account: AccountID) throws -> Data? {
        throw EncryptedStoreError.storeUnavailable
    }

    func checkIntegrity(for account: AccountID) throws -> StoreIntegrity {
        throw EncryptedStoreError.storeUnavailable
    }

    func wipe(_ account: AccountID) throws {}
}

/// A synthetic Vaultwarden account key for store tests. Never a real account.
let canaryStoreAccount = AccountID(provider: .vaultwarden, rawValue: "VSQ-Canary-account")

/// Builds a synthetic account snapshot from `VSQ-Canary` fixture material. Dates
/// are fixed so ordering assertions are deterministic.
func makeCanarySnapshot(
    account: AccountID = canaryStoreAccount,
    generation: UInt64,
    capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    records: [EncryptedRecordRow] = [],
    syncCursor: Data = Data("VSQ-Canary-cursor".utf8),
    cacheEnvelopes: [ProviderCacheEnvelope] = []
) -> AccountSnapshot {
    AccountSnapshot(
        account: account,
        generation: SnapshotGeneration(rawValue: generation),
        capturedAt: capturedAt,
        records: records,
        syncState: ProviderSyncState(account: account, rawValue: syncCursor),
        cacheEnvelopes: cacheEnvelopes
    )
}

/// Builds a synthetic ciphertext record row for `account`'s personal space.
func makeCanaryRecord(
    account: AccountID = canaryStoreAccount,
    itemRawValue: String,
    revisionDate: Date,
    payload: Data = Data("VSQ-Canary-ciphertext".utf8)
) -> EncryptedRecordRow {
    let space = VaultSpaceID(account: account, scope: .personal)
    return EncryptedRecordRow(
        itemID: VaultItemID(space: space, rawValue: itemRawValue),
        revisionDate: revisionDate,
        payload: payload
    )
}
