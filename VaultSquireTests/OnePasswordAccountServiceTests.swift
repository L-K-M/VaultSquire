import CryptoKit
import XCTest
@testable import VaultSquire

/// All fixtures are synthetic. Secret-looking values are prefixed `VSQ-`.
final class OnePasswordAccountServiceTests: XCTestCase {
    private let approvedPath = "/usr/local/bin/op"

    private func makeService(
        executor: FakeCLIExecutor,
        supported: Set<String> = ["2.38.1"],
        installed: Bool = true
    ) -> OnePasswordAccountService {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultSquire1PSvc-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        return OnePasswordAccountService(
            locator: OnePasswordCLILocator(
                candidatePaths: [approvedPath],
                isExecutable: { _ in installed },
                resolveRealPath: { $0 }
            ),
            executor: executor,
            versionGate: OnePasswordCLIVersionGate(supportedVersions: supported),
            cache: OnePasswordSnapshotCache(keyProvider: { key }, directory: directory),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func stubHappyPath(_ executor: FakeCLIExecutor) async {
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
              "urls":[{"href":"https://example.com"}],
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
                        "label":"password","value":"VSQ-password"}]}
            """
        )
    }

    // MARK: - Refresh

    func testRefreshListsAndSealsWithoutFetchingAnySecret() async throws {
        let executor = FakeCLIExecutor()
        await stubHappyPath(executor)
        let service = makeService(executor: executor)

        let result = await service.refresh(accountUUID: "ACCOUNT1")
        guard case .success(let refresh) = result else {
            return XCTFail("expected success, got \(result)")
        }
        let projection = try XCTUnwrap(refresh.projections.first)
        XCTAssertEqual(projection.displayTitle, "Example Service")
        XCTAssertEqual(projection.category, .login)
        XCTAssertEqual(projection.username, "squire@example.com")
        XCTAssertEqual(projection.id.provider, .onePasswordCLI)

        // Listing must never hydrate: `op item get` is a child process and, by
        // 1Password's own request accounting, several server reads per item.
        let recorded = await executor.recordedArguments
        XCTAssertFalse(
            recorded.contains { $0.first == "item" && $0.dropFirst().first == "get" },
            "refresh must not fetch any item's secrets"
        )
        XCTAssertEqual(recorded.count, 3, "version + vault list + one item list")

        // No secret rests in the sealed snapshot.
        let cached = try XCTUnwrap(service.cachedSnapshot(accountUUID: "ACCOUNT1"))
        XCTAssertEqual(cached, refresh.snapshot)
        XCTAssertTrue(cached.lossy)
        let encoded = try JSONEncoder().encode(cached)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("VSQ-"))

        // Without fetched content the detail carries the non-secret fields only.
        let bare = try XCTUnwrap(service.detail(for: projection.id, snapshot: refresh.snapshot))
        XCTAssertNil(bare.fields.first { $0.label == "Password" })
    }

    /// Every account-bearing command names the account the snapshot was read
    /// from, so a second signed-in account cannot answer a command meant for
    /// this one.
    func testRefreshResolvesTheAccountAndScopesLaterCommandsToIt() async throws {
        let executor = FakeCLIExecutor()
        await stubHappyPath(executor)
        let service = makeService(executor: executor)

        guard case .success(let refresh) = await service.refresh(accountUUID: "ACCOUNT1") else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(refresh.snapshot.accountIdentifier, "ACCOUNT1")

        let recorded = await executor.recordedArguments
        for arguments in recorded where arguments != ["--version"] {
            XCTAssertEqual(
                Array(arguments.suffix(2)), ["--account", "ACCOUNT1"],
                "\(arguments) was not scoped to the resolved account"
            )
        }
    }

    func testRefreshReportsCLINotInstalled() async {
        let service = makeService(executor: FakeCLIExecutor(), installed: false)
        guard case .failure(let error) = await service.refresh(accountUUID: "ACCOUNT1") else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(error, .cliNotInstalled)
    }

    func testRefreshReportsUnsupportedVersion() async {
        let executor = FakeCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "2.39.0\n")
        let service = makeService(executor: executor, supported: ["2.38.1"])
        guard case .failure(let error) = await service.refresh(accountUUID: "ACCOUNT1") else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(error, .unsupportedVersion("2.39.0"))
    }

    /// The first real read is where authorization is decided, so a non-zero
    /// `vault list` means the desktop app did not grant it — locked app,
    /// integration off, or a declined prompt. The CLI reports all three the
    /// same way, so the service reports the one honest state.
    func testRefreshTreatsAVaultListFailureAsNotAuthorized() async {
        let executor = FakeCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "2.38.1")
        await executor.stub(
            arguments: ["vault", "list", "--format", "json", "--account", "ACCOUNT1"],
            stdout: Data(), exitCode: 1
        )
        let service = makeService(executor: executor)
        guard case .failure(let error) = await service.refresh(accountUUID: "ACCOUNT1") else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(error, .notAuthorized)
    }

    /// An account identifier the CLI would never accept must fail before any
    /// command runs, rather than being passed to argv.
    func testRefreshRejectsAnUnusableAccountIdentifier() async {
        let executor = FakeCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "2.38.1")
        let service = makeService(executor: executor)
        guard case .failure(let error) = await service.refresh(accountUUID: "--oops") else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(error, .unusableAccount)
        let recorded = await executor.recordedArguments
        XCTAssertEqual(recorded, [["--version"]])
    }

    func testRefreshReportsUnreadableOutput() async {
        let executor = FakeCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "2.38.1")
        await executor.stub(
            arguments: ["account", "list", "--format", "json"],
            stdout: #"[{"url":"my.1password.com","account_uuid":"ACCOUNT1"}]"#
        )
        await executor.stub(
            arguments: ["vault", "list", "--format", "json", "--account", "ACCOUNT1"],
            stdout: "not json"
        )
        let service = makeService(executor: executor)
        guard case .failure(let error) = await service.refresh(accountUUID: "ACCOUNT1") else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(error, .unreadableOutput)
    }

    /// One vault the build will not list should not cost the user every other
    /// vault, so it is skipped rather than failing the whole refresh.
    func testAnUnreadableVaultIsSkippedRatherThanFailingTheRefresh() async throws {
        let executor = FakeCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "2.38.1")
        await executor.stub(
            arguments: ["account", "list", "--format", "json"],
            stdout: #"[{"url":"my.1password.com","account_uuid":"ACCOUNT1"}]"#
        )
        await executor.stub(
            arguments: ["vault", "list", "--format", "json", "--account", "ACCOUNT1"],
            stdout: #"[{"id":"VAULT1","name":"Private"},{"id":"VAULT2","name":"Shared"}]"#
        )
        await executor.stub(
            arguments: [
                "item", "list", "--vault", "VAULT1", "--format", "json", "--account", "ACCOUNT1"
            ],
            stdout: Data(), exitCode: 1
        )
        await executor.stub(
            arguments: [
                "item", "list", "--vault", "VAULT2", "--format", "json", "--account", "ACCOUNT1"
            ],
            stdout: #"[{"id":"ITEM2","title":"Kept","category":"LOGIN"}]"#
        )
        let service = makeService(executor: executor)

        guard case .success(let refresh) = await service.refresh(accountUUID: "ACCOUNT1") else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(refresh.projections.map(\.displayTitle), ["Kept"])
    }

    /// A vault whose identifier fails validation never reaches a command, and
    /// must be skipped for the same reason an unlistable one is — not allowed
    /// to fail the whole refresh.
    func testAVaultWithAnUnusableIdentifierIsSkipped() async throws {
        let executor = FakeCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "2.38.1")
        await executor.stub(
            arguments: ["account", "list", "--format", "json"],
            stdout: #"[{"url":"my.1password.com","account_uuid":"ACCOUNT1"}]"#
        )
        await executor.stub(
            arguments: ["vault", "list", "--format", "json", "--account", "ACCOUNT1"],
            stdout: #"[{"id":"--oops","name":"Bad"},{"id":"VAULT2","name":"Shared"}]"#
        )
        await executor.stub(
            arguments: [
                "item", "list", "--vault", "VAULT2", "--format", "json", "--account", "ACCOUNT1"
            ],
            stdout: #"[{"id":"ITEM2","title":"Kept","category":"LOGIN"}]"#
        )
        let service = makeService(executor: executor)

        guard case .success(let refresh) = await service.refresh(accountUUID: "ACCOUNT1") else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(refresh.projections.map(\.displayTitle), ["Kept"])

        // The rejected identifier never became a command.
        let recorded = await executor.recordedArguments
        XCTAssertFalse(recorded.contains { $0.contains("--oops") })
    }

    // MARK: - On-demand content

    func testContentFetchesOneItemOnDemandAndMergesIntoTheDetail() async throws {
        let executor = FakeCLIExecutor()
        await stubHappyPath(executor)
        let service = makeService(executor: executor)

        guard case .success(let refresh) = await service.refresh(accountUUID: "ACCOUNT1") else {
            return XCTFail("expected success")
        }
        let projection = try XCTUnwrap(refresh.projections.first)

        // The await is hoisted: XCTUnwrap takes an autoclosure, which cannot
        // carry an async call.
        let fetched = await service.content(
            itemID: "ITEM1", vaultID: "VAULT1", accountUUID: "ACCOUNT1"
        )
        let content = try XCTUnwrap(fetched)
        XCTAssertEqual(content.password, "VSQ-password")

        let detail = try XCTUnwrap(
            service.detail(for: projection.id, snapshot: refresh.snapshot, content: content)
        )
        let password = try XCTUnwrap(detail.fields.first { $0.label == "Password" })
        XCTAssertEqual(password.value, "VSQ-password")
        XCTAssertEqual(password.kind, .secret)
    }

    /// The version gate is a security control, so the on-demand read runs it
    /// too: an unadmitted CLI yields no content rather than parsed output.
    func testContentFailsClosedOnAnUnsupportedVersion() async {
        let executor = FakeCLIExecutor()
        await stubHappyPath(executor)
        let service = makeService(executor: executor, supported: ["9.9.9"])
        let content = await service.content(
            itemID: "ITEM1", vaultID: "VAULT1", accountUUID: "ACCOUNT1"
        )
        XCTAssertNil(content)
    }

    func testDetailReturnsNilForAnItemOutsideTheSnapshot() async {
        let executor = FakeCLIExecutor()
        await stubHappyPath(executor)
        let service = makeService(executor: executor)
        guard case .success(let refresh) = await service.refresh(accountUUID: "ACCOUNT1") else {
            return XCTFail("expected success")
        }
        let foreign = VaultItemID(
            space: VaultSpaceID(
                account: OnePasswordAccountService.vaultIdentity(for: "ACCOUNT1"),
                scope: .providerSpace("VAULT9")
            ),
            rawValue: "ITEM9"
        )
        XCTAssertNil(service.detail(for: foreign, snapshot: refresh.snapshot))
    }

    // MARK: - Detection

    func testProbeStatusReadyWhenAnAccountIsConfigured() async {
        let executor = FakeCLIExecutor()
        await stubHappyPath(executor)
        let service = makeService(executor: executor)
        let status = await service.probeStatus()
        XCTAssertEqual(
            status,
            .ready(
                version: "2.38.1",
                accounts: [OnePasswordAccount(
                    accountUUID: "ACCOUNT1", url: "my.1password.com", email: "a@example.com"
                )],
                approvedPath: approvedPath,
                resolvedRealPath: approvedPath
            )
        )
    }

    func testProbeStatusNotInstalled() async {
        let service = makeService(executor: FakeCLIExecutor(), installed: false)
        let status = await service.probeStatus()
        XCTAssertEqual(status, .notInstalled)
    }

    /// Detection enumerates accounts and stops. Proving authorization would
    /// mean running a real read, which raises the biometric prompt — rude to do
    /// merely because the Add Account sheet was opened.
    func testProbeStatusDoesNotAttemptAuthorization() async {
        let executor = FakeCLIExecutor()
        await stubHappyPath(executor)
        let service = makeService(executor: executor)
        _ = await service.probeStatus()

        let recorded = await executor.recordedArguments
        XCTAssertEqual(recorded, [
            ["--version"],
            ["account", "list", "--format", "json"]
        ], "detection must not run a real read")
    }

    func testProbeStatusReportsNoAccounts() async {
        let executor = FakeCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "2.38.1")
        await executor.stub(arguments: ["account", "list", "--format", "json"], stdout: "[]")
        let service = makeService(executor: executor)
        XCTAssertEqual(await service.probeStatus(), .noAccounts)
    }

    /// `account list` reads local configuration, so a failure there is a broken
    /// install, not a refused prompt.
    func testProbeStatusReportsErrorWhenAccountsCannotBeListed() async {
        let executor = FakeCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "2.38.1")
        await executor.stub(
            arguments: ["account", "list", "--format", "json"], stdout: Data(), exitCode: 1
        )
        let service = makeService(executor: executor)
        XCTAssertEqual(await service.probeStatus(), .error)
    }

    /// Two signed-in accounts are both offered; neither is silently chosen.
    func testProbeStatusOffersEveryConfiguredAccount() async throws {
        let executor = FakeCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "2.38.1")
        await executor.stub(
            arguments: ["account", "list", "--format", "json"],
            stdout: #"[{"url":"a.1password.com","account_uuid":"ACCOUNTA"},{"url":"b.1password.com","account_uuid":"ACCOUNTB"}]"#
        )
        let service = makeService(executor: executor)
        guard case .ready(_, let accounts, _, _) = await service.probeStatus() else {
            return XCTFail("expected ready")
        }
        XCTAssertEqual(accounts.map(\.accountUUID), ["ACCOUNTA", "ACCOUNTB"])
    }

    func testProbeStatusUnsupportedVersion() async {
        let executor = FakeCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "2.39.0")
        let service = makeService(executor: executor, supported: ["2.38.1"])
        let status = await service.probeStatus()
        XCTAssertEqual(status, .unsupportedVersion("2.39.0"))
    }

    func testProbeStatusUnparseableVersion() async {
        let executor = FakeCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "not a version")
        let service = makeService(executor: executor)
        let status = await service.probeStatus()
        XCTAssertEqual(status, .unparseableVersion)
    }

    // MARK: - Capabilities

    func testTheProviderIsReadOnly() {
        let capabilities = OnePasswordAccountService.capabilities
        XCTAssertEqual(capabilities, OnePasswordReadModel.capabilities)
        for write: ProviderCapability in [
            .createItem, .updateItem, .archiveItem, .trashItem, .restoreItem,
            .deleteItemPermanently, .favoriteItem, .organizeFolders, .shareItems
        ] {
            XCTAssertFalse(
                capabilities.contains(write), "\(write) must stay disabled for 1Password"
            )
        }
    }
}
