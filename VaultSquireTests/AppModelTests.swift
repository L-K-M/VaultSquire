import CryptoKit
import XCTest
@testable import VaultSquire

final class AppModelTests: XCTestCase {
    /// A model whose descriptor store is an isolated defaults suite, so tests
    /// never read or write the real installation's vault list.
    @MainActor
    private func makeModel(
        presence: @escaping () -> AppModel.AccountPresence = { .none },
        descriptors: [AccountDescriptor] = [],
        protonService: ProtonAccountService = ProtonAccountService()
    ) -> (AppModel, AccountDescriptorStore) {
        let defaults = UserDefaults(suiteName: "VSQ-appmodel-\(UUID().uuidString)")!
        let store = AccountDescriptorStore(defaults: defaults)
        for descriptor in descriptors {
            store.upsert(descriptor)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VSQ-appmodel-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let service = VaultwardenAccountService(
            credentialStore: InMemoryCredentialStore(),
            vaultCache: VaultwardenVaultCache(keyProvider: { key }, directory: directory),
            descriptorStore: store
        )
        let model = AppModel(
            queryAccountPresence: presence,
            service: service,
            protonService: protonService,
            biometricStore: FakeBiometricVaultKeyStore(available: false)
        )
        return (model, store)
    }

    @MainActor
    func testNewModelIsLocked() {
        let (model, _) = makeModel()
        XCTAssertTrue(model.isLocked)
        XCTAssertFalse(model.isUnlocked)
        XCTAssertTrue(model.sessions.isEmpty)
    }

    @MainActor
    func testLockIsIdempotent() {
        let (model, _) = makeModel()
        model.lock()
        model.lock()
        XCTAssertTrue(model.isLocked)
    }

    @MainActor
    func testAccountPresenceStartsUnknownAndRefreshQueriesTheStore() {
        var presence = AppModel.AccountPresence.none
        let (model, _) = makeModel(presence: { presence })

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
    func testRefreshBuildsOneSessionPerConfiguredVault() {
        let (model, _) = makeModel(
            presence: { .present },
            descriptors: [
                AccountDescriptor(
                    account: .vaultwardenPrimary,
                    serverDisplay: "vault.example.com",
                    email: "user@example.com"
                ),
                AccountDescriptor(
                    account: ProtonAccountService.accountID,
                    serverDisplay: "Proton Pass",
                    email: "Official Proton Pass CLI"
                ),
            ]
        )
        model.refreshAccountPresence()

        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertEqual(model.session(for: .vaultwardenPrimary)?.kind, .vaultwarden)
        XCTAssertEqual(model.session(for: ProtonAccountService.accountID)?.kind, .proton)
        // A closed vault contributes no items and no secrets.
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(model.allOpenItems.isEmpty)
        XCTAssertFalse(model.isUnlocked)
    }

    // MARK: - Proton, read-only, per vault

    @MainActor
    private func makeProtonService(executor: FakeProtonCLIExecutor) -> ProtonAccountService {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VSQ-appmodel-proton-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        return ProtonAccountService(
            locator: ProtonCLILocator(
                candidatePaths: ["/opt/homebrew/bin/pass-cli"],
                isExecutable: { _ in true },
                resolveRealPath: { $0 }
            ),
            executor: executor,
            versionGate: ProtonCLIVersionGate(supportedVersions: ["2.2.4"]),
            cache: ProtonSnapshotCache(keyProvider: { key }, directory: directory),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    @MainActor
    func testOpeningProtonPopulatesItemsReadOnly() async throws {
        let executor = FakeProtonCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "pass-cli 2.2.4\n")
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

        let account = ProtonAccountService.accountID
        let (model, _) = makeModel(
            presence: { .present },
            descriptors: [
                AccountDescriptor(
                    account: account, serverDisplay: "Proton Pass", email: "Official Proton Pass CLI"
                )
            ],
            protonService: makeProtonService(executor: executor)
        )
        model.refreshAccountPresence()

        model.open(account)
        try await pollUntil { model.session(for: account)?.isOpen == true }

        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items.first?.displayTitle, "GitHub")
        // Proton is read-only: nothing offers a write on its items.
        let id = try XCTUnwrap(model.items.first?.id)
        XCTAssertFalse(model.canCreateItems)
        XCTAssertFalse(model.canArchive(id))
        XCTAssertFalse(model.canEdit(id))
        XCTAssertNil(model.draft(for: id))

        // Listing carries no secrets; opening the item fetches them.
        XCTAssertNil(model.detail(for: id)?.fields.first { $0.label == "Password" })
        model.hydrateIfNeeded(id)
        try await pollUntil { model.detail(for: id)?.fields.contains { $0.label == "Password" } == true }
        XCTAssertEqual(
            model.detail(for: id)?.fields.first { $0.label == "Password" }?.value, "VSQ-secret"
        )

        // Locking that vault drops its items and its fetched secrets, and the
        // detail is no longer readable from the stale identifier.
        model.lock(account)
        XCTAssertFalse(model.isUnlocked)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.detail(for: id))
    }

    /// The whole point of the multi-vault model: locking one vault must not
    /// disturb another that is open.
    @MainActor
    func testLockingOneVaultLeavesTheOtherOpen() async throws {
        let executor = FakeProtonCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "pass-cli 2.2.4\n")
        await executor.stub(
            arguments: ["vault", "list", "--output", "json"],
            stdout: #"{"vaults":[{"shareId":"S1","name":"Personal"}]}"#
        )
        await executor.stub(
            arguments: ["item", "list", "--share-id", "S1", "--output", "json"],
            stdout: #"{"items":[{"id":"i1","type":"login","title":"GitHub"}]}"#
        )

        let proton = ProtonAccountService.accountID
        let (model, _) = makeModel(
            presence: { .present },
            descriptors: [
                AccountDescriptor(
                    account: .vaultwardenPrimary,
                    serverDisplay: "vault.example.com",
                    email: "user@example.com"
                ),
                AccountDescriptor(
                    account: proton, serverDisplay: "Proton Pass", email: "Official Proton Pass CLI"
                ),
            ],
            protonService: makeProtonService(executor: executor)
        )
        model.refreshAccountPresence()
        model.open(proton)
        try await pollUntil { model.session(for: proton)?.isOpen == true }

        XCTAssertTrue(model.isUnlocked)
        XCTAssertEqual(model.allOpenItems.count, 1)

        // Locking the (never opened) Vaultwarden vault leaves Proton alone.
        model.lock(.vaultwardenPrimary)
        XCTAssertTrue(model.session(for: proton)?.isOpen == true)
        XCTAssertEqual(model.allOpenItems.count, 1)

        model.lock(proton)
        XCTAssertFalse(model.isUnlocked)
    }

