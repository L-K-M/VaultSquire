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

    func testRefreshListsHydratesAndSealsASnapshot() async throws {
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

        // The hydrated secret is present in the detail and marked secret.
        let detail = try XCTUnwrap(service.detail(for: projection.id, snapshot: refresh.snapshot))
        let password = try XCTUnwrap(detail.fields.first { $0.label == "Password" })
        XCTAssertEqual(password.value, "VSQ-secret")
        XCTAssertEqual(password.kind, .secret)

        // The snapshot was sealed to the cache and reopens equal.
        let cached = try XCTUnwrap(service.cachedSnapshot())
        XCTAssertEqual(cached, refresh.snapshot)
        XCTAssertTrue(cached.lossy)
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
