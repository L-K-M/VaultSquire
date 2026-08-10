import CryptoKit
import XCTest
@testable import VaultSquire

final class AppModelTests: XCTestCase {
    @MainActor
    func testNewModelIsLocked() {
        let model = AppModel()

        XCTAssertEqual(model.accessState, .locked)
        XCTAssertTrue(model.isLocked)
    }

    @MainActor
    func testLockIsIdempotent() {
        let model = AppModel()

        model.lock()
        model.lock()

        XCTAssertTrue(model.isLocked)
    }

    @MainActor
    func testAccountPresenceStartsUnknownAndRefreshQueriesTheStore() {
        var presence = AppModel.AccountPresence.none
        let model = AppModel(queryAccountPresence: { presence })

        XCTAssertEqual(model.accountPresence, .unknown)
        XCTAssertFalse(model.hasNoAccounts, "unknown must not claim absence")

        model.refreshAccountPresence()
        XCTAssertEqual(model.accountPresence, .none)
        XCTAssertTrue(model.hasNoAccounts)

        presence = .present
        model.refreshAccountPresence()
        XCTAssertEqual(model.accountPresence, .present)
        XCTAssertFalse(model.hasNoAccounts)
    }

    @MainActor
    func testNoteAccountConfiguredMarksPresenceWithoutAStoreQuery() {
        let model = AppModel(queryAccountPresence: {
            XCTFail("noteAccountConfigured must not query the store")
            return .unknown
        })

        model.noteAccountConfigured()

        XCTAssertEqual(model.accountPresence, .present)
        XCTAssertFalse(model.hasNoAccounts)
    }

    @MainActor
    func testOpenProtonVaultPopulatesItemsReadOnly() async throws {
        let executor = FakeProtonCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "proton-pass 2.2.4\n")
        await executor.stub(
            arguments: ["vault", "list", "--output", "json"],
            stdout: #"{"vaults":[{"shareId":"S1","name":"Personal"}]}"#
        )
        await executor.stub(
            arguments: ["item", "list", "--share-id", "S1", "--output", "json"],
            stdout: #"{"items":[{"id":"i1","type":"login","title":"GitHub","content":{"username":"octocat"}}]}"#
        )
        await executor.stub(
            arguments: ["item", "view", "--share-id", "S1", "--item-id", "i1", "--output", "json"],
            stdout: #"{"login":{"password":"VSQ-secret"}}"#
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultSquireAppModelProton-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let proton = ProtonAccountService(
            locator: ProtonCLILocator(
                candidatePaths: ["/opt/homebrew/bin/proton-pass"],
                isExecutable: { _ in true },
                resolveRealPath: { $0 }
            ),
            executor: executor,
            versionGate: ProtonCLIVersionGate(supportedVersions: ["2.2.4"]),
            cache: ProtonSnapshotCache(keyProvider: { key }, directory: directory),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let model = AppModel(queryAccountPresence: { .present }, protonService: proton)
        model.openProtonVault()
        try await pollUntil { model.isUnlocked }

        XCTAssertEqual(model.activeVault, .proton)
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items.first?.displayTitle, "GitHub")
        // Proton is read-only: no create or archive is offered.
        XCTAssertFalse(model.canCreateItems)
        XCTAssertFalse(model.canArchiveItems)

        // Opening the vault fetches no secrets: listing is fast and the password
        // arrives only once the item is actually opened.
        let id = try XCTUnwrap(model.items.first?.id)
        let bare = try XCTUnwrap(model.detail(for: id))
        XCTAssertNil(bare.fields.first { $0.label == "Password" })

        model.hydrateIfNeeded(id)
        try await pollUntil { model.detail(for: id)?.fields.contains { $0.label == "Password" } == true }
        XCTAssertEqual(
            model.detail(for: id)?.fields.first { $0.label == "Password" }?.value, "VSQ-secret"
        )

        // Locking drops the Proton snapshot and returns to the shell.
        model.lock()
        XCTAssertEqual(model.activeVault, .none)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.detail(for: id))
    }

    /// Polls a main-actor condition, yielding so a model's internal Task can
    /// run, until it holds or a short timeout elapses.
    @MainActor
    private func pollUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition did not hold within the timeout", file: file, line: line)
    }
}