    /// The sidebar hierarchy: a vault's containers come from the items' own
    /// grouping labels, and scoping to one narrows the list to it.
    @MainActor
    func testVaultExposesItsContainersAndScopingNarrowsToThem() async throws {
        let executor = FakeProtonCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "pass-cli 2.2.4\n")
        await executor.stub(
            arguments: ["vault", "list", "--output", "json"],
            stdout: #"{"vaults":[{"shareId":"S1","name":"Personal"},{"shareId":"S2","name":"Work"}]}"#
        )
        await executor.stub(
            arguments: ["item", "list", "--share-id", "S1", "--output", "json"],
            stdout: #"{"items":[{"id":"i1","type":"login","title":"GitHub"}]}"#
        )
        await executor.stub(
            arguments: ["item", "list", "--share-id", "S2", "--output", "json"],
            stdout: #"{"items":[{"id":"i2","type":"login","title":"Payroll"},{"id":"i3","type":"login","title":"Intranet"}]}"#
        )

        let account = ProtonAccountService.accountID
        let (model, _) = makeModel(
            presence: { .present },
            descriptors: [
                AccountDescriptor(
                    account: account, serverDisplay: "Proton Pass", email: "Official Proton Pass CLI"
                )
            ],
            protonService: makeProtonService(executor: executor)
        )
        model.refreshAccountPresence()
        model.open(account)
        try await pollUntil { model.session(for: account)?.isOpen == true }

        let groups = try XCTUnwrap(model.session(for: account)?.groups)
        XCTAssertEqual(groups.map(\.name), ["Personal", "Work"])
        // A Proton container is keyed by its share, not its display name.
        XCTAssertEqual(groups.map(\.id), ["S1", "S2"])
        XCTAssertEqual(groups.first { $0.name == "Work" }?.count, 2)

        model.scope = .group(account, "S2")
        XCTAssertEqual(model.items.map(\.displayTitle), ["Intranet", "Payroll"])

        model.scope = .group(account, "S1")
        XCTAssertEqual(model.items.map(\.displayTitle), ["GitHub"])

