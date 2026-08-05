import Foundation

/// Result of one provider synchronization: the opaque state to present next
/// time and the snapshot generation the provider's committed snapshot carries.
struct ProviderSyncOutcome: Hashable, Sendable {
    let syncState: ProviderSyncState
    let snapshotGeneration: SnapshotGeneration
}

/// The single compiled provider facade (ADR 0002). One conforming type per
/// provider owns every provider-specific rule behind these seams — session,
/// catalog, records, sync, capabilities, and cache envelope — and shared code
/// never sees wire shapes, CLI JSON, or provider cryptography. There is
/// deliberately no protocol per conceptual seam and no universal crypto or
/// key interface.
protocol VaultProvider: Sendable {
    var providerID: ProviderID { get }

    /// Capabilities seam: exact action capabilities for an account, consumed
    /// by every UI action through `CapabilityGate`.
    func capabilities(for account: AccountID) async -> Set<ProviderCapability>

    /// Catalog seam: the user-visible spaces of an account. Provider space,
    /// share, organization, and role semantics stay behind this call.
    func spaces(for account: AccountID) async throws -> [VaultSpaceID]

    /// Records seam, read side: bounded display projections for one space.
    func listItems(in space: VaultSpaceID) async throws -> [VaultItemProjection]

    /// Records seam, write side: performs a mutation that already passed the
    /// capability gate. The authorization is the only path in; a provider
    /// must not offer another mutation entry point.
    func perform(_ authorization: CapabilityAuthorization) async throws

    /// Sync seam: publish a validated snapshot from opaque prior state.
    func synchronize(
        for account: AccountID,
        from state: ProviderSyncState?
    ) async throws -> ProviderSyncOutcome

    /// Cache-envelope seam: provider state at rest with explicit fidelity.
    func cacheEnvelope(for scope: ProviderCacheScope) async throws -> ProviderCacheEnvelope
}
