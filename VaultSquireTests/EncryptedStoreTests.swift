import XCTest
@testable import VaultSquire

final class EncryptedStoreTests: XCTestCase {
    private let account = canaryStoreAccount

    // MARK: Deterministic ordering

    func testRecordsReturnedInRevisionThenIdentifierOrder() throws {
        let store = InMemoryEncryptedStore()
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 2_000)
        // Publish deliberately out of order and with an intra-date tie.
        let snapshot = makeCanarySnapshot(
            generation: 1,
            records: [
                makeCanaryRecord(itemRawValue: "b", revisionDate: late),
                makeCanaryRecord(itemRawValue: "a", revisionDate: late),
                makeCanaryRecord(itemRawValue: "z", revisionDate: early),
            ]
        )
        try store.publish(snapshot)

        let ordered = try store.records(for: account).map(\.itemID.rawValue)
        // Earlier revision first; within a date, ascending identifier.
        XCTAssertEqual(ordered, ["z", "a", "b"])
    }

    // MARK: Monotonic, atomic publication

    func testGenerationMustStrictlyAdvance() throws {
        let store = InMemoryEncryptedStore()
        try store.publish(makeCanarySnapshot(generation: 5))

        XCTAssertThrowsError(try store.publish(makeCanarySnapshot(generation: 5))) { error in
            XCTAssertEqual(
                error as? EncryptedStoreError,
                .nonMonotonicGeneration(
                    current: SnapshotGeneration(rawValue: 5),
                    offered: SnapshotGeneration(rawValue: 5)
                )
            )
        }
        XCTAssertThrowsError(try store.publish(makeCanarySnapshot(generation: 4)))

        // The rejected publishes left the current generation untouched.
        XCTAssertEqual(try store.currentGeneration(for: account), SnapshotGeneration(rawValue: 5))

        // A strictly greater generation is accepted.
        try store.publish(makeCanarySnapshot(generation: 6))
        XCTAssertEqual(try store.currentGeneration(for: account), SnapshotGeneration(rawValue: 6))
    }

    func testFailedPublishLeavesPriorGenerationIntact() throws {
        let store = InMemoryEncryptedStore()
        let priorRecord = makeCanaryRecord(itemRawValue: "keep", revisionDate: Date(timeIntervalSince1970: 10))
        try store.publish(makeCanarySnapshot(generation: 1, records: [priorRecord]))

        // Model an engine failure mid-commit while publishing a new generation.
        store.setFailNextPublish(true)
        let replacement = makeCanaryRecord(itemRawValue: "replace", revisionDate: Date(timeIntervalSince1970: 20))
        XCTAssertThrowsError(try store.publish(makeCanarySnapshot(generation: 2, records: [replacement]))) { error in
            XCTAssertEqual(error as? EncryptedStoreError, .unexpected)
        }

        // No mixed generation: the prior generation and its records are intact.
        XCTAssertEqual(try store.currentGeneration(for: account), SnapshotGeneration(rawValue: 1))
        XCTAssertEqual(try store.records(for: account).map(\.itemID.rawValue), ["keep"])
    }

    func testCancelledPublishWritesNothing() async throws {
        let store = InMemoryEncryptedStore()
        try store.publish(makeCanarySnapshot(generation: 1))

        let result: EncryptedStoreError? = await Task {
            // Self-cancel synchronously, before publish runs, so it observes
            // cancellation deterministically. Cancelling the Task from outside
            // after creation would race the body: publish reads Task.isCancelled
            // with no suspension point before the call, so the flag must already
            // be set when the body begins.
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try store.publish(makeCanarySnapshot(generation: 2))
                return nil
            } catch let error as EncryptedStoreError {
                return error
            } catch {
                return .unexpected
            }
        }.value

        XCTAssertEqual(result, .cancelled)
        // Prior generation survived; nothing was written by the cancelled publish.
        XCTAssertEqual(try store.currentGeneration(for: account), SnapshotGeneration(rawValue: 1))
    }

    // MARK: Blob boundary

    func testCacheEnvelopeRoundTripsAndStaysSeparableFromRecords() throws {
        let store = InMemoryEncryptedStore()
        let scope = ProviderCacheScope.wholeAccount(account)
        let lossyPayload = Data("VSQ-Canary-lossy-blob".utf8)
        let envelope = ProviderCacheEnvelope(
            scope: scope,
            fidelity: .lossyApplicationEncrypted,
            schemaVersion: 1,
            captureGeneration: SnapshotGeneration(rawValue: 1),
            payload: lossyPayload
        )
        let record = makeCanaryRecord(
            itemRawValue: "vw-1",
            revisionDate: Date(timeIntervalSince1970: 30),
            payload: Data("VSQ-Canary-native-ciphertext".utf8)
        )
        try store.publish(
            makeCanarySnapshot(generation: 1, records: [record], cacheEnvelopes: [envelope])
        )

        // The lossy blob round-trips through the envelope boundary…
        let loaded = try store.cacheEnvelope(for: scope)
        XCTAssertEqual(loaded, envelope)
        XCTAssertEqual(loaded?.fidelity, .lossyApplicationEncrypted)

        // …and never leaks into the ciphertext record rows.
        let recordPayloads = try store.records(for: account).map(\.payload)
        XCTAssertEqual(recordPayloads, [Data("VSQ-Canary-native-ciphertext".utf8)])
        XCTAssertFalse(recordPayloads.contains(lossyPayload))
    }

    // MARK: Reauthentication marker retains the snapshot

    func testReauthenticationMarkerPersistsWithoutDisturbingSnapshot() throws {
        let store = InMemoryEncryptedStore()
        let record = makeCanaryRecord(itemRawValue: "r", revisionDate: Date(timeIntervalSince1970: 40))
        try store.publish(makeCanarySnapshot(generation: 3, records: [record]))
        try store.setQuickUnlockWrappedKey(Data("VSQ-Canary-qk".utf8), for: account)

        try store.setReauthenticationRequired(true, for: account)

        XCTAssertTrue(try store.reauthenticationRequired(for: account))
        // The prior snapshot, generation, records, and quick-unlock key survive.
        XCTAssertEqual(try store.currentGeneration(for: account), SnapshotGeneration(rawValue: 3))
        XCTAssertEqual(try store.records(for: account).map(\.itemID.rawValue), ["r"])
        XCTAssertEqual(try store.quickUnlockWrappedKey(for: account), Data("VSQ-Canary-qk".utf8))

        try store.setReauthenticationRequired(false, for: account)
        XCTAssertFalse(try store.reauthenticationRequired(for: account))
        XCTAssertEqual(try store.currentGeneration(for: account), SnapshotGeneration(rawValue: 3))
    }

    // MARK: Quick-unlock wrapped key

    func testQuickUnlockWrappedKeyStoreLoadClear() throws {
        let store = InMemoryEncryptedStore()
        XCTAssertNil(try store.quickUnlockWrappedKey(for: account))

        let wrapped = Data("VSQ-Canary-wrapped-user-key".utf8)
        try store.setQuickUnlockWrappedKey(wrapped, for: account)
        XCTAssertEqual(try store.quickUnlockWrappedKey(for: account), wrapped)

        try store.setQuickUnlockWrappedKey(nil, for: account)
        XCTAssertNil(try store.quickUnlockWrappedKey(for: account))
    }

    // MARK: Logout wipe post-condition

    func testWipeRemovesEveryTraceOfTheAccount() throws {
        let store = InMemoryEncryptedStore()
        let scope = ProviderCacheScope.wholeAccount(account)
        let envelope = ProviderCacheEnvelope(
            scope: scope,
            fidelity: .losslessNativeCiphertext,
            schemaVersion: 1,
            captureGeneration: SnapshotGeneration(rawValue: 1),
            payload: Data("VSQ-Canary-envelope".utf8)
        )
        try store.publish(
            makeCanarySnapshot(
                generation: 1,
                records: [makeCanaryRecord(itemRawValue: "x", revisionDate: Date(timeIntervalSince1970: 50))],
                cacheEnvelopes: [envelope]
            )
        )
        try store.setReauthenticationRequired(true, for: account)
        try store.setQuickUnlockWrappedKey(Data("VSQ-Canary-qk".utf8), for: account)

        try store.wipe(account)

        // No credential, cache key, or snapshot remains for the account.
        XCTAssertNil(try store.currentGeneration(for: account))
        XCTAssertNil(try store.snapshotDate(for: account))
        XCTAssertTrue(try store.records(for: account).isEmpty)
        XCTAssertNil(try store.syncState(for: account))
        XCTAssertNil(try store.cacheEnvelope(for: scope))
        XCTAssertFalse(try store.reauthenticationRequired(for: account))
        XCTAssertNil(try store.quickUnlockWrappedKey(for: account))
    }

    // MARK: Integrity and unavailability

    func testIntegrityReportsForcedCorruption() throws {
        let store = InMemoryEncryptedStore()
        XCTAssertEqual(try store.checkIntegrity(for: account), .ok)

        store.setForcedIntegrity(.corrupt(reason: "VSQ-Canary-corruption"))
        XCTAssertEqual(try store.checkIntegrity(for: account), .corrupt(reason: "VSQ-Canary-corruption"))
    }

    func testFailingStoreReportsUnavailable() {
        let store = FailingEncryptedStore()
        XCTAssertThrowsError(try store.publish(makeCanarySnapshot(generation: 1))) { error in
            XCTAssertEqual(error as? EncryptedStoreError, .storeUnavailable)
        }
        XCTAssertThrowsError(try store.records(for: account)) { error in
            XCTAssertEqual(error as? EncryptedStoreError, .storeUnavailable)
        }
    }

    // MARK: Snapshot metadata

    func testSnapshotDateCommittedWithGeneration() throws {
        let store = InMemoryEncryptedStore()
        let captured = Date(timeIntervalSince1970: 1_712_000_000)
        try store.publish(makeCanarySnapshot(generation: 1, capturedAt: captured))
        XCTAssertEqual(try store.snapshotDate(for: account), captured)
    }

    func testDistinctAccountsAreIsolated() throws {
        let store = InMemoryEncryptedStore()
        let other = AccountID(provider: .vaultwarden, rawValue: "VSQ-Canary-other")
        try store.publish(makeCanarySnapshot(account: account, generation: 1))
        try store.publish(
            makeCanarySnapshot(
                account: other,
                generation: 9,
                records: [
                    makeCanaryRecord(
                        account: other,
                        itemRawValue: "o1",
                        revisionDate: Date(timeIntervalSince1970: 60)
                    )
                ]
            )
        )

        XCTAssertEqual(try store.currentGeneration(for: account), SnapshotGeneration(rawValue: 1))
        XCTAssertEqual(try store.currentGeneration(for: other), SnapshotGeneration(rawValue: 9))

        try store.wipe(account)
        XCTAssertNil(try store.currentGeneration(for: account))
        // Wiping one account leaves the other fully intact — records included —
        // so an over-broad wipe (a delete missing its account scope) is caught.
        XCTAssertEqual(try store.currentGeneration(for: other), SnapshotGeneration(rawValue: 9))
        XCTAssertEqual(try store.records(for: other).map(\.itemID.rawValue), ["o1"])
    }
}
