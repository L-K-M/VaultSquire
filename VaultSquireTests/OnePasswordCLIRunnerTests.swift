import XCTest
@testable import VaultSquire

final class OnePasswordCLIRunnerTests: XCTestCase {
    private let binary = OnePasswordCLIBinary(
        approvedPath: "/usr/local/bin/op",
        resolvedRealPath: "/opt/homebrew/Cellar/1password-cli/2.38.1/bin/op"
    )

    private func makeRunner(
        executor: FakeCLIExecutor,
        supported: Set<String> = ["2.38.1"],
        account: String? = nil
    ) -> OnePasswordCLIRunner {
        OnePasswordCLIRunner(
            binary: binary,
            executor: executor,
            versionGate: OnePasswordCLIVersionGate(supportedVersions: supported),
            accountID: account
        )
    }

    func testProbeVersionParsesAndAdmitsASupportedVersion() async throws {
        let executor = FakeCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "2.38.1\n")
        let runner = makeRunner(executor: executor)

        let version = try await runner.probeVersion()
        XCTAssertEqual(version, OnePasswordCLIVersion(raw: "2.38.1"))

        // Execution is bound to the resolved target that was shown for review,
        // not to a friendly symlink that can be retargeted afterward.
        let urls = await executor.recordedExecutableURLs
        XCTAssertEqual(
            urls.first?.path,
            "/opt/homebrew/Cellar/1password-cli/2.38.1/bin/op"
        )
    }

    func testProbeVersionRejectsAnUnsupportedVersion() async {
        let executor = FakeCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "2.39.0\n")
        let runner = makeRunner(executor: executor, supported: ["2.38.1"])

        await XCTAssertThrowsErrorAsync(try await runner.probeVersion()) { error in
            XCTAssertEqual(error as? OnePasswordCLIRunnerError, .unsupportedVersion("2.39.0"))
        }
    }

    func testProbeVersionReportsUnparseableOutput() async {
        let executor = FakeCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "no version here\n")
        let runner = makeRunner(executor: executor)

        await XCTAssertThrowsErrorAsync(try await runner.probeVersion()) { error in
            XCTAssertEqual(error as? OnePasswordCLIRunnerError, .unparseableVersion)
        }
    }

    /// `--version` describes the binary, not an account, so it is the one
    /// command that is never account-scoped.
    func testVersionProbeIsNotAccountScoped() async throws {
        let executor = FakeCLIExecutor()
        await executor.stub(arguments: ["--version"], stdout: "2.38.1")
        let runner = makeRunner(executor: executor, account: "ACCOUNT1")

        _ = try await runner.probeVersion()
        let recorded = await executor.recordedArguments
        XCTAssertEqual(recorded.first, ["--version"])
    }

    func testReadCommandsCarryTheDocumentedJSONSwitch() async throws {
        let executor = FakeCLIExecutor()
        await executor.stub(arguments: ["account", "list", "--format", "json"], stdout: "[]")
        await executor.stub(arguments: ["vault", "list", "--format", "json"], stdout: "[]")
        await executor.stub(
            arguments: ["item", "list", "--vault", "VAULT1", "--format", "json"], stdout: "[]"
        )
        let runner = makeRunner(executor: executor)

        _ = try await runner.accountListJSON()
        _ = try await runner.vaultListJSON()
        _ = try await runner.itemListJSON(vaultID: "VAULT1")

        let recorded = await executor.recordedArguments
        XCTAssertEqual(recorded, [
            ["account", "list", "--format", "json"],
            ["vault", "list", "--format", "json"],
            ["item", "list", "--vault", "VAULT1", "--format", "json"]
        ])
    }

    /// `account list` is what discovers which accounts exist, so it is the one
    /// read that must never be scoped to one of them.
    func testAccountListIsNeverAccountScoped() async throws {
        let executor = FakeCLIExecutor()
        await executor.stub(arguments: ["account", "list", "--format", "json"], stdout: "[]")
        let runner = makeRunner(executor: executor, account: "ACCOUNT1")

        _ = try await runner.accountListJSON()
        let recorded = await executor.recordedArguments
        XCTAssertEqual(recorded.first, ["account", "list", "--format", "json"])
    }

    /// `op whoami` is a status query: it reports "not signed in" instead of
    /// starting the authorization ceremony, so it must not exist as a probe.
    /// A real read is what raises the prompt.
    func testTheRunnerExposesNoWhoAmIProbe() async throws {
        let executor = FakeCLIExecutor()
        await executor.stub(arguments: ["vault", "list", "--format", "json"], stdout: "[]")
        let runner = makeRunner(executor: executor)

        _ = try await runner.vaultListJSON()
        let recorded = await executor.recordedArguments
        XCTAssertFalse(recorded.contains { $0.contains("whoami") })
    }

    /// Concealed fields are masked by default and the docs never state whether
    /// that masking applies to JSON, so `--reveal` is passed rather than relying
    /// on undocumented behavior.
    func testItemGetRequestsRevealedFieldsByValidatedIdentifiers() async throws {
        let executor = FakeCLIExecutor()
        let expected = [
            "item", "get", "ITEM1", "--vault", "VAULT1", "--format", "json", "--reveal"
        ]
        await executor.stub(arguments: expected, stdout: "{}")
        let runner = makeRunner(executor: executor)

        _ = try await runner.itemGetJSON(itemID: "ITEM1", vaultID: "VAULT1")
        let recorded = await executor.recordedArguments
        XCTAssertEqual(recorded.first, expected)
    }

    /// 1Password's own reference pages disagree on what "the default account"
    /// means, so every account-bearing command names one explicitly.
    func testResolvedAccountScopesEveryReadCommand() async throws {
        let executor = FakeCLIExecutor()
        let expected = ["vault", "list", "--format", "json", "--account", "ACCOUNT1"]
        await executor.stub(arguments: expected, stdout: "[]")
        let runner = makeRunner(executor: executor).scoped(toAccount: "ACCOUNT1")

        _ = try await runner.vaultListJSON()
        let recorded = await executor.recordedArguments
        XCTAssertEqual(recorded.first, expected)
    }

    /// An account identifier from CLI output must not reach argv unvetted.
    /// argv. An identifier that fails validation is dropped and the command
    /// falls back to unscoped rather than passing an unvetted string.
    func testAnUnvettedAccountIdentifierIsDroppedRatherThanPassed() async throws {
        let executor = FakeCLIExecutor()
        await executor.stub(arguments: ["vault", "list", "--format", "json"], stdout: "[]")
        let runner = makeRunner(executor: executor).scoped(toAccount: "--not an id")

        XCTAssertNil(runner.accountID)
        _ = try await runner.vaultListJSON()
        let recorded = await executor.recordedArguments
        XCTAssertEqual(recorded.first, ["vault", "list", "--format", "json"])
    }

    func testNonZeroExitBecomesCommandFailed() async {
        let executor = FakeCLIExecutor()
        await executor.stub(
            arguments: ["account", "list", "--format", "json"], stdout: Data(), exitCode: 1
        )
        let runner = makeRunner(executor: executor)

        await XCTAssertThrowsErrorAsync(try await runner.accountListJSON()) { error in
            XCTAssertEqual(error as? OnePasswordCLIRunnerError, .commandFailed(1))
        }
    }

    func testExecutorErrorIsWrapped() async {
        let executor = FakeCLIExecutor()
        await executor.stub(arguments: ["vault", "list", "--format", "json"], error: .timedOut)
        let runner = makeRunner(executor: executor)

        await XCTAssertThrowsErrorAsync(try await runner.vaultListJSON()) { error in
            XCTAssertEqual(error as? OnePasswordCLIRunnerError, .execution(.timedOut))
        }
    }

    func testItemListRejectsAnInvalidVaultIdentifierBeforeRunning() async {
        let executor = FakeCLIExecutor()
        let runner = makeRunner(executor: executor)

        await XCTAssertThrowsErrorAsync(try await runner.itemListJSON(vaultID: "--help")) { error in
            XCTAssertEqual(error as? OnePasswordCLIRunnerError, .invalidIdentifier)
        }
        // No command was constructed for the rejected identifier.
        let recorded = await executor.recordedArguments
        XCTAssertTrue(recorded.isEmpty)
    }

    func testItemGetRejectsAnInvalidItemIdentifierBeforeRunning() async {
        let executor = FakeCLIExecutor()
        let runner = makeRunner(executor: executor)

        await XCTAssertThrowsErrorAsync(
            try await runner.itemGetJSON(itemID: "-rf", vaultID: "VAULT1")
        ) { error in
            XCTAssertEqual(error as? OnePasswordCLIRunnerError, .invalidIdentifier)
        }
        let recorded = await executor.recordedArguments
        XCTAssertTrue(recorded.isEmpty)
    }

    func testIdentifierValidationRules() {
        XCTAssertTrue(
            OnePasswordCLIRunner.isValidOpaqueIdentifier("kiramv6tpjijkuci7fig4lndta")
        )
        XCTAssertTrue(OnePasswordCLIRunner.isValidOpaqueIdentifier("IU2OKUBKAFGQPFPFZEG7X3NQ4U"))
        XCTAssertFalse(OnePasswordCLIRunner.isValidOpaqueIdentifier(""))
        XCTAssertFalse(OnePasswordCLIRunner.isValidOpaqueIdentifier("-leadingDash"))
        XCTAssertFalse(OnePasswordCLIRunner.isValidOpaqueIdentifier("has space"))
        XCTAssertFalse(OnePasswordCLIRunner.isValidOpaqueIdentifier("semi;colon"))
        // A sign-in address is not an opaque identifier; it must not reach argv.
        XCTAssertFalse(OnePasswordCLIRunner.isValidOpaqueIdentifier("my.1password.com"))
        XCTAssertFalse(
            OnePasswordCLIRunner.isValidOpaqueIdentifier(String(repeating: "a", count: 257))
        )
    }

    func testLocatorPicksTheFirstExecutableAllowlistedPath() {
        let locator = OnePasswordCLILocator(
            candidatePaths: ["/usr/local/bin/op", "/opt/homebrew/bin/op"],
            isExecutable: { $0 == "/opt/homebrew/bin/op" },
            resolveRealPath: { _ in "/opt/homebrew/Cellar/1password-cli/2.38.1/bin/op" }
        )
        let located = locator.locate()
        XCTAssertEqual(located?.approvedPath, "/opt/homebrew/bin/op")
        XCTAssertEqual(
            located?.resolvedRealPath, "/opt/homebrew/Cellar/1password-cli/2.38.1/bin/op"
        )
    }

    func testLocatorReturnsNilWhenNothingIsExecutable() {
        let locator = OnePasswordCLILocator(
            candidatePaths: ["/usr/local/bin/op"],
            isExecutable: { _ in false },
            resolveRealPath: { $0 }
        )
        XCTAssertNil(locator.locate())
    }

    /// `/usr/local/bin/op` must be tried first: it is the `.pkg` default, the
    /// path the upgrade instructions require, and the only location older
    /// 1Password for Mac builds will talk to.
    func testDefaultCandidatePathsPreferTheDocumentedInstallLocation() {
        let paths = OnePasswordCLILocator.defaultCandidatePaths()
        XCTAssertEqual(paths.first, "/usr/local/bin/op")
        XCTAssertTrue(paths.contains("/opt/homebrew/bin/op"))
        XCTAssertTrue(paths.allSatisfy { $0.hasPrefix("/") })
        XCTAssertTrue(paths.allSatisfy { $0.hasSuffix("/op") })
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
