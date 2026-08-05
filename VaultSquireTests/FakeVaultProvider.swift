import Foundation
@testable import VaultSquire

/// Test-only provider facade. It proves state, cancellation, capability, and
/// unknown-field behavior before either production provider exists, and it
/// never leaves the test target.
actor FakeVaultProvider: VaultProvider {
    static let providerID = ProviderID(rawValue: "test-fake")

    nonisolated var providerID: ProviderID {
        Self.providerID
    }

    private var accountCapabilities: [AccountID: Set<ProviderCapability>] = [:]
    private var spacesByAccount: [AccountID: [VaultSpaceID]] = [:]
    private var itemsBySpace: [VaultSpaceID: [VaultItemProjection]] = [:]
    private var envelopesByScope: [ProviderCacheScope: ProviderCacheEnvelope] = [:]
    private var syncOutcome: ProviderSyncOutcome?

    private(set) var performedMutations: [CapabilityAuthorization] = []
    private(set) var receivedSyncStates: [ProviderSyncState?] = []

    /// When set, `listItems` suspends until `releaseHeldListItems` runs, so a
    /// test can lock the session while a plaintext-producing read is in
    /// flight.
    private var holdListItems = false
    private var heldListContinuations: [CheckedContinuation<Void, Never>] = []
    private var holdArrivalWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: Configuration

    func setCapabilities(
        _ capabilities: Set<ProviderCapability>,
        for account: AccountID
    ) {
        accountCapabilities[account] = capabilities
    }

    func setSpaces(_ spaces: [VaultSpaceID], for account: AccountID) {
        spacesByAccount[account] = spaces
    }

    func setItems(_ items: [VaultItemProjection], in space: VaultSpaceID) {
        itemsBySpace[space] = items
    }

    func setEnvelope(_ envelope: ProviderCacheEnvelope) {
        envelopesByScope[envelope.scope] = envelope
    }

    func setSyncOutcome(_ outcome: ProviderSyncOutcome) {
        syncOutcome = outcome
    }

    func beginHoldingListItems() {
        holdListItems = true
    }

    /// Suspends until at least one `listItems` caller is parked on the hold,
    /// so a test can deterministically act while the read is in flight.
    /// Returns immediately when no hold is active, because no reader could
    /// ever park and waiting would deadlock the test.
    func waitUntilListItemsHeld() async {
        guard heldListContinuations.isEmpty else {
            return
        }
        guard holdListItems else {
            return
        }

        await withCheckedContinuation { continuation in
            holdArrivalWaiters.append(continuation)
        }
    }

    func releaseHeldListItems() {
        holdListItems = false
        let continuations = heldListContinuations
        heldListContinuations = []
        for continuation in continuations {
            continuation.resume()
        }
        // Also release arrival waiters so a misordered release can never
        // leave a test parked forever waiting for a reader that already ran
        // or will never come.
        let waiters = holdArrivalWaiters
        holdArrivalWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    // MARK: VaultProvider

    func capabilities(for account: AccountID) async -> Set<ProviderCapability> {
        accountCapabilities[account] ?? []
    }

    func spaces(for account: AccountID) async throws -> [VaultSpaceID] {
        spacesByAccount[account] ?? []
    }

    func listItems(in space: VaultSpaceID) async throws -> [VaultItemProjection] {
        if holdListItems {
            await withCheckedContinuation { continuation in
                heldListContinuations.append(continuation)
                let waiters = holdArrivalWaiters
                holdArrivalWaiters = []
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }

        return itemsBySpace[space] ?? []
    }

    func perform(_ authorization: CapabilityAuthorization) async throws {
        performedMutations.append(authorization)
    }

    func synchronize(
        for account: AccountID,
        from state: ProviderSyncState?
    ) async throws -> ProviderSyncOutcome {
        receivedSyncStates.append(state)
        guard let syncOutcome else {
            return ProviderSyncOutcome(
                syncState: ProviderSyncState(account: account, rawValue: Data()),
                snapshotGeneration: SnapshotGeneration(rawValue: 1)
            )
        }

        return syncOutcome
    }

    func cacheEnvelope(
        for scope: ProviderCacheScope
    ) async throws -> ProviderCacheEnvelope {
        guard let envelope = envelopesByScope[scope] else {
            throw FakeVaultProviderError.missingEnvelope
        }

        return envelope
    }
}

enum FakeVaultProviderError: Error, Equatable, Sendable {
    case missingEnvelope
}
