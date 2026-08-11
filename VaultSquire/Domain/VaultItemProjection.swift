import Foundation

/// Canonical item category used only where a lossless mapping from the
/// provider's own kind exists. Anything else stays visible as unsupported
/// instead of being coerced into a nearby category.
enum VaultItemCategory: Hashable, Sendable {
    case login
    case secureNote
    case card
    case identity
    case unsupported
}

/// Stable reference from a projection row back to the provider cache envelope
/// it was built from.
struct ProviderCacheReference: Hashable, Sendable {
    let scope: ProviderCacheScope
    let captureGeneration: SnapshotGeneration
}

/// One provider container an item belongs to. Identity and display text are
/// deliberately separate: two folders or vaults may share a name without
/// becoming one scope in the sidebar.
struct VaultItemGrouping: Hashable, Sendable {
    let id: String
    let name: String
}

/// The narrow immutable projection shared UI and search may consume. It
/// carries display fields, non-secret labels, and exact action capabilities —
/// nothing more. Secrets, provider wire shapes, and unknown fields remain
/// inside the provider cache envelope the reference points back to.
struct VaultItemProjection: Hashable, Sendable, Identifiable {
    let id: VaultItemID
    let displayTitle: String
    let displaySubtitle: String?
    let category: VaultItemCategory
    let username: String?
    let websites: [String]
    /// Non-secret folder, collection, vault, or share identities and labels;
    /// empty when a provider has no such grouping.
    let groupings: [VaultItemGrouping]
    var groupingLabels: [String] { groupings.map(\.name) }
    let capabilities: Set<ProviderCapability>
    let cacheReference: ProviderCacheReference
}
