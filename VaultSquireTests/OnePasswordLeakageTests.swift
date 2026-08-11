import CryptoKit
import XCTest
@testable import VaultSquire

/// The 1Password CLI boundary's secret-handling contract, asserted end to end.
///
/// ONEPASSWORD_CLI_RESEARCH.md §4 and §12 bind this provider to one
/// authentication mode and one set of prohibited channels. These tests are the
/// executable form of those rules: argv, the environment, and anything that
/// rests on disk must never carry a secret. Fixtures are synthetic and every
/// secret-looking value is prefixed `VSQ-` so a single search covers them all.
final class OnePasswordLeakageTests: XCTestCase {
    private let approvedPath = "/usr/local/bin/op"
    private static let secrets = ["VSQ-password", "VSQ-recovery", "VSQOTPSEED"]

    // MARK: - Environment

    /// The base environment is an allowlist, not a filter, so a secret-bearing
    /// variable the app inherited can never reach a child process. Manual
    /// sign-in and service accounts both deliver their credential through one
    /// of these, which is exactly why neither mode is supported.
    func testTheChildEnvironmentCarriesNoSessionOrTokenVariable() async {
        let executor = CLIProcessExecutor(mode: .onePasswordDesktopAuthorization)
        let environment = await executor.childEnvironment()

        for prohibited in [
            "OP_SESSION", "OP_SERVICE_ACCOUNT_TOKEN", "OP_CONNECT_HOST", "OP_CONNECT_TOKEN"
        ] {
            XCTAssertNil(environment[prohibited], "\(prohibited) must never reach the CLI")
        }
        // The whole environment is a fixed set; nothing else can slip in.
        XCTAssertTrue(
            Set(environment.keys).isSubset(of: [
                "LANG", "LC_ALL", "PATH", "HOME", "OP_BIOMETRIC_UNLOCK_ENABLED"
            ]),
            "unexpected environment keys: \(Set(environment.keys))"
        )
    }

    /// Desktop-app integration is the only authentication mode VaultSquire
    /// permits, and this is the documented switch that selects it.
    func testTheProductionExecutorPinsDesktopAppAuthentication() async throws {
        let executor = try XCTUnwrap(
            OnePasswordAccountService.makeExecutor() as? CLIProcessExecutor
        )
        let environment = await executor.childEnvironment()
        XCTAssertEqual(environment["OP_BIOMETRIC_UNLOCK_ENABLED"], "true")
    }

    // MARK: - Arguments

    /// No secret, and no user-authored value, may appear in argv. A full
    /// refresh plus an on-demand item read exercises every command the provider
    /// can issue.
    func testNoSecretReachesArgvAcrossAFullReadCycle() async throws {
        let executor = FakeCLIExecutor()
        await stubHappyPath(executor)
        let service = makeService(executor: executor)

        guard case .success = await service.refresh(accountUUID: "ACCOUNT1") else {
            return XCTFail("expected success")
        }
        let content = await service.content(
            itemID: "ITEM1", vaultID: "VAULT1", accountUUID: "ACCOUNT1"
        )
        XCTAssertEqual(try XCTUnwrap(content).password, "VSQ-password")

        let recorded = await executor.recordedArguments
        XCTAssertFalse(recorded.isEmpty)
        for arguments in recorded {
            for argument in arguments {
                for secret in Self.secrets {
                    XCTAssertFalse(
                        argument.contains(secret),
                        "secret reached argv in \(arguments)"
                    )
                }
            }
        }
    }

    /// Every argument is either a fixed subcommand, a fixed switch, or a
    /// validated opaque identifier — never a user-chosen vault or item name,
    /// which 1Password's selectors would otherwise accept.
    func testEveryArgumentIsAFixedTokenOrAValidatedIdentifier() async throws {
        let executor = FakeCLIExecutor()
        await stubHappyPath(executor)
        let service = makeService(executor: executor)

        guard case .success = await service.refresh(accountUUID: "ACCOUNT1") else {
            return XCTFail("expected success")
        }
        _ = await service.content(
            itemID: "ITEM1", vaultID: "VAULT1", accountUUID: "ACCOUNT1"
        )

        let fixedTokens: Set<String> = [
            "--version", "account", "vault", "list", "item", "get",
            "--vault", "--format", "json", "--reveal", "--account"
        ]
        let identifiers: Set<String> = ["ACCOUNT1", "VAULT1", "ITEM1"]
        let recorded = await executor.recordedArguments
        for arguments in recorded {
            for argument in arguments {
                XCTAssertTrue(
                    fixedTokens.contains(argument) || identifiers.contains(argument),
                    "\(argument) is neither a fixed token nor a validated identifier"
                )
                if identifiers.contains(argument) {
                    XCTAssertTrue(OnePasswordCLIRunner.isValidOpaqueIdentifier(argument))
                }
            }
        }
    }

