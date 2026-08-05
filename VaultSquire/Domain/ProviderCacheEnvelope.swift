import Foundation

/// What the payload of a cache envelope preserves. Vaultwarden retains native
/// ciphertext byte for byte; Proton CLI snapshots are decrypted, lossy output
/// wrapped by a VaultSquire AEAD before they ever rest. The label is explicit
/// so lossy data can never be mistaken for a lossless write source.
enum CacheFidelity: Hashable, Sendable {
    case losslessNativeCiphertext
    case lossyApplicationEncrypted

    var isLossy: Bool {
        self == .lossyApplicationEncrypted
    }
}

/// The account- or space-level extent one envelope covers.
enum ProviderCacheScope: Hashable, Sendable {
    case wholeAccount(AccountID)
    case space(VaultSpaceID)

    var account: AccountID {
        switch self {
        case .wholeAccount(let account):
            return account
        case .space(let space):
            return space.account
        }
    }
}

/// At-rest container for provider state. The payload is opaque to shared code
/// and is preserved byte for byte, including fields no VaultSquire version
/// understands. The envelope performs no cryptography itself; the payload
/// arrives already protected (provider-native ciphertext or an application
/// AEAD wrapper supplied by the persistence workstream).
struct ProviderCacheEnvelope: Hashable, Sendable {
    let scope: ProviderCacheScope
    let fidelity: CacheFidelity
    /// Version of the envelope's own layout, so later migrations can tell
    /// which rules produced a stored envelope.
    let schemaVersion: Int
    /// The snapshot generation whose sync produced this payload.
    let captureGeneration: SnapshotGeneration
    let payload: Data

    var account: AccountID {
        scope.account
    }
}

/// Opaque provider sync state. Shared code stores and returns it without
/// interpretation: a cursor is not a timestamp, and no cross-provider meaning
/// exists.
struct ProviderSyncState: Hashable, Sendable {
    let account: AccountID
    let rawValue: Data

    init(account: AccountID, rawValue: Data) {
        self.account = account
        self.rawValue = rawValue
    }
}
