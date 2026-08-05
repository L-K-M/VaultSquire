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
        store: any VaultwardenCredentialStore
    ) -> AddAccountModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return AddAccountModel(
            credentialStore: store,
            deviceIdentity: device,
            makeTransport: { environment in
                VaultwardenTransport(environment: environment, session: session)
            }
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
        XCTAssertTrue(model.offeredProviders.isEmpty)
    }

    func testDifferingEffectiveOriginIsRejected() async {
        let store = InMemoryCredentialStore()
        let model = makeModel(store: store)
        StubServer.shared.on(
            "/api/config",
            respond: .json(200, "{\"environment\":{\"identity\":\"https://identity.other.com\"}}")
        )
        StubServer.shared.on(
            "/accounts/prelogin/password",
            respond: .json(200, "{\"Kdf\":0,\"KdfIterations\":100000}")
        )

        model.serverURL = "https://vault.example.com"
        model.email = "user@example.com"
        model.masterPassword = "pw"
        await model.signIn()

        guard case .failed = model.phase else {
            return XCTFail("a differing effective origin must fail closed")
        }
        // Prelogin (carrying the email) was never sent.
        XCTAssertNil(StubServer.shared.lastRequest(pathSuffix: "/accounts/prelogin/password"))
    }
}
