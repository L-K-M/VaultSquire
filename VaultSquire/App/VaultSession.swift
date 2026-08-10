import Foundation

/// What the browser is showing: everything that is open, or one vault.
enum VaultScope: Hashable, Sendable {
    case allVaults
    case vault(AccountID)
}

/// One configured vault and whatever of it is currently open.
///
/// Each vault carries its own decrypted state, so locking one drops only that
/// vault's secrets and leaves the others open. `generation` advances on every
/// lock: an async open or sync that finishes after the user locked carries a
/// stale generation and its result is discarded, so a late result can never
/// re-open a vault the user just closed.
struct VaultSession: Identifiable, Sendable {
    enum Kind: Sendable, Hashable {
        case vaultwarden
        case proton
    }

    enum State: Equatable, Sendable {
        case locked
        /// An unlock or first read is in flight.
        case opening
        case open
        /// The last attempt failed; the message is shown on that vault's row.
        case failed(String)
    }

    let account: AccountID
    let kind: Kind
    /// The vault's display name in the sidebar.
    let title: String
    /// Non-secret second line: the account email, or how Proton is reached.
    let subtitle: String

    var state: State = .locked
    /// Display projections for this vault, present only while it is open.
    var items: [VaultItemProjection] = []
    var lastSyncedAt: Date?
    var syncError: String?
    var isSyncing = false
    var generation: UInt64 = 0

    /// The unlocked Vaultwarden material, held only while this vault is open.
    var vaultwarden: VaultwardenUnlockedVault?
    /// The open Proton snapshot: a lossy, device-sealed capture, never a write
    /// source.
    var proton: ProtonSnapshot?

    var id: AccountID { account }

    var isOpen: Bool {
        if case .open = state { return true }
        return false
    }

    var isOpening: Bool {
        if case .opening = state { return true }
        return false
    }

    /// Whether this provider supports mutations at all. Proton is read-only:
    /// the documented CLI has no write path that keeps private values out of
    /// argv, so no write surface exists for it.
    var isWritable: Bool { kind == .vaultwarden }

    /// The exact capabilities this vault's items carry, which the UI gates
    /// every action on. A read-only provider never gains a write capability by
    /// sitting next to a writable one in a merged list.
    var capabilities: Set<ProviderCapability> {
        switch kind {
        case .vaultwarden: return VaultwardenAccountService.capabilities
        case .proton: return ProtonReadModel.capabilities
        }
    }

    /// Drops every decrypted value and advances the generation so in-flight
    /// work for the previous open cannot publish into the closed vault.
    mutating func close() {
        state = .locked
        items = []
        vaultwarden = nil
        proton = nil
        syncError = nil
        isSyncing = false
        generation &+= 1
    }
}