        // Locking the vault empties its containers rather than leaving a stale
        // hierarchy pointing at items that are gone.
        model.lock(account)
        XCTAssertTrue(model.session(for: account)?.groups.isEmpty == true)
        XCTAssertTrue(model.items.isEmpty)
    }

    /// Two Proton vaults may carry the same name. They must stay separate rows
    /// holding separate items, which keying on the display name would break.
    @MainActor
    func testSameNamedProtonVaultsStaySeparateContainers() async throws {
        let executor = FakeProtonCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "pass-cli 2.2.4\n")
        await executor.stub(
            arguments: ["vault", "list", "--output", "json"],
            stdout: #"{"vaults":[{"shareId":"S1","name":"Personal"},{"shareId":"S2","name":"Personal"}]}"#
        )
        await executor.stub(
            arguments: ["item", "list", "--share-id", "S1", "--output", "json"],
            stdout: #"{"items":[{"id":"i1","type":"login","title":"First"}]}"#
        )
        await executor.stub(
            arguments: ["item", "list", "--share-id", "S2", "--output", "json"],
            stdout: #"{"items":[{"id":"i2","type":"login","title":"Second"}]}"#
        )

        let account = ProtonAccountService.accountID
        let (model, _) = makeModel(
            presence: { .present },
            descriptors: [
                AccountDescriptor(
                    account: account, serverDisplay: "Proton Pass", email: "Official Proton Pass CLI"
                )
            ],
            protonService: makeProtonService(executor: executor)
        )
        model.refreshAccountPresence()
        model.open(account)
        try await pollUntil { model.session(for: account)?.isOpen == true }

        let groups = try XCTUnwrap(model.session(for: account)?.groups)
        XCTAssertEqual(groups.count, 2, "same-named vaults must not merge")
        XCTAssertEqual(groups.map(\.name), ["Personal", "Personal"])
        XCTAssertEqual(groups.map(\.id), ["S1", "S2"])
        XCTAssertEqual(groups.map(\.count), [1, 1])

        model.scope = .group(account, "S1")
        XCTAssertEqual(model.items.map(\.displayTitle), ["First"])
        model.scope = .group(account, "S2")
        XCTAssertEqual(model.items.map(\.displayTitle), ["Second"])
    }

    /// A read-only vault is never offered as a destination for a new item.
    @MainActor
    func testWritableVaultsExcludesReadOnlyProviders() async throws {
        let executor = FakeProtonCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "pass-cli 2.2.4\n")
        await executor.stub(
            arguments: ["vault", "list", "--output", "json"],
            stdout: #"{"vaults":[{"shareId":"S1","name":"Personal"}]}"#
        )
        await executor.stub(
            arguments: ["item", "list", "--share-id", "S1", "--output", "json"],
            stdout: #"{"items":[{"id":"i1","type":"login","title":"GitHub"}]}"#
        )

        let proton = ProtonAccountService.accountID
        let (model, _) = makeModel(
            presence: { .present },
            descriptors: [
                AccountDescriptor(
                    account: proton, serverDisplay: "Proton Pass", email: "Official Proton Pass CLI"
                )
            ],
            protonService: makeProtonService(executor: executor)
        )
        model.refreshAccountPresence()
        model.open(proton)
        try await pollUntil { model.session(for: proton)?.isOpen == true }

        XCTAssertTrue(model.writableVaults.isEmpty)
        XCTAssertNil(model.createTarget)
        XCTAssertFalse(model.canCreateItems)
    }

    /// The shell calls refreshAccountPresence every time it appears, so the
    /// rebuild must diff rather than recreate: recreating would silently lock
    /// every open vault on each appearance.
    @MainActor
    func testRefreshPreservesAnOpenVault() async throws {
        let executor = FakeProtonCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "pass-cli 2.2.4\n")
        await executor.stub(
            arguments: ["vault", "list", "--output", "json"],
            stdout: #"{"vaults":[{"shareId":"S1","name":"Personal"}]}"#
        )
        await executor.stub(
            arguments: ["item", "list", "--share-id", "S1", "--output", "json"],
            stdout: #"{"items":[{"id":"i1","type":"login","title":"GitHub"}]}"#
        )

        let account = ProtonAccountService.accountID
        let (model, _) = makeModel(
            presence: { .present },
            descriptors: [
                AccountDescriptor(
                    account: account, serverDisplay: "Proton Pass", email: "Official Proton Pass CLI"
                )
            ],
            protonService: makeProtonService(executor: executor)
        )
        model.refreshAccountPresence()
        model.open(account)
        try await pollUntil { model.session(for: account)?.isOpen == true }

        model.refreshAccountPresence()
        XCTAssertTrue(model.session(for: account)?.isOpen == true, "an open vault survives a refresh")
        XCTAssertEqual(model.allOpenItems.count, 1)
    }

    /// Scoping narrows the list; All Vaults merges. Quick Search always spans
    /// everything that is open regardless of the browser's scope.
    @MainActor
    func testScopeNarrowsTheListButQuickSearchSpansEveryOpenVault() async throws {
        let executor = FakeProtonCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "pass-cli 2.2.4\n")
        await executor.stub(
            arguments: ["vault", "list", "--output", "json"],
            stdout: #"{"vaults":[{"shareId":"S1","name":"Personal"}]}"#
        )
        await executor.stub(
            arguments: ["item", "list", "--share-id", "S1", "--output", "json"],
            stdout: #"{"items":[{"id":"i1","type":"login","title":"GitHub"}]}"#
        )

        let proton = ProtonAccountService.accountID
        let (model, _) = makeModel(
            presence: { .present },
            descriptors: [
                AccountDescriptor(
                    account: .vaultwardenPrimary,
                    serverDisplay: "vault.example.com",
                    email: "user@example.com"
                ),
                AccountDescriptor(
                    account: proton, serverDisplay: "Proton Pass", email: "Official Proton Pass CLI"
                ),
            ],
            protonService: makeProtonService(executor: executor)
        )
        model.refreshAccountPresence()
        model.open(proton)
        try await pollUntil { model.session(for: proton)?.isOpen == true }

        model.scope = .allVaults
        XCTAssertEqual(model.items.count, 1)

        // Scoped to the closed Vaultwarden vault, the list is empty …
        model.scope = .vault(.vaultwardenPrimary)
        XCTAssertTrue(model.items.isEmpty)
        // … but Quick Search still finds the open Proton item.
        XCTAssertEqual(model.quickSearchItems.count, 1)
        XCTAssertTrue(model.quickSearchIsUnlocked)
    }

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