    /// The item title is a user-authored value. It is displayed, never passed
    /// to the CLI, because `op item get` would happily accept it as a selector.
    func testAUserAuthoredTitleIsNeverUsedAsASelector() async throws {
        let executor = FakeCLIExecutor()
        await stubHappyPath(executor)
        let service = makeService(executor: executor)

        guard case .success(let refresh) = await service.refresh(accountUUID: "ACCOUNT1") else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(refresh.projections.first?.displayTitle, "Example Service")

        let recorded = await executor.recordedArguments
        for arguments in recorded {
            XCTAssertFalse(arguments.contains("Example Service"))
        }
    }

    // MARK: - At rest

    /// A refresh seals a snapshot. Nothing secret may be in it, because the
    /// snapshot is the only 1Password data that rests on this Mac.
    func testTheSealedSnapshotHoldsNoSecret() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultSquire1PLeak-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let cache = OnePasswordSnapshotCache(keyProvider: { key }, directory: directory)

        let executor = FakeCLIExecutor()
        await stubHappyPath(executor)
        let service = makeService(executor: executor, cache: cache)

        guard case .success(let refresh) = await service.refresh(accountUUID: "ACCOUNT1") else {
            return XCTFail("expected success")
        }

        // Opening an item must not change what rests: content is in-memory only.
        _ = await service.content(
            itemID: "ITEM1", vaultID: "VAULT1", accountUUID: "ACCOUNT1"
        )

        let reloaded = try XCTUnwrap(
            cache.load(for: OnePasswordAccountService.vaultIdentity(for: "ACCOUNT1"))
        )
        XCTAssertEqual(reloaded, refresh.snapshot)
        let decoded = String(decoding: try JSONEncoder().encode(reloaded), as: UTF8.self)
        for secret in Self.secrets {
            XCTAssertFalse(decoded.contains(secret), "\(secret) was sealed into the snapshot")
        }

        // And the bytes on disk are the sealed envelope, not readable JSON.
        let file = try XCTUnwrap(
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ))?.first
        )
        let raw = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        for secret in Self.secrets {
            XCTAssertFalse(raw.contains(secret))
        }
        XCTAssertFalse(raw.contains("Example Service"))
    }

    // MARK: - Support

    private func makeService(
        executor: FakeCLIExecutor,
        cache: OnePasswordSnapshotCache? = nil
    ) -> OnePasswordAccountService {
        OnePasswordAccountService(
            locator: OnePasswordCLILocator(
                candidatePaths: [approvedPath],
                isExecutable: { _ in true },
                resolveRealPath: { $0 }
            ),
            executor: executor,
            versionGate: OnePasswordCLIVersionGate(supportedVersions: ["2.38.1"]),
            cache: cache ?? makeCache(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    /// A cache in a fresh temporary directory, removed when the test finishes.
    private func makeCache() -> OnePasswordSnapshotCache {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultSquire1PLeak-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        return OnePasswordSnapshotCache(keyProvider: { key }, directory: directory)
    }

    private func stubHappyPath(_ executor: FakeCLIExecutor) async {
        await executor.stub(arguments: ["--version"], stdout: "2.38.1\n")
        await executor.stub(
            arguments: ["account", "list", "--format", "json"],
            stdout: #"[{"url":"my.1password.com","account_uuid":"ACCOUNT1"}]"#
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
            {"id":"ITEM1","title":"Example Service","category":"LOGIN","fields":[
              {"id":"password","type":"CONCEALED","purpose":"PASSWORD",
               "label":"password","value":"VSQ-password"},
              {"id":"totp","type":"OTP","label":"one-time password",
               "value":"otpauth://totp/Example?secret=VSQOTPSEED"},
              {"id":"rk","type":"CONCEALED","label":"recovery key","value":"VSQ-recovery"}
            ]}
            """
        )
    }
}
