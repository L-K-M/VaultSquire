import XCTest
@testable import VaultSquire

final class ProtonCLIRunnerTests: XCTestCase {
    private let binary = ProtonCLIBinary(
        approvedPath: "/opt/homebrew/bin/proton-pass",
        resolvedRealPath: "/opt/homebrew/Cellar/proton-pass/2.2.4/bin/proton-pass"
    )

    private func makeRunner(
        executor: FakeProtonCLIExecutor,
        supported: Set<String> = ["2.2.4"]
    ) -> ProtonCLIRunner {
        ProtonCLIRunner(
            binary: binary,
            executor: executor,
            versionGate: ProtonCLIVersionGate(supportedVersions: supported)
        )
    }

    func testProbeVersionParsesAndAdmitsASupportedVersion() async throws {
        let executor = FakeProtonCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "proton-pass 2.2.4\n")
        let runner = makeRunner(executor: executor)

        let version = try await runner.probeVersion()
        XCTAssertEqual(version, ProtonCLIVersion(raw: "2.2.4"))

        // The invoked executable is the approved absolute path, not the
        // resolved real path.
        let urls = await executor.recordedExecutableURLs
        XCTAssertEqual(urls.first?.path, "/opt/homebrew/bin/proton-pass")
    }

    func testProbeVersionRejectsAnUnsupportedVersion() async {
        let executor = FakeProtonCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "proton-pass 2.2.5\n")
        let runner = makeRunner(executor: executor, supported: ["2.2.4"])

        await XCTAssertThrowsErrorAsync(try await runner.probeVersion()) { error in
            XCTAssertEqual(error as? ProtonCLIRunnerError, .unsupportedVersion("2.2.5"))
        }
    }

    func testProbeVersionReportsUnparseableOutput() async {
        let executor = FakeProtonCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "no version\n")
        let runner = makeRunner(executor: executor)

        await XCTAssertThrowsErrorAsync(try await runner.probeVersion()) { error in
            XCTAssertEqual(error as? ProtonCLIRunnerError, .unparseableVersion)
        }
    }

    func testNonZeroExitBecomesCommandFailed() async {
        let executor = FakeProtonCLIExecutor()
        await executor.stub(arguments: ["vault", "list", "--format", "json"], stdout: Data(), exitCode: 3)
        let runner = makeRunner(executor: executor)

        await XCTAssertThrowsErrorAsync(try await runner.vaultListJSON()) { error in
            XCTAssertEqual(error as? ProtonCLIRunnerError, .commandFailed(3))
        }
    }

    func testExecutorErrorIsWrapped() async {
        let executor = FakeProtonCLIExecutor()
        await executor.stub(arguments: ["vault", "list", "--format", "json"], error: .timedOut)
        let runner = makeRunner(executor: executor)

        await XCTAssertThrowsErrorAsync(try await runner.vaultListJSON()) { error in
            XCTAssertEqual(error as? ProtonCLIRunnerError, .execution(.timedOut))
        }
    }

    func testItemListRejectsAnInvalidShareIdentifierBeforeRunning() async {
        let executor = FakeProtonCLIExecutor()
        let runner = makeRunner(executor: executor)

        await XCTAssertThrowsErrorAsync(try await runner.itemListJSON(shareID: "-rf")) { error in
            XCTAssertEqual(error as? ProtonCLIRunnerError, .invalidIdentifier)
        }
        // No command was constructed for the rejected identifier.
        let recorded = await executor.recordedArguments
        XCTAssertTrue(recorded.isEmpty)
    }

    func testItemViewBuildsTheSelectorFromValidatedIdentifiers() async throws {
        let executor = FakeProtonCLIExecutor()
        await executor.stub(
            arguments: ["item", "read", "--share-id", "SHARE1", "--item-id", "ITEM1", "--format", "json"],
            stdout: "{}"
        )
        let runner = makeRunner(executor: executor)

        _ = try await runner.itemViewJSON(shareID: "SHARE1", itemID: "ITEM1")
        let recorded = await executor.recordedArguments
        XCTAssertEqual(
            recorded.first,
            ["item", "read", "--share-id", "SHARE1", "--item-id", "ITEM1", "--format", "json"]
        )
    }

    func testIdentifierValidationRules() {
        XCTAssertTrue(ProtonCLIRunner.isValidOpaqueIdentifier("Abc-123_ZQ=="))
        XCTAssertFalse(ProtonCLIRunner.isValidOpaqueIdentifier(""))
        XCTAssertFalse(ProtonCLIRunner.isValidOpaqueIdentifier("-leadingDash"))
        XCTAssertFalse(ProtonCLIRunner.isValidOpaqueIdentifier("has space"))
        XCTAssertFalse(ProtonCLIRunner.isValidOpaqueIdentifier("semi;colon"))
        XCTAssertFalse(ProtonCLIRunner.isValidOpaqueIdentifier(String(repeating: "a", count: 257)))
    }

    func testLocatorPicksTheFirstExecutableAllowlistedPath() {
        let locator = ProtonCLILocator(
            candidatePaths: ["/opt/homebrew/bin/proton-pass", "/usr/local/bin/proton-pass"],
            isExecutable: { $0 == "/usr/local/bin/proton-pass" },
            resolveRealPath: { _ in "/usr/local/Cellar/proton-pass/2.2.4/bin/proton-pass" }
        )
        let located = locator.locate()
        XCTAssertEqual(located?.approvedPath, "/usr/local/bin/proton-pass")
        XCTAssertEqual(located?.resolvedRealPath, "/usr/local/Cellar/proton-pass/2.2.4/bin/proton-pass")
    }

    func testLocatorReturnsNilWhenNothingIsExecutable() {
        let locator = ProtonCLILocator(
            candidatePaths: ["/opt/homebrew/bin/proton-pass"],
            isExecutable: { _ in false },
            resolveRealPath: { $0 }
        )
        XCTAssertNil(locator.locate())
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
