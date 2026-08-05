import Foundation

/// One provider-native ciphertext record persisted at rest. The payload is
/// opaque to shared code and preserved byte for byte, exactly like a cache
/// envelope's payload; the store never decrypts it, and a plaintext name,
/// username, URI, or note never becomes a column. The revision date is the one
/// non-secret projection the store may read, so a locked snapshot can be
/// hydrated in a deterministic order without decrypting anything.
struct EncryptedRecordRow: Hashable, Sendable {
    /// The compound local key: provider, account, space, and item.
    let itemID: VaultItemID
    /// A non-secret ordering token — the provider's revision date for the item.
    /// It is metadata, never a secret, and exists only so records sort
    /// deterministically without touching ciphertext.
    let revisionDate: Date
    /// Provider-native ciphertext, opaque and byte-preserved.
    let payload: Data

    init(itemID: VaultItemID, revisionDate: Date, payload: Data) {
        self.itemID = itemID
        self.revisionDate = revisionDate
        self.payload = payload
    }
}

/// A complete candidate snapshot for one account, staged for atomic publication.
/// A sync builds one of these entirely, and the store publishes it in a single
/// transaction: either the whole snapshot becomes the account's current
/// generation, or nothing changes. A partial or interleaved generation is never
/// observable.
struct AccountSnapshot: Hashable, Sendable {
    let account: AccountID
    /// The monotonic generation this snapshot publishes. The store rejects a
    /// generation that does not strictly advance the account's current one.
    let generation: SnapshotGeneration
    /// When the snapshot's sync completed. Recorded in the same transaction as
    /// the generation, never separately.
    let capturedAt: Date
    /// The provider-native ciphertext rows, in any order; the store persists
    /// them and returns them in deterministic order on read.
    let records: [EncryptedRecordRow]
    /// Opaque provider sync cursor to resume from next time.
    let syncState: ProviderSyncState
    /// The at-rest cache envelopes for this account — the lossless native
    /// provider envelope and any lossy application-encrypted snapshot — kept as
    /// an explicit blob boundary so a lossy payload can never be flattened into
    /// the record rows.
    let cacheEnvelopes: [ProviderCacheEnvelope]

    init(
        account: AccountID,
        generation: SnapshotGeneration,
        capturedAt: Date,
        records: [EncryptedRecordRow],
        syncState: ProviderSyncState,
        cacheEnvelopes: [ProviderCacheEnvelope]
    ) {
        self.account = account
        self.generation = generation
        self.capturedAt = capturedAt
        self.records = records
        self.syncState = syncState
        self.cacheEnvelopes = cacheEnvelopes
    }
}

/// The result of an at-rest integrity diagnostic. The real store derives it from
/// a keyed integrity check; the seam exposes it so callers can detect a corrupt
/// or unreadable database and rebuild from the provider rather than presenting
/// wrong data.
enum StoreIntegrity: Hashable, Sendable {
    case ok
    case corrupt(reason: String)
}

enum EncryptedStoreError: Error, Equatable, Sendable {
    /// The store could not be opened or keyed in this environment.
    case storeUnavailable
    /// A snapshot was published whose generation does not strictly advance the
    /// account's current generation. The prior snapshot is left intact.
    case nonMonotonicGeneration(current: SnapshotGeneration, offered: SnapshotGeneration)
    /// A stored record or marker could not be decoded.
    case malformedRecord
    /// The database failed an integrity check and must be rebuilt from the
    /// provider before use.
    case corrupt(reason: String)
    /// The operation's task was cancelled before it committed; nothing was
    /// written.
    case cancelled
    /// An unexpected backing-store failure.
    case unexpected
}

/// The at-rest store for one installation's encrypted account data
/// (ARCHITECTURE `EncryptedStore`). It persists provider-native ciphertext rows,
/// opaque provider sync state, cache envelopes, the durable reauthentication
/// marker, and the quick-unlock wrapped user key, and it commits the snapshot
/// generation and its date inside the same transaction as the data they
/// describe. It must never store a decrypted name, username, URI, note, or
/// search term.
///
/// The real implementation is GRDB over SQLCipher, backed by a device-only
/// Keychain database key; that binary adoption is the separately reviewed
/// storage spike (`docs/dependencies/storage.md`, ADR 0003) and is deliberately
/// not part of this seam. An in-memory implementation backs the logic tests and
/// mirrors these semantics.
///
/// Publication rule: `publish(_:)` either makes the offered snapshot the
/// account's whole current generation or leaves the prior generation intact. A
/// failed, cancelled, or non-advancing publish never replaces a usable snapshot
/// with a partial or empty one.
///
/// Concurrency: the read-then-write inside `publish` is not atomic across
/// callers, so writes for one account must be serialized by the caller, exactly
/// as `VaultwardenCredentialStore` requires.
protocol EncryptedStore: Sendable {
    /// Atomically publishes a candidate snapshot as the account's new current
    /// generation. Throws `nonMonotonicGeneration` (leaving the prior snapshot
    /// intact) when the offered generation does not strictly advance the current
    /// one, and `cancelled` if the calling task was cancelled before the commit.
    func publish(_ snapshot: AccountSnapshot) throws

    /// The account's current snapshot generation, or `nil` if none is stored.
    func currentGeneration(for account: AccountID) throws -> SnapshotGeneration?

    /// When the account's current snapshot was captured, or `nil` if none is
    /// stored.
    func snapshotDate(for account: AccountID) throws -> Date?

    /// The account's persisted ciphertext rows in deterministic storage order
    /// (revision date, then item identifier), so a locked hydration is stable
    /// without decrypting anything. Empty when no snapshot is stored.
    func records(for account: AccountID) throws -> [EncryptedRecordRow]

    /// The opaque provider sync state to resume from, or `nil` if none.
    func syncState(for account: AccountID) throws -> ProviderSyncState?

    /// The stored cache envelope for a scope, or `nil` if none.
    func cacheEnvelope(for scope: ProviderCacheScope) throws -> ProviderCacheEnvelope?

    /// Persists (or clears, when `required` is false) the durable
    /// reauthentication-required marker for an account WITHOUT disturbing the
    /// stored snapshot, generation, sync state, cache envelopes, or quick-unlock
    /// key, so a rotation can require reauthentication while the prior snapshot
    /// stays presentable.
    func setReauthenticationRequired(_ required: Bool, for account: AccountID) throws

    /// Whether the account is marked as requiring reauthentication.
    func reauthenticationRequired(for account: AccountID) throws -> Bool

    /// Stores (or clears, when `nil`) the AEAD-wrapped quick-unlock user key for
    /// an account. The wrapped key is opaque bytes; the store never holds the
    /// wrapping key, which lives device-only in the Keychain.
    func setQuickUnlockWrappedKey(_ wrapped: Data?, for account: AccountID) throws

    /// The AEAD-wrapped quick-unlock user key for an account, or `nil` if none.
    func quickUnlockWrappedKey(for account: AccountID) throws -> Data?

    /// Reports whether the account's database passes an at-rest integrity check.
    func checkIntegrity(for account: AccountID) throws -> StoreIntegrity

    /// Removes every persisted trace of an account — records, sync state, cache
    /// envelopes, reauthentication marker, quick-unlock key, generation, and
    /// date — so a logout leaves no account credential or cache key behind.
    func wipe(_ account: AccountID) throws
}
