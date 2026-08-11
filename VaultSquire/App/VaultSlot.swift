import Foundation

/// What the browser is showing: everything that is open, one vault, or one
/// container inside a vault.
enum VaultScope: Hashable, Sendable {
    case allVaults
    case vault(AccountID)
    /// A container within a vault: a Proton vault (share) or a Vaultwarden
    /// folder, named by its non-secret grouping label.
    case group(AccountID, String)

    /// The vault this scope reads from, if it names one.
    var account: AccountID? {
        switch self {
        case .allVaults: return nil
        case .vault(let account): return account
        case .group(let account, _): return account
        }
    }
}

/// One container inside a vault, as the sidebar lists it.
///
/// `id` is the container's stable identity, which is deliberately not its
/// display name: a Proton account can hold two vaults called the same thing,
/// and keying on the name would merge them into one row holding both vaults'
/// items. Proton containers are keyed by the share identifier already carried
/// in every item's compound id; Vaultwarden folders are keyed by their label,
/// which is the only folder identity a projection carries.
struct VaultGroup: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let count: Int
}

/// One configured vault and whatever of it is currently open.
///
/// Each vault carries its own decrypted state, so locking one drops only that
/// vault's secrets and leaves the others open. `generation` advances on every
/// lock: an async open or sync that finishes after the user locked carries a
/// stale generation and its result is discarded, so a late result can never
/// re-open a vault the user just closed.
struct VaultSlot: Identifiable, Sendable {
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

    /// The containers inside this vault, in name order, with how many items
    /// each holds. Empty while the vault is closed, because it is derived from
    /// the open projections.
    var groups: [VaultGroup] {
        var counts: [String: Int] = [:]
        var names: [String: String] = [:]
        for item in items {
            for key in Self.groupKeys(of: item, kind: kind) {
                counts[key.id, default: 0] += 1
                names[key.id] = key.name
            }
        }
        return counts
            .map { VaultGroup(id: $0.key, name: names[$0.key] ?? $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                // Two containers can legitimately share a name; the identifier
                // keeps that order stable rather than arbitrary.
                let byName = lhs.name.localizedStandardCompare(rhs.name)
                return byName == .orderedSame ? lhs.id < rhs.id : byName == .orderedAscending
            }
    }

    /// The items in one container of this vault, matched on the same identity
    /// the sidebar row carries.
    func items(inGroup group: String) -> [VaultItemProjection] {
        items.filter { item in
            Self.groupKeys(of: item, kind: kind).contains { $0.id == group }
        }
    }

    /// The containers an item belongs to, as (identity, display name).
    ///
    /// A Proton item's container is its share, whose identifier is already part
    /// of the item's compound id — so two vaults sharing a name stay distinct.
    /// A Vaultwarden item's container is its folder, and the folder's name is
    /// the only identity the projection carries.
    private static func groupKeys(
        of item: VaultItemProjection,
        kind: Kind
    ) -> [(id: String, name: String)] {
        switch kind {
        case .proton:
            guard case .providerSpace(let shareID) = item.id.space.scope else { return [] }
            let name = item.groupingLabels.first { !$0.isEmpty } ?? shareID
            return [(shareID, name)]
        case .vaultwarden:
            return item.groupingLabels.filter { !$0.isEmpty }.map { ($0, $0) }
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
