import CryptoKit
import XCTest
@testable import VaultSquire

@MainActor
final class AddAccountModelTests: XCTestCase {
    private let device = VaultwardenDeviceIdentity(
        identifier: "VSQ-Canary-device", name: "VSQ-Canary Mac"
    )

    override func setUp() {
        super.setUp()
        StubServer.shared.reset()
    }

    override func tearDown() {
        StubServer.shared.reset()
        super.tearDown()
    }

    private func makeModel(
        store: any VaultwardenCredentialStore,
        onAccountConfigured: @escaping @MainActor (URL) -> Void = { _ in }
    ) -> AddAccountModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return AddAccountModel(
            credentialStore: store,
            deviceIdentity: device,
            makeTransport: { environment in
                VaultwardenTransport(environment: environment, session: session)
            },
            onAccountConfigured: onAccountConfigured,
            accountService: makeIsolatedAccountService()
        )
    }

    /// A completing sign-in persists a descriptor and seeds the sealed vault.
    /// Those must land in throwaway stores: the default service writes to the
    /// app's real UserDefaults and Application Support, and a descriptor left
    /// there makes the app launch into the vault browser — which the UI tests,
    /// running later in the same job, see instead of the locked shell.
    private func makeIsolatedAccountService() -> VaultwardenAccountService {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VSQ-addaccount-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let defaults = UserDefaults(suiteName: "VSQ-addaccount-\(UUID().uuidString)")!
        return VaultwardenAccountService(
            credentialStore: InMemoryCredentialStore(),
            vaultCache: VaultwardenVaultCache(keyProvider: { key }, directory: directory),
            descriptorStore: AccountDescriptorStore(defaults: defaults)
        )
    }

    private func stubSuccessfulLogin() {
        StubServer.shared.on("/api/config", respond: .json(200, "{\"version\":\"2026.6.0\"}"))
        StubServer.shared.on(
            "/accounts/prelogin/password",
            respond: .json(200, "{\"Kdf\":0,\"KdfIterations\":100000}")
        )
        StubServer.shared.on(
            "/connect/token",
            respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"VSQ-refresh\",\"TwoFactorToken\":null}")
        )
    }

    func testSuccessfulSignInStoresCredentialsAndClearsPassword() async {
        let store = InMemoryCredentialStore()
        let model = makeModel(store: store)
        stubSuccessfulLogin()

        model.serverURL = "https://vault.example.com"
        model.email = "VSQ-Canary-User@Example.com"
        model.masterPassword = "VSQ-Canary-Master-Password"
        await model.signIn()

        XCTAssertEqual(model.phase, .succeeded)
        XCTAssertEqual(model.masterPassword, "", "master password must be cleared")
        XCTAssertEqual(
            store.record(for: .primary)?.refreshToken, "VSQ-refresh"
        )
    }

    func testSuccessfulSignInReportsAccountConfiguredOnce() async {
        var configured: [URL] = []
        let model = makeModel(store: InMemoryCredentialStore()) { configured.append($0) }
        stubSuccessfulLogin()

        model.serverURL = "https://vault.example.com"
        model.email = "user@example.com"
        model.masterPassword = "pw"
        await model.signIn()

        XCTAssertEqual(configured.map(\.absoluteString), ["https://vault.example.com"])
    }

    func testFailedSignInNeverReportsAccountConfigured() async {
        let model = makeModel(store: InMemoryCredentialStore()) { _ in
            XCTFail("a failed sign-in must not report a configured account")
        }
        StubServer.shared.on("/api/config", respond: .json(200, "{}"))
        StubServer.shared.on(
            "/accounts/prelogin/password",
            respond: .json(200, "{\"Kdf\":0,\"KdfIterations\":100000}")
        )
        StubServer.shared.on(
            "/connect/token",
            respond: .json(400, "{\"error\":\"invalid_grant\"}")
        )

        model.serverURL = "https://vault.example.com"
        model.email = "user@example.com"
        model.masterPassword = "pw"
        await model.signIn()

        guard case .failed = model.phase else {
            return XCTFail("expected a failed phase")
        }
    }

    func testMasterPasswordNeverReachesTheStoredRecord() async {
        let store = InMemoryCredentialStore()
        let model = makeModel(store: store)
        stubSuccessfulLogin()

        model.serverURL = "https://vault.example.com"
        model.email = "user@example.com"
        model.masterPassword = "VSQ-Canary-Master-Password"
        await model.signIn()

        let record = store.record(for: .primary)
        XCTAssertNotNil(record)
        XCTAssertNotEqual(record?.refreshToken, "VSQ-Canary-Master-Password")
        XCTAssertNil(record?.rememberedTwoFactorToken)
    }

    func testInvalidURLFailsBeforeAnyRequest() async {
        let store = InMemoryCredentialStore()
        let model = makeModel(store: store)

        model.serverURL = "http://insecure.example.com"
        model.email = "user@example.com"
        model.masterPassword = "pw"
        await model.signIn()

        guard case .failed(let message) = model.phase else {
            return XCTFail("expected a failure")
        }
        XCTAssertTrue(message.contains("HTTPS"))
        XCTAssertTrue(StubServer.shared.requests.isEmpty, "no request should be sent")
    }

    func testWrongPasswordSurfacesAFailure() async {
        let store = InMemoryCredentialStore()
        let model = makeModel(store: store)
        StubServer.shared.on("/api/config", respond: .json(200, "{}"))
        StubServer.shared.on(
            "/accounts/prelogin/password",
            respond: .json(200, "{\"Kdf\":0,\"KdfIterations\":100000}")
        )
        StubServer.shared.on(
            "/connect/token",
            respond: .json(400, "{\"error\":\"invalid_grant\",\"error_description\":\"Bad credentials.\"}")
        )

        model.serverURL = "https://vault.example.com"
        model.email = "user@example.com"
        model.masterPassword = "wrong"
        await model.signIn()

        guard case .failed = model.phase else {
            return XCTFail("expected a failure")
        }
        XCTAssertNil(store.record(for: .primary))
    }

    func testMissingRefreshTokenFailsRatherThanReportingSuccess() async {
        let store = InMemoryCredentialStore()
        let model = makeModel(store: store)
        StubServer.shared.on("/api/config", respond: .json(200, "{}"))
        StubServer.shared.on(
            "/accounts/prelogin/password",
            respond: .json(200, "{\"Kdf\":0,\"KdfIterations\":100000}")
        )
        StubServer.shared.on(
            "/connect/token",
            respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":null,\"TwoFactorToken\":null}")
        )

        model.serverURL = "https://vault.example.com"
        model.email = "user@example.com"
        model.masterPassword = "pw"
        await model.signIn()

        guard case .failed = model.phase else {
            return XCTFail("a session without a refresh token must not report success")
        }
        XCTAssertNil(store.record(for: .primary), "nothing durable should be stored")
    }

    func testCredentialStoreFailureIsReportedAsASaveFailureNotABadPassword() async {
        let model = makeModel(store: FailingCredentialStore())
        stubSuccessfulLogin()

        model.serverURL = "https://vault.example.com"
        model.email = "user@example.com"
        model.masterPassword = "pw"
        await model.signIn()

        guard case .failed(let message) = model.phase else {
            return XCTFail("a credential-store failure must surface as a failure")
        }
        XCTAssertTrue(
            message.contains("could not be saved"),
            "the message should indicate a save failure, not a rejected password"
        )
    }

    func testTwoFactorChallengeThenSuccessStoresRememberedToken() async {
        let store = InMemoryCredentialStore()
        let model = makeModel(store: store)
        StubServer.shared.on("/api/config", respond: .json(200, "{}"))
        StubServer.shared.on(
            "/accounts/prelogin/password",
            respond: .json(200, "{\"Kdf\":0,\"KdfIterations\":100000}")
        )
        // Two /connect/token responses served in FIFO order: the 2FA challenge
        // first, then the success.
        StubServer.shared.on(
            "/connect/token",
            respond: .json(400, "{\"TwoFactorProviders2\":{\"0\":{}}}")
        )
        StubServer.shared.on(
            "/connect/token",
            respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"r2\",\"TwoFactorToken\":\"VSQ-remember\"}")
        )

        model.serverURL = "https://vault.example.com"
        model.email = "user@example.com"
        model.masterPassword = "pw"
        await model.signIn()

        XCTAssertEqual(model.phase, .challenged)
        XCTAssertEqual(model.offeredProviders, [.authenticator])
        XCTAssertFalse(model.hasUnsupportedOnlyChallenge)
        XCTAssertEqual(
            model.masterPassword, "", "master password must be cleared even when challenged"
        )

        model.twoFactorCode = "123456"
        model.rememberDevice = true
        await model.submitTwoFactor()

        XCTAssertEqual(model.phase, .succeeded)
        XCTAssertEqual(store.record(for: .primary)?.refreshToken, "r2")
        XCTAssertEqual(
            store.record(for: .primary)?.rememberedTwoFactorToken, "VSQ-remember"
        )
    }

    func testTwoFactorSuccessWithoutRememberDoesNotStoreRememberedToken() async {
        let store = InMemoryCredentialStore()
        let model = makeModel(store: store)
        StubServer.shared.on("/api/config", respond: .json(200, "{}"))
        StubServer.shared.on(
            "/accounts/prelogin/password",
            respond: .json(200, "{\"Kdf\":0,\"KdfIterations\":100000}")
        )
        // Two /connect/token responses served in FIFO order: challenge first,
        // then success.
        StubServer.shared.on(
            "/connect/token",
            respond: .json(400, "{\"TwoFactorProviders2\":{\"0\":{}}}")
        )
        // When the device is not remembered the server issues no remember
        // token, so none is persisted.
        StubServer.shared.on(
            "/connect/token",
            respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"r2\",\"TwoFactorToken\":null}")
        )

        model.serverURL = "https://vault.example.com"
        model.email = "user@example.com"
        model.masterPassword = "pw"
        await model.signIn()
        XCTAssertEqual(model.phase, .challenged)
        XCTAssertEqual(model.masterPassword, "", "master password must be cleared even when challenged")

        model.twoFactorCode = "123456"
        model.rememberDevice = false
        await model.submitTwoFactor()

        XCTAssertEqual(model.phase, .succeeded)
        XCTAssertEqual(store.record(for: .primary)?.refreshToken, "r2")
        XCTAssertNil(store.record(for: .primary)?.rememberedTwoFactorToken)
    }

    func testUnsupportedOnlyChallengeIsFlagged() async {
        let store = InMemoryCredentialStore()
        let model = makeModel(store: store)
        StubServer.shared.on("/api/config", respond: .json(200, "{}"))
        StubServer.shared.on(
            "/accounts/prelogin/password",
            respond: .json(200, "{\"Kdf\":0,\"KdfIterations\":100000}")
        )
        StubServer.shared.on(
            "/connect/token",
            respond: .json(400, "{\"TwoFactorProviders2\":{\"2\":{},\"7\":{}}}")
        )

        model.serverURL = "https://vault.example.com"
        model.email = "user@example.com"
        model.masterPassword = "pw"
        await model.signIn()

        XCTAssertEqual(model.phase, .challenged)
        XCTAssertTrue(model.hasUnsupportedOnlyChallenge)
        XCTAssertTrue(model.offeredProviders.isEmpty)
    }

    func testSubmitTwoFactorWithoutAChallengeShowsFeedback() async {
        let model = makeModel(store: InMemoryCredentialStore())

        // No challenge was ever presented, so the state is inconsistent.
        await model.submitTwoFactor()

        XCTAssertNotNil(model.failureMessage)
    }

    func testReturnToFormPreservesNonSecretFields() async {
        let store = InMemoryCredentialStore()
        let model = makeModel(store: store)
        StubServer.shared.on("/api/config", respond: .json(200, "{}"))
        StubServer.shared.on(
            "/accounts/prelogin/password",
            respond: .json(200, "{\"Kdf\":0,\"KdfIterations\":100000}")
        )
        StubServer.shared.on(
            "/connect/token",
            respond: .json(400, "{\"TwoFactorProviders2\":{\"0\":{}}}")
        )

        model.serverURL = "https://vault.example.com"
        model.email = "user@example.com"
        model.masterPassword = "pw"
        await model.signIn()
        XCTAssertEqual(model.phase, .challenged)

        model.returnToForm()

        XCTAssertEqual(model.phase, .editing)
        XCTAssertEqual(model.serverURL, "https://vault.example.com")
        XCTAssertEqual(model.email, "user@example.com")
        XCTAssertEqual(model.masterPassword, "", "master password must remain cleared after returning to the form")
        XCTAssertTrue(model.offeredProviders.isEmpty)
    }

    // MARK: - Effective-origin approval

    /// Stubs a server whose config advertises the identity service on a
    /// different https origin, plus the endpoints a fully approved login needs.
    private func stubCrossOriginServer() {
        StubServer.shared.on(
            "/api/config",
            respond: .json(200, "{\"environment\":{\"identity\":\"https://identity.other.com\"}}")
        )
        StubServer.shared.on(
            "/accounts/prelogin/password",
            respond: .json(200, "{\"Kdf\":0,\"KdfIterations\":100000}")
        )
        StubServer.shared.on(
            "/connect/token",
            respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"VSQ-refresh\",\"TwoFactorToken\":null}")
        )
    }

    private func beginCrossOriginSignIn(_ model: AddAccountModel) {
        model.serverURL = "https://vault.example.com"
        model.email = "user@example.com"
        model.masterPassword = "pw"
        model.beginSignIn()
    }

    /// Waits until the condition holds, sleeping briefly between checks so the
    /// suspended sign-in task can make progress on the main actor. Bounded so
    /// a regression fails the test instead of hanging it.
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    func testDifferingEffectiveOriginPresentsApprovalBeforeAnyCredentialLeaves() async {
        let model = makeModel(store: InMemoryCredentialStore())
        stubCrossOriginServer()

        beginCrossOriginSignIn(model)

        let presented = await waitUntil { model.originApproval != nil }
        XCTAssertTrue(presented, "a differing https origin must surface an approval request")
        XCTAssertEqual(model.originApproval?.entered.host, "vault.example.com")
        XCTAssertEqual(model.originApproval?.effectiveIdentity.host, "identity.other.com")
        // While the decision is pending, nothing credential-bearing was sent.
        XCTAssertNil(StubServer.shared.lastRequest(pathSuffix: "/accounts/prelogin/password"))

        model.cancel()
    }

    func testDecliningOriginApprovalFailsClosedWithoutPrelogin() async {
        let store = InMemoryCredentialStore()
        let model = makeModel(store: store)
        stubCrossOriginServer()

        beginCrossOriginSignIn(model)
        let presented = await waitUntil { model.originApproval != nil }
        XCTAssertTrue(presented)

        model.resolveOriginApproval(approved: false)

        let failed = await waitUntil {
            if case .failed = model.phase { return true }
            return false
        }
        XCTAssertTrue(failed, "a declined origin must fail closed")
        // Prelogin (carrying the email) was never sent, and nothing persisted.
        XCTAssertNil(StubServer.shared.lastRequest(pathSuffix: "/accounts/prelogin/password"))
        XCTAssertNil(store.record(for: .primary))
    }

    func testApprovedOriginProceedsAgainstTheAdvertisedHostAndStores() async {
        let store = InMemoryCredentialStore()
        let model = makeModel(store: store)
        stubCrossOriginServer()

        beginCrossOriginSignIn(model)
        let presented = await waitUntil { model.originApproval != nil }
        XCTAssertTrue(presented)

        model.resolveOriginApproval(approved: true)

        let succeeded = await waitUntil { model.phase == .succeeded }
        XCTAssertTrue(succeeded, "an approved origin must let the login finish")
        XCTAssertNil(model.originApproval)
        XCTAssertEqual(store.record(for: .primary)?.refreshToken, "VSQ-refresh")
        // The approved advertised host actually served prelogin and the grant.
        XCTAssertEqual(
            StubServer.shared.lastRequest(pathSuffix: "/accounts/prelogin/password")?.url.host,
            "identity.other.com"
        )
        XCTAssertEqual(
            StubServer.shared.lastRequest(pathSuffix: "/connect/token")?.url.host,
            "identity.other.com"
        )
    }

    func testDismissalWhileApprovalPendingDeclinesAndSendsNothing() async {
        let store = InMemoryCredentialStore()
        let model = makeModel(store: store)
        stubCrossOriginServer()

        beginCrossOriginSignIn(model)
        let presented = await waitUntil { model.originApproval != nil }
        XCTAssertTrue(presented)

        // Sheet dismissal: the pending continuation must resolve (declined) so
        // the suspended task ends instead of leaking.
        model.cancel()

        XCTAssertNil(model.originApproval)
        // Give the resumed task a bounded moment to finish; it must send
        // nothing further and persist nothing. The cancelled task also must
        // not repaint the form with a failure.
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNil(StubServer.shared.lastRequest(pathSuffix: "/accounts/prelogin/password"))
        XCTAssertNil(store.record(for: .primary))
        XCTAssertEqual(model.phase, .connecting, "a dismissed flow leaves no stale failure behind")
    }
}
