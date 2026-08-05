import Foundation

/// Discards late plaintext results. `VaultSession` increments it on every
/// unlock and every lock; it exists only while the vault is unlocked or
/// unlocking. It is deliberately not `Comparable` and not `Codable`: the only
/// valid question is whether a result's generation is exactly the current one,
/// and it never survives the process.
struct SessionGeneration: Hashable, Sendable {
    let rawValue: UInt64
}

/// Identifies which complete encrypted snapshot is current for an account.
/// It is committed inside each sync transaction, survives lock and
/// logout-free restarts, and advances while the app is locked when ciphertext
/// sync continues. It must never be conflated with `SessionGeneration`, which
/// is why the two are distinct types.
struct SnapshotGeneration: Hashable, Sendable, Codable, Comparable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    static func < (lhs: SnapshotGeneration, rhs: SnapshotGeneration) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Account dimension of the orthogonal session state.
enum AccountState: Hashable, Sendable {
    case noAccount
    case authenticating
    case challenged
    case authenticated
    case reauthenticationRequired
    case loggingOut
}

/// Vault-access dimension of the orthogonal session state.
enum VaultAccessState: Hashable, Sendable {
    case locked
    case unlocking(SessionGeneration)
    case unlocked(SessionGeneration)
    case locking
}

/// Connectivity dimension of the orthogonal session state.
enum ConnectivityState: Hashable, Sendable {
    case offline
    case online
}

/// Sync-operation dimension of the orthogonal session state. The associated
/// value is the candidate snapshot generation a running sync is building, not
/// a session generation.
enum SyncOperationState: Hashable, Sendable {
    case idle
    case checking
    case syncing(SnapshotGeneration)
    case failed
}

/// Immutable snapshot of the four coordinated session dimensions. There is
/// deliberately no single enum containing every combination; transitions are
/// serialized by `VaultSession`.
struct VaultSessionState: Hashable, Sendable {
    var account: AccountState
    var vaultAccess: VaultAccessState
    var connectivity: ConnectivityState
    var syncOperation: SyncOperationState

    static let initial = VaultSessionState(
        account: .noAccount,
        vaultAccess: .locked,
        connectivity: .offline,
        syncOperation: .idle
    )
}
