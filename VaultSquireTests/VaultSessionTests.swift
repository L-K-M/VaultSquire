import XCTest
@testable import VaultSquire

final class VaultSessionTests: XCTestCase {
    private let account = AccountID(
        provider: FakeVaultProvider.providerID,
        rawValue: "account-1"
    )

    private var space: VaultSpaceID {
        VaultSpaceID(account: account, scope: .personal)
    }

    private func makeAuthenticatedSession() async throws -> VaultSession {
        let session = VaultSession()
        try await session.beginAuthentication()
        try await session.completeAuthentication()
        return session
    }

    private func makeProjection(_ rawValue: String) -> VaultItemProjection {
        VaultItemProjection(
            id: VaultItemID(space: space, rawValue: rawValue),
            displayTitle: "Title \(rawValue)",
            displaySubtitle: nil,
            category: .login,
            username: nil,
            websites: [],
            groupingLabels: [],
            capabilities: [.viewItems],
            cacheReference: ProviderCacheReference(
                scope: .wholeAccount(account),
                captureGeneration: SnapshotGeneration(rawValue: 1)
            )
        )
    }

    // MARK: Generations

    func testEachUnlockIssuesANewGeneration() async throws {
        let session = try await makeAuthenticatedSession()

        let first = try await session.beginUnlock()
        await session.completeUnlock(first)
        await session.lock()
        let second = try await session.beginUnlock()

        XCTAssertNotEqual(first, second)
    }

    func testCompletingUnlockWithCurrentGenerationSucceeds() async throws {
        let session = try await makeAuthenticatedSession()

        let generation = try await session.beginUnlock()
        let accepted = await session.completeUnlock(generation)

        XCTAssertTrue(accepted)
        let state = await session.state
        XCTAssertEqual(state.vaultAccess, .unlocked(generation))
    }

    func testLockDuringUnlockingDiscardsTheLateCompletion() async throws {
        let session = try await makeAuthenticatedSession()

        let generation = try await session.beginUnlock()
        await session.lock()
        let accepted = await session.completeUnlock(generation)

        XCTAssertFalse(accepted)
        let state = await session.state
        XCTAssertEqual(state.vaultAccess, .locked)
    }

    func testGenerationInvalidatedByLockStaysInvalidAfterReUnlock() async throws {
        let session = try await makeAuthenticatedSession()

        let stale = try await session.beginUnlock()
        await session.lock()
        let current = try await session.beginUnlock()

        let staleAccepted = await session.completeUnlock(stale)
        let currentAccepted = await session.completeUnlock(current)

        XCTAssertFalse(staleAccepted)
        XCTAssertTrue(currentAccepted)
    }

    // MARK: Late publication

    func testPublishWithCurrentGenerationPublishes() async throws {
        let session = try await makeAuthenticatedSession()
        let generation = try await session.beginUnlock()
        await session.completeUnlock(generation)

        let accepted = await session.publish(
            [makeProjection("item-1")],
            generation: generation
        )

        XCTAssertTrue(accepted)
        let published = await session.projectedItems
        XCTAssertEqual(published.map(\.id.rawValue), ["item-1"])
    }

    func testLockDuringInFlightDecryptLeavesNothingPublished() async throws {
        let session = try await makeAuthenticatedSession()
        let generation = try await session.beginUnlock()
        await session.completeUnlock(generation)

        let provider = FakeVaultProvider()
        await provider.setItems([makeProjection("item-1")], in: space)
        await provider.beginHoldingListItems()

        let providerSpace = space
        let inFlight = Task {
            let items = (try? await provider.listItems(in: providerSpace)) ?? []
            _ = await session.publish(items, generation: generation)
        }

        await provider.waitUntilListItemsHeld()
        await session.lock()
        await provider.releaseHeldListItems()
        await inFlight.value

        let published = await session.projectedItems
        let state = await session.state
        XCTAssertEqual(published, [])
        XCTAssertEqual(state.vaultAccess, .locked)
    }

    func testLockClearsPreviouslyPublishedProjections() async throws {
        let session = try await makeAuthenticatedSession()
        let generation = try await session.beginUnlock()
        await session.completeUnlock(generation)
        await session.publish([makeProjection("item-1")], generation: generation)

        await session.lock()

        let published = await session.projectedItems
        XCTAssertEqual(published, [])
    }

    // MARK: Cancellation

    func testLockCancelsRegisteredWork() async throws {
        let session = try await makeAuthenticatedSession()
        let generation = try await session.beginUnlock()
        await session.completeUnlock(generation)

        let observedCancellation = expectation(
            description: "registered work observed cancellation"
        )
        let work = Task {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                observedCancellation.fulfill()
            }
        }
        _ = await session.register(work)

        await session.lock()

