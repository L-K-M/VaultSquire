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
        protonService: ProtonAccountService = ProtonAccountService(),
        onePasswordService: OnePasswordAccountService = AppModelTests.inertOnePasswordService()
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
            onePasswordService: onePasswordService,
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
    private func makeProtonService(executor: FakeCLIExecutor) -> ProtonAccountService {
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
        let executor = FakeCLIExecutor()
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
        let executor = FakeCLIExecutor()
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
        let executor = FakeCLIExecutor()
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
        let executor = FakeCLIExecutor()
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
        let executor = FakeCLIExecutor()
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
        let executor = FakeCLIExecutor()
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
        let executor = FakeCLIExecutor()
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

    // MARK: - 1Password, read-only, per vault

    /// The default for tests that never open a 1Password vault. Its locator has
    /// no candidate paths, so a test that registers a 1Password descriptor
    /// without supplying a service reports "not installed" instead of reaching
    /// for a real binary on the machine running the suite.
    private static func inertOnePasswordService() -> OnePasswordAccountService {
        OnePasswordAccountService(
            locator: OnePasswordCLILocator(
                candidatePaths: [],
                isExecutable: { _ in false },
                resolveRealPath: { $0 }
            )
        )
    }

    /// The descriptor `addOnePasswordVault` would write for the stubbed
    /// account: keyed by the CLI's account identifier, so a second account adds
    /// a second vault rather than replacing this one.
    private func onePasswordDescriptor() -> AccountDescriptor {
        AccountDescriptor(
            account: OnePasswordAccountService.vaultIdentity(for: "ACCOUNT1"),
            serverDisplay: "my.1password.com",
            email: "a@example.com"
        )
    }

    @MainActor
    private func makeOnePasswordService(executor: FakeCLIExecutor) -> OnePasswordAccountService {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VSQ-appmodel-1p-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        return OnePasswordAccountService(
            locator: OnePasswordCLILocator(
                candidatePaths: ["/usr/local/bin/op"],
                isExecutable: { _ in true },
                resolveRealPath: { $0 }
            ),
            executor: executor,
            versionGate: OnePasswordCLIVersionGate(supportedVersions: ["2.38.1"]),
            cache: OnePasswordSnapshotCache(keyProvider: { key }, directory: directory),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    @MainActor
    private func stubOnePassword(_ executor: FakeCLIExecutor) async {
        await executor.stub(arguments: ["--version"], stdout: "2.38.1\n")
        await executor.stub(
            arguments: ["account", "list", "--format", "json"],
            stdout: #"[{"url":"my.1password.com","email":"a@example.com","account_uuid":"ACCOUNT1"}]"#
        )
        await executor.stub(
            arguments: ["vault", "list", "--format", "json", "--account", "ACCOUNT1"],
            stdout: #"[{"id":"VAULT1","name":"Private"}]"#
        )
        await executor.stub(
            arguments: [
                "item", "list", "--vault", "VAULT1", "--format", "json", "--account", "ACCOUNT1"
            ],
            stdout: """
            [{"id":"ITEM1","title":"Example Service","category":"LOGIN",
              "fields":[{"id":"username","type":"STRING","purpose":"USERNAME",
                         "label":"username","value":"squire@example.com"}]}]
            """
        )
        await executor.stub(
            arguments: [
                "item", "get", "ITEM1", "--vault", "VAULT1",
                "--format", "json", "--reveal", "--account", "ACCOUNT1"
            ],
            stdout: """
            {"id":"ITEM1","title":"Example Service","category":"LOGIN",
             "fields":[{"id":"password","type":"CONCEALED","purpose":"PASSWORD",
                        "label":"password","value":"VSQ-1p-secret"}]}
            """
        )
    }

    @MainActor
    func testOpeningOnePasswordPopulatesItemsReadOnly() async throws {
        let executor = FakeCLIExecutor()
        await stubOnePassword(executor)

        let account = OnePasswordAccountService.vaultIdentity(for: "ACCOUNT1")
        let (model, _) = makeModel(
            presence: { .present },
            descriptors: [onePasswordDescriptor()],
            onePasswordService: makeOnePasswordService(executor: executor)
        )
        model.refreshAccountPresence()
        XCTAssertEqual(model.session(for: account)?.kind, .onePassword)
        // The sidebar names the account, not the brand, so two are distinct.
        XCTAssertEqual(model.session(for: account)?.title, "my.1password.com")

        model.open(account)
        try await pollUntil { model.session(for: account)?.isOpen == true }

        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items.first?.displayTitle, "Example Service")

        // 1Password is read-only: nothing offers a write on its items.
        let id = try XCTUnwrap(model.items.first?.id)
        XCTAssertFalse(model.canCreateItems)
        XCTAssertFalse(model.canArchive(id))
        XCTAssertFalse(model.canEdit(id))
        XCTAssertNil(model.draft(for: id))

        // Listing carries no secrets; opening the item fetches them.
        XCTAssertNil(model.detail(for: id)?.fields.first { $0.label == "Password" })
        model.hydrateIfNeeded(id)
        try await pollUntil {
            model.detail(for: id)?.fields.contains { $0.label == "Password" } == true
        }
        XCTAssertEqual(
            model.detail(for: id)?.fields.first { $0.label == "Password" }?.value, "VSQ-1p-secret"
        )

        // Locking drops the items and the fetched secret, and the detail is no
        // longer readable from the stale identifier.
        model.lock(account)
        XCTAssertFalse(model.isUnlocked)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.detail(for: id))
    }

    /// Re-opening after a lock must not resurrect the previous session's
    /// secret: the fetched content is dropped with the vault, so the detail
    /// starts bare again.
    @MainActor
    func testReopeningOnePasswordDoesNotResurrectAFetchedSecret() async throws {
        let executor = FakeCLIExecutor()
        await stubOnePassword(executor)

        let account = OnePasswordAccountService.vaultIdentity(for: "ACCOUNT1")
        let (model, _) = makeModel(
            presence: { .present },
            descriptors: [onePasswordDescriptor()],
            onePasswordService: makeOnePasswordService(executor: executor)
        )
        model.refreshAccountPresence()
        model.open(account)
        try await pollUntil { model.session(for: account)?.isOpen == true }

        let id = try XCTUnwrap(model.items.first?.id)
        model.hydrateIfNeeded(id)
        try await pollUntil {
            model.detail(for: id)?.fields.contains { $0.label == "Password" } == true
        }

        model.lock(account)
        model.open(account)
        try await pollUntil { model.session(for: account)?.isOpen == true }

        XCTAssertNil(model.detail(for: id)?.fields.first { $0.label == "Password" })
    }

    /// A read-only provider's item must not gain a write action by sitting in a
    /// merged list beside a writable vault.
    @MainActor
    func testAMergedListStillGatesEachItemByItsOwnProvider() async throws {
        let executor = FakeCLIExecutor()
        await stubOnePassword(executor)

        let onePassword = OnePasswordAccountService.vaultIdentity(for: "ACCOUNT1")
        let (model, _) = makeModel(
            presence: { .present },
            descriptors: [
                AccountDescriptor(
                    account: .vaultwardenPrimary,
                    serverDisplay: "vault.example.com",
                    email: "user@example.com"
                ),
                onePasswordDescriptor(),
            ],
            onePasswordService: makeOnePasswordService(executor: executor)
        )
        model.refreshAccountPresence()
        model.open(onePassword)
        try await pollUntil { model.session(for: onePassword)?.isOpen == true }

        model.scope = .allVaults
        let id = try XCTUnwrap(model.items.first?.id)
        XCTAssertEqual(id.provider, .onePasswordCLI)
        XCTAssertFalse(model.canArchive(id))
        XCTAssertFalse(model.canEdit(id))

        // Locking the never-opened Vaultwarden vault leaves 1Password alone.
        model.lock(.vaultwardenPrimary)
        XCTAssertTrue(model.session(for: onePassword)?.isOpen == true)
        XCTAssertEqual(model.allOpenItems.count, 1)
    }

    /// The sidebar groups 1Password items by their vault, keyed on the vault
    /// identifier carried in each item's compound id.
    @MainActor
    func testOnePasswordItemsGroupByTheirVault() async throws {
        let executor = FakeCLIExecutor()
        await stubOnePassword(executor)

        let account = OnePasswordAccountService.vaultIdentity(for: "ACCOUNT1")
        let (model, _) = makeModel(
            presence: { .present },
            descriptors: [onePasswordDescriptor()],
            onePasswordService: makeOnePasswordService(executor: executor)
        )
        model.refreshAccountPresence()
        model.open(account)
        try await pollUntil { model.session(for: account)?.isOpen == true }

        let groups = try XCTUnwrap(model.session(for: account)?.groups)
        XCTAssertEqual(groups.map(\.id), ["VAULT1"])
        XCTAssertEqual(groups.map(\.name), ["Private"])
        XCTAssertEqual(groups.map(\.count), [1])

        model.scope = .group(account, "VAULT1")
        XCTAssertEqual(model.items.count, 1)
    }

    /// Two signed-in 1Password accounts become two vaults, not one. Adding the
    /// second must not replace the first, and their items must stay separable.
    @MainActor
    func testTwoOnePasswordAccountsBecomeTwoVaults() async throws {
        let executor = FakeCLIExecutor()
        await stubOnePassword(executor)

        let (model, store) = makeModel(
            presence: { .present },
            onePasswordService: makeOnePasswordService(executor: executor)
        )
        model.addOnePasswordVault(OnePasswordAccount(
            accountUUID: "ACCOUNT1", url: "my.1password.com", email: "a@example.com"
        ))
        model.addOnePasswordVault(OnePasswordAccount(
            accountUUID: "ACCOUNT2", url: "work.1password.com", email: "b@example.com"
        ))

        let identities = store.all().map(\.account)
        XCTAssertEqual(identities.count, 2)
        XCTAssertTrue(identities.contains(OnePasswordAccountService.vaultIdentity(for: "ACCOUNT1")))
        XCTAssertTrue(identities.contains(OnePasswordAccountService.vaultIdentity(for: "ACCOUNT2")))
        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertEqual(
            Set(model.sessions.map(\.title)), ["my.1password.com", "work.1password.com"]
        )
    }

    /// Re-adding the same account updates its vault instead of duplicating it.
    @MainActor
    func testReaddingTheSameOnePasswordAccountDoesNotDuplicateTheVault() async throws {
        let executor = FakeCLIExecutor()
        await stubOnePassword(executor)
        let (model, store) = makeModel(
            presence: { .present },
            onePasswordService: makeOnePasswordService(executor: executor)
        )
        let account = OnePasswordAccount(
            accountUUID: "ACCOUNT1", url: "my.1password.com", email: "a@example.com"
        )
        model.addOnePasswordVault(account)
        model.addOnePasswordVault(account)
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(model.sessions.count, 1)
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

    @MainActor
    func testLockCancelsRegisteredCLIBackgroundTasks() async throws {
        // SECURITY_AND_TESTING.md § "Memory And Lifecycle": lock must terminate
        // every Proton CLI process because its output is plaintext. An in-flight
        // refresh/hydrate must be cancelled, not merely have its result
        // discarded. The registry is exercised directly — the same registry
        // openProton/openOnePassword/hydrate/sync register through — so the
        // test is deterministic and independent of the provider service chain.
        let (model, _) = makeModel(descriptors: [
            AccountDescriptor(
                account: ProtonAccountService.accountID,
                serverDisplay: "Proton Pass",
                email: "Official Proton Pass CLI"
            )
        ])
        model.refreshAccountPresence()
        let account = ProtonAccountService.accountID

        let flag = CancellationFlag()
        model.registerCLIBackgroundTaskForTesting(account: account) {
            // Blocks until cancelled, exactly like a CLI executor awaiting
            // output that lock must interrupt.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            await flag.markCancelled()
        }
        try await pollUntil { model.cliBackgroundTaskCountForTesting == 1 }

        // Locking must cancel the registered task so it stops producing
        // plaintext. The registry entry is removed synchronously by lock, so
        // wait on the operation itself observing cancellation (the real proof),
        // yielding the main actor so the cancelled task can resume and record it.
        model.lock(account)
        var wasCancelled = false
        for _ in 0..<400 {
            wasCancelled = await flag.wasMarked
            if wasCancelled { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertTrue(
            wasCancelled,
            "Lock must cancel the registered CLI background task for the account"
        )
    }
}

/// Records that a test task observed cancellation. Actor-isolated so the
/// background task and the test can both reach it safely.
private actor CancellationFlag {
    private(set) var wasMarked = false
    func markCancelled() { wasMarked = true }
}
