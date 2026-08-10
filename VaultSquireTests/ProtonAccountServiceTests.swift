import CryptoKit
import XCTest
@testable import VaultSquire

final class ProtonAccountServiceTests: XCTestCase {
    private let approvedPath = "/opt/homebrew/bin/proton-pass"

    private func makeService(
        executor: FakeProtonCLIExecutor,
        supported: Set<String> = ["2.2.4"],
        installed: Bool = true
    ) -> ProtonAccountService {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultSquireProtonSvc-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        return ProtonAccountService(
            locator: ProtonCLILocator(
                candidatePaths: [approvedPath],
                isExecutable: { _ in installed },
                resolveRealPath: { $0 }
            ),
            executor: executor,
            versionGate: ProtonCLIVersionGate(supportedVersions: supported),
            cache: ProtonSnapshotCache(keyProvider: { key }, directory: directory),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func stubHappyPath(_ executor: FakeProtonCLIExecutor) async {
        await executor.stub(arguments: ["--version"], stdout: "proton-pass 2.2.4\n")
        await executor.stub(
            arguments: ["vault", "list", "--output", "json"],
            stdout: #"{"vaults":[{"shareId":"S1","name":"Personal"}]}"#
        )
        await executor.stub(
            arguments: ["item", "list", "--share-id", "S1", "--output", "json"],
            stdout: #"{"items":[{"id":"i1","type":"login","title":"GitHub","content":{"username":"octocat","urls":["https://github.com"]}}]}"#
        )
        await executor.stub(
            arguments: ["item", "view", "--share-id", "S1", "--item-id", "i1", "--output", "json"],
            stdout: #"{"login":{"password":"VSQ-secret","totp":"otpauth://x"}}"#
        )
    }

    func testRefreshListsAndSealsWithoutFetchingAnySecret() async throws {
        let executor = FakeProtonCLIExecutor()
        await stubHappyPath(executor)
        let service = makeService(executor: executor)

        let result = await service.refresh()
        guard case .success(let refresh) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(refresh.projections.count, 1)
        let projection = try XCTUnwrap(refresh.projections.first)
        XCTAssertEqual(projection.displayTitle, "GitHub")
        XCTAssertEqual(projection.category, .login)
        XCTAssertEqual(projection.username, "octocat")
        XCTAssertEqual(projection.id.provider, .protonCLI)

        // The regression this guards: one `item view` per item made opening a
        // real vault take minutes. A refresh runs the version probe, the vault
        // list, and one item list per vault — and never an item view.
        let recorded = await executor.recordedArguments
        XCTAssertFalse(
            recorded.contains { $0.first == "item" && $0.dropFirst().first == "view" },
            "refresh must not fetch any item's secrets"
        )
        XCTAssertEqual(recorded.count, 3, "version + vault list + one item list")

        // No secret rests in the sealed snapshot.
        let cached = try XCTUnwrap(service.cachedSnapshot())
        XCTAssertEqual(cached, refresh.snapshot)
        XCTAssertTrue(cached.lossy)
        XCTAssertNil(cached.items.first?.password)
        // Without fetched content the detail carries the non-secret fields only.
        let bare = try XCTUnwrap(service.detail(for: projection.id, snapshot: refresh.snapshot))
        XCTAssertNil(bare.fields.first { $0.label == "Password" })
    }

    func testContentFetchesOneItemOnDemandAndMergesIntoTheDetail() async throws {
        let executor = FakeProtonCLIExecutor()
        await stubHappyPath(executor)
        let service = makeService(executor: executor)

        guard case .success(let refresh) = await service.refresh() else {
            return XCTFail("expected success")
        }
        let projection = try XCTUnwrap(refresh.projections.first)

        // The await is hoisted: XCTUnwrap takes an autoclosure, which cannot
        // carry an async call.
        let fetched = await service.content(shareID: "S1", itemID: "i1")
        let content = try XCTUnwrap(fetched)
        XCTAssertEqual(content.password, "VSQ-secret")

        let detail = try XCTUnwrap(
            service.detail(for: projection.id, snapshot: refresh.snapshot, content: content)
        )
        let password = try XCTUnwrap(detail.fields.first { $0.label == "Password" })
        XCTAssertEqual(password.value, "VSQ-secret")
        XCTAssertEqual(password.kind, .secret)
    }

    /// The version gate is a security control, so the on-demand read runs it
    /// too: an unadmitted CLI yields no content rather than parsed output.
    func testContentFailsClosedOnAnUnsupportedVersion() async {
        let executor = FakeProtonCLIExecutor()
        await stubHappyPath(executor)
        let service = makeService(executor: executor, supported: ["9.9.9"])
        let content = await service.content(shareID: "S1", itemID: "i1")
        XCTAssertNil(content)
    }

    func testRefreshReportsCLINotInstalled() async {
        let executor = FakeProtonCLIExecutor()
        let service = makeService(executor: executor, installed: false)
        let result = await service.refresh()
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .cliNotInstalled)
    }

    func testRefreshReportsUnsupportedVersion() async {
        let executor = FakeProtonCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "proton-pass 2.2.5\n")
        let service = makeService(executor: executor, supported: ["2.2.4"])
        let result = await service.refresh()
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .unsupportedVersion("2.2.5"))
    }

    func testRefreshTreatsAVaultListFailureAsNotAuthenticated() async {
        let executor = FakeProtonCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "2.2.4")
        await executor.stub(arguments: ["vault", "list", "--output", "json"], stdout: Data(), exitCode: 1)
        let service = makeService(executor: executor)
        let result = await service.refresh()
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .notAuthenticated)
    }

    func testRefreshReportsUnreadableOutput() async {
        let executor = FakeProtonCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "2.2.4")
        await executor.stub(arguments: ["vault", "list", "--output", "json"], stdout: "not json")
        let service = makeService(executor: executor)
        let result = await service.refresh()
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .unreadableOutput)
    }

    func testProbeStatusReadyWhenAuthenticated() async {
        let executor = FakeProtonCLIExecutor()
        await stubHappyPath(executor)
        let service = makeService(executor: executor)
        let status = await service.probeStatus()
        XCTAssertEqual(
            status,
            .ready(version: "2.2.4", approvedPath: approvedPath, resolvedRealPath: approvedPath)
        )
    }

    func testProbeStatusNotInstalled() async {
        let service = makeService(executor: FakeProtonCLIExecutor(), installed: false)
        let status = await service.probeStatus()
        XCTAssertEqual(status, .notInstalled)
    }

    func testProbeStatusNotAuthenticated() async {
        let executor = FakeProtonCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "2.2.4")
        await executor.stub(arguments: ["vault", "list", "--output", "json"], stdout: Data(), exitCode: 1)
        let service = makeService(executor: executor)
        let status = await service.probeStatus()
        XCTAssertEqual(status, .notAuthenticated)
    }

    func testProbeStatusUnsupportedVersion() async {
        let executor = FakeProtonCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "9.9.9")
        let service = makeService(executor: executor, supported: ["2.2.4"])
        let status = await service.probeStatus()
        XCTAssertEqual(status, .unsupportedVersion("9.9.9"))
    }
}