        await fulfillment(of: [observedCancellation], timeout: 5)
        await work.value
    }

    func testUnregisteredWorkIsNotCancelledByLock() async throws {
        let session = try await makeAuthenticatedSession()

        let work = Task {
            _ = try? await Task.sleep(for: .milliseconds(10))
        }
        let token = await session.register(work)
        await session.unregister(token)

        await session.lock()
        await work.value

        XCTAssertFalse(work.isCancelled)
    }

    // MARK: Transition validity

    func testUnlockRequiresAnAuthenticatedAccount() async {
        let session = VaultSession()

        do {
            _ = try await session.beginUnlock()
            XCTFail("Unlock must not begin with no account")
        } catch {
            XCTAssertEqual(error as? VaultSessionError, .invalidTransition)
        }
    }

    func testUnlockWhileUnlockingIsRejected() async throws {
        let session = try await makeAuthenticatedSession()
        _ = try await session.beginUnlock()

        do {
            _ = try await session.beginUnlock()
            XCTFail("A second unlock attempt must be rejected while one runs")
        } catch {
            XCTAssertEqual(error as? VaultSessionError, .invalidTransition)
        }
    }

    func testReauthenticationRequiredStillPermitsCacheUnlock() async throws {
        let session = try await makeAuthenticatedSession()
        try await session.requireReauthentication()

        let generation = try await session.beginUnlock()
        let accepted = await session.completeUnlock(generation)

        XCTAssertTrue(accepted)
    }

    func testCancelledReauthenticationReturnsToReauthenticationRequired() async throws {
        let session = try await makeAuthenticatedSession()
        try await session.requireReauthentication()
        try await session.beginAuthentication()

        try await session.cancelAuthentication()

        let state = await session.state
        XCTAssertEqual(state.account, .reauthenticationRequired)
    }

    func testReauthenticationRestartedAtChallengeKeepsItsOrigin() async throws {
        let session = try await makeAuthenticatedSession()
        try await session.requireReauthentication()
        try await session.beginAuthentication()
        try await session.presentChallenge()
        try await session.beginAuthentication()

        try await session.cancelAuthentication()

        let state = await session.state
        XCTAssertEqual(state.account, .reauthenticationRequired)
    }

    func testCancelledFirstAuthenticationReturnsToNoAccount() async throws {
        let session = VaultSession()
        try await session.beginAuthentication()
        try await session.presentChallenge()

        try await session.cancelAuthentication()

        let state = await session.state
        XCTAssertEqual(state.account, .noAccount)
    }

    func testLogoutLocksAndClearsBeforeCompleting() async throws {
        let session = try await makeAuthenticatedSession()
        let generation = try await session.beginUnlock()
        await session.completeUnlock(generation)
        await session.publish([makeProjection("item-1")], generation: generation)

        try await session.beginLogout()
        let midLogout = await session.state
        XCTAssertEqual(midLogout.account, .loggingOut)
        XCTAssertEqual(midLogout.vaultAccess, .locked)

        try await session.completeLogout()

        let state = await session.state
        let published = await session.projectedItems
        XCTAssertEqual(state.account, .noAccount)
        XCTAssertEqual(published, [])
    }

    func testLockIsIdempotent() async throws {
        let session = try await makeAuthenticatedSession()

        await session.lock()
        await session.lock()

        let state = await session.state
        XCTAssertEqual(state.vaultAccess, .locked)
    }

    // MARK: Sync dimension

    func testSyncTransitionsCarryTheCandidateSnapshotGeneration() async throws {
        let session = try await makeAuthenticatedSession()
        let candidate = SnapshotGeneration(rawValue: 7)

        try await session.beginSyncCheck()
        try await session.beginSyncApply(candidate: candidate)

        let syncing = await session.state
        XCTAssertEqual(syncing.syncOperation, .syncing(candidate))

        try await session.completeSync()
        let idle = await session.state
        XCTAssertEqual(idle.syncOperation, .idle)
    }

    func testSyncProceedsWhileLocked() async throws {
        let session = try await makeAuthenticatedSession()
        await session.lock()

        try await session.beginSyncCheck()
        try await session.beginSyncApply(candidate: SnapshotGeneration(rawValue: 2))
        try await session.completeSync()

        let state = await session.state
        XCTAssertEqual(state.vaultAccess, .locked)
        XCTAssertEqual(state.syncOperation, .idle)
    }

    func testLogoutResetsInFlightSyncState() async throws {
        let session = try await makeAuthenticatedSession()
        try await session.beginSyncCheck()
        try await session.beginSyncApply(candidate: SnapshotGeneration(rawValue: 3))

        try await session.beginLogout()
        try await session.completeLogout()

        let state = await session.state
        XCTAssertEqual(state.syncOperation, .idle)
        XCTAssertEqual(state.account, .noAccount)
        XCTAssertEqual(state.vaultAccess, .locked)
    }

    func testSyncFailureRequiresExplicitClearing() async throws {
        let session = try await makeAuthenticatedSession()

        try await session.beginSyncCheck()
        try await session.failSync()

        do {
            try await session.beginSyncApply(candidate: SnapshotGeneration(rawValue: 1))
            XCTFail("Sync apply must not begin from a failed state")
        } catch {
            XCTAssertEqual(error as? VaultSessionError, .invalidTransition)
        }

        try await session.clearSyncFailure()
        let state = await session.state
        XCTAssertEqual(state.syncOperation, .idle)
    }
}
