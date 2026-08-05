import XCTest
@testable import VaultSquire

final class ProviderCacheEnvelopeTests: XCTestCase {
    private let account = AccountID(
        provider: FakeVaultProvider.providerID,
        rawValue: "account-1"
    )

    func testFidelityLabelsAreExplicit() {
        XCTAssertFalse(CacheFidelity.losslessNativeCiphertext.isLossy)
        XCTAssertTrue(CacheFidelity.lossyApplicationEncrypted.isLossy)
    }

    func testEnvelopePayloadIsPreservedByteForByte() async throws {
        // Synthetic payload with keys no VaultSquire version understands; the
        // envelope must hand back exactly the bytes it was given.
        let unknownFieldPayload = Data(
            #"{"known":"value","unknownField":{"nested":[1,2,3]},"za_x":"?"}"#
                .utf8
        )
        let scope = ProviderCacheScope.wholeAccount(account)
        let envelope = ProviderCacheEnvelope(
            scope: scope,
            fidelity: .losslessNativeCiphertext,
            schemaVersion: 1,
            captureGeneration: SnapshotGeneration(rawValue: 3),
            payload: unknownFieldPayload
        )

        let provider = FakeVaultProvider()
        await provider.setEnvelope(envelope)
        let returned = try await provider.cacheEnvelope(for: scope)

        XCTAssertEqual(returned.payload, unknownFieldPayload)
        XCTAssertEqual(returned, envelope)
        XCTAssertEqual(returned.account, account)
    }

    func testSpaceScopedEnvelopeKeepsItsSpaceIdentity() async throws {
        let space = VaultSpaceID(
            account: account,
            scope: .providerSpace("share-1")
        )
        let envelope = ProviderCacheEnvelope(
            scope: .space(space),
            fidelity: .lossyApplicationEncrypted,
            schemaVersion: 1,
            captureGeneration: SnapshotGeneration(rawValue: 1),
            payload: Data([0x00, 0xFF, 0x10])
        )

        let provider = FakeVaultProvider()
        await provider.setEnvelope(envelope)
        let returned = try await provider.cacheEnvelope(for: .space(space))

        XCTAssertEqual(returned.scope, .space(space))
        XCTAssertTrue(returned.fidelity.isLossy)
        XCTAssertEqual(returned.account, account)
    }

    // The fake provider records received states and returns a configured
    // outcome; this proves the state is stored and handed back untouched, not
    // that any provider processes it.
    func testSyncStateIsOpaqueAndPreserved() async throws {
        let provider = FakeVaultProvider()
        let opaque = Data([0x01, 0x02, 0xFE])
        let outcome = ProviderSyncOutcome(
            syncState: ProviderSyncState(account: account, rawValue: opaque),
            snapshotGeneration: SnapshotGeneration(rawValue: 9)
        )
        await provider.setSyncOutcome(outcome)

        let first = try await provider.synchronize(for: account, from: nil)
        let second = try await provider.synchronize(
            for: account,
            from: first.syncState
        )

        XCTAssertEqual(first.syncState.rawValue, opaque)
        XCTAssertEqual(second.snapshotGeneration, SnapshotGeneration(rawValue: 9))
        let received = await provider.receivedSyncStates
        XCTAssertEqual(received, [nil, first.syncState])
    }

    func testSnapshotGenerationsAreOrderedForMonotonicChecks() {
        XCTAssertLessThan(
            SnapshotGeneration(rawValue: 1),
            SnapshotGeneration(rawValue: 2)
        )
    }
}
