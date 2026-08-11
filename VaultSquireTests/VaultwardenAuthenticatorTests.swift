import XCTest
@testable import VaultSquire

final class VaultwardenAuthenticatorTests: XCTestCase {
    private let device = VaultwardenDeviceIdentity(
        identifier: "VSQ-Canary-00000000-0000-0000-0000-000000000001",
        name: "VSQ-Canary Mac"
    )

    private var email: String { VaultwardenCryptoFixtures.emailRaw }
    private var passwordBytes: Data { Data(VaultwardenCryptoFixtures.password.utf8) }
    private var pbkdf2Case: (iterations: Int, masterKeyHex: String, authHashBase64: String) {
        VaultwardenCryptoFixtures.pbkdf2Cases[1] // 100_000 iterations
    }

    override func setUp() {
        super.setUp()
        StubServer.shared.reset()
    }

    override func tearDown() {
        StubServer.shared.reset()
        super.tearDown()
    }

    private func makeAuthenticator(
        kdf: VaultwardenKDFChangePolicy = ApproveAllKDFChangePolicy(),
        origin: VaultwardenOriginApprovalPolicy = ApproveAllOriginPolicy()
    ) throws -> VaultwardenAuthenticator {
        VaultwardenAuthenticator(
            transport: try VaultwardenTestFactory.stubbedTransport(),
            kdfChangePolicy: kdf,
            originApprovalPolicy: origin
        )
    }

    private func stubConfig() {
        StubServer.shared.on("/api/config", respond: .json(200, "{\"version\":\"2026.6.0\"}"))
    }

    private func stubPrelogin(kdf: Int, iterations: Int, memory: Int? = nil, parallelism: Int? = nil) {
        var json = "{\"Kdf\":\(kdf),\"KdfIterations\":\(iterations)"
        if let memory { json += ",\"KdfMemory\":\(memory)" }
        if let parallelism { json += ",\"KdfParallelism\":\(parallelism)" }
        json += "}"
        StubServer.shared.on("/accounts/prelogin/password", respond: .json(200, json))
    }

    // AUTH-01: PBKDF2 password login -> session with the wrapped user key, and
    // the wire auth hash equals the independently-derived known-answer.
    func testPBKDF2PasswordLoginSucceeds() async throws {
        stubConfig()
        stubPrelogin(kdf: 0, iterations: pbkdf2Case.iterations)
        StubServer.shared.on(
            "/connect/token",
            respond: .json(200, """
            {"access_token":"VSQ-Canary-access","refresh_token":"VSQ-Canary-refresh",\
            "expires_in":7200,"token_type":"Bearer",\
            "Key":"2.aaa|bbb|ccc","PrivateKey":"2.ddd|eee|fff"}
            """)
        )

        let authenticator = try makeAuthenticator()
        let outcome = try await authenticator.login(
            email: email,
            masterPasswordBytes: passwordBytes,
            device: device,
            lastAcceptedKDF: nil
        )

        guard case .authenticated(let session) = outcome else {
            return XCTFail("expected authenticated outcome")
        }
        XCTAssertEqual(session.refreshToken, "VSQ-Canary-refresh")
        XCTAssertEqual(session.wrappedUserKey, "2.aaa|bbb|ccc")

        let grant = try XCTUnwrap(StubServer.shared.lastRequest(pathSuffix: "/connect/token"))
        XCTAssertEqual(grant.formFields["grant_type"], "password")
        XCTAssertEqual(grant.formFields["client_id"], "desktop")
        XCTAssertEqual(grant.formFields["device_type"], "7")
        XCTAssertEqual(grant.formFields["scope"], "api offline_access")
        XCTAssertEqual(grant.formFields["username"], VaultwardenCryptoFixtures.emailNormalized)
        // The wire password field is the Base64 auth hash, never the master password.
        XCTAssertEqual(grant.formFields["password"], pbkdf2Case.authHashBase64)
        XCTAssertNotEqual(grant.formFields["password"], VaultwardenCryptoFixtures.password)
    }

    func testConfigFetchedBeforeAnyEmailIsSent() async throws {
        stubConfig()
        stubPrelogin(kdf: 0, iterations: pbkdf2Case.iterations)
        StubServer.shared.on("/connect/token", respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"r\"}"))

        _ = try await makeAuthenticator().login(
            email: email, masterPasswordBytes: passwordBytes, device: device, lastAcceptedKDF: nil
        )

        let requests = StubServer.shared.requests
        let configIndex = try XCTUnwrap(requests.firstIndex { $0.url.path.hasSuffix("/api/config") })
        let preloginIndex = try XCTUnwrap(requests.firstIndex { $0.url.path.hasSuffix("/accounts/prelogin/password") })
        XCTAssertLessThan(configIndex, preloginIndex, "config must precede prelogin")
        // The config request carried no email anywhere.
        XCTAssertFalse(requests[configIndex].bodyString.localizedCaseInsensitiveContains("example.com"))
    }

    // AUTH-02: Argon2id account fails closed at derivation (no dependency yet).
    func testArgon2idAccountFailsClosed() async throws {
        stubConfig()
        stubPrelogin(kdf: 1, iterations: 3, memory: 64, parallelism: 4)

        do {
            _ = try await makeAuthenticator().login(
                email: email, masterPasswordBytes: passwordBytes, device: device, lastAcceptedKDF: nil
            )
            XCTFail("Argon2id must fail closed")
        } catch let error as VaultwardenAPIError {
            XCTAssertEqual(error.category, .incompatibleCrypto)
        }
        // No token grant was attempted.
        XCTAssertNil(StubServer.shared.lastRequest(pathSuffix: "/connect/token"))
    }

    func testBelowFloorKDFIsRejectedBeforeDerivation() async throws {
        stubConfig()
        stubPrelogin(kdf: 0, iterations: 4_999)

        do {
            _ = try await makeAuthenticator().login(
                email: email, masterPasswordBytes: passwordBytes, device: device, lastAcceptedKDF: nil
            )
            XCTFail("below-floor iterations must be rejected")
        } catch let error as VaultwardenAPIError {
            XCTAssertEqual(error.category, .incompatibleCrypto)
        }
    }

    // AUTH-12: a KDF change from the last accepted settings requires approval.
    func testKDFChangeRequiresApproval() async throws {
        stubConfig()
        stubPrelogin(kdf: 0, iterations: pbkdf2Case.iterations)

        let lastAccepted = VaultwardenKDFConfiguration.pbkdf2SHA256(iterations: 600_000)
        do {
            _ = try await makeAuthenticator(kdf: RejectAllKDFChangePolicy()).login(
                email: email, masterPasswordBytes: passwordBytes,
                device: device, lastAcceptedKDF: lastAccepted
            )
            XCTFail("unapproved KDF change must abort")
        } catch let error as VaultwardenAPIError {
            XCTAssertEqual(error.category, .incompatibleCrypto)
        }
        XCTAssertNil(StubServer.shared.lastRequest(pathSuffix: "/connect/token"))
    }

    func testFirstLoginIsNotRoutedThroughTheKDFChangePolicy() async throws {
        stubConfig()
        stubPrelogin(kdf: 0, iterations: pbkdf2Case.iterations)
        StubServer.shared.on("/connect/token", respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"r\"}"))

        // A reject-all policy would abort if consulted; first login (no baseline)
        // must not consult it.
        let outcome = try await makeAuthenticator(kdf: RejectAllKDFChangePolicy()).login(
            email: email, masterPasswordBytes: passwordBytes, device: device, lastAcceptedKDF: nil
        )
        guard case .authenticated = outcome else {
            return XCTFail("first login should authenticate without KDF approval")
        }
    }

    func testUnchangedKDFDoesNotRequireApproval() async throws {
        stubConfig()
        stubPrelogin(kdf: 0, iterations: pbkdf2Case.iterations)
        StubServer.shared.on("/connect/token", respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"r\"}"))

        // A reject-all policy would abort if consulted; an unchanged config must
        // not consult it.
        let outcome = try await makeAuthenticator(kdf: RejectAllKDFChangePolicy()).login(
            email: email, masterPasswordBytes: passwordBytes,
            device: device,
            lastAcceptedKDF: .pbkdf2SHA256(iterations: pbkdf2Case.iterations)
        )
        guard case .authenticated = outcome else {
            return XCTFail("unchanged KDF should authenticate")
        }
    }

    // AUTH-04: wrong password -> generic login failure (bad credentials).
    func testWrongPasswordIsBadCredentials() async throws {
        stubConfig()
        stubPrelogin(kdf: 0, iterations: pbkdf2Case.iterations)
        StubServer.shared.on(
            "/connect/token",
            respond: .json(400, "{\"error\":\"invalid_grant\",\"error_description\":\"bad\"}")
        )

        do {
            _ = try await makeAuthenticator().login(
                email: email, masterPasswordBytes: passwordBytes, device: device, lastAcceptedKDF: nil
            )
            XCTFail("expected failure")
        } catch let error as VaultwardenAPIError {
            // invalid_grant on the initial password grant means the master
            // password was rejected, mapped to badCredentials by the classifier
            // (a refresh-time invalid_grant maps to sessionExpired instead).
            XCTAssertEqual(error.category, .badCredentials)
            XCTAssertEqual(error.machineCode, "invalid_grant")
        }
    }

    // 2FA challenge then successful continuation.
    func testTwoFactorChallengeThenSuccessfulContinuation() async throws {
        stubConfig()
        stubPrelogin(kdf: 0, iterations: pbkdf2Case.iterations)
        StubServer.shared.on(
            "/connect/token",
            respond: .json(400, "{\"TwoFactorProviders\":[\"0\"],\"TwoFactorProviders2\":{\"0\":{}}}")
        )
        StubServer.shared.on(
            "/connect/token",
            respond: .json(200, "{\"access_token\":\"VSQ-2fa-access\",\"refresh_token\":\"r\"}")
        )

        let authenticator = try makeAuthenticator()
        let outcome = try await authenticator.login(
            email: email, masterPasswordBytes: passwordBytes, device: device, lastAcceptedKDF: nil
        )

        guard case .twoFactorRequired(let challenge, let pending) = outcome else {
            return XCTFail("expected a 2FA challenge")
        }
        XCTAssertEqual(challenge.completableProviders, [.authenticator])

        let session = try await authenticator.completeTwoFactor(
            pending,
            proof: VaultwardenTwoFactorProof(
                provider: .authenticator, token: "123456", rememberDevice: true
            )
        )
        XCTAssertEqual(session.refreshToken, "r")

        let grant = try XCTUnwrap(StubServer.shared.lastRequest(pathSuffix: "/connect/token"))
        XCTAssertEqual(grant.formFields["two_factor_provider"], "0")
        XCTAssertEqual(grant.formFields["two_factor_token"], "123456")
        XCTAssertEqual(grant.formFields["two_factor_remember"], "1")
    }

    func testResubmittedProofStillChallengedIsBadCredentials() async throws {
        // Pins the classification path: a resubmitted proof whose grant still
        // returns challenge maps is a rejected factor (bad credentials), decided
        // in submitGrant/classify, not the defensive branch in completeTwoFactor.
        stubConfig()
        stubPrelogin(kdf: 0, iterations: pbkdf2Case.iterations)
        StubServer.shared.on("/connect/token", respond: .json(400, "{\"TwoFactorProviders2\":{\"0\":{}}}"))
        StubServer.shared.on("/connect/token", respond: .json(400, "{\"TwoFactorProviders2\":{\"0\":{}}}"))

        let authenticator = try makeAuthenticator()
        let outcome = try await authenticator.login(
            email: email, masterPasswordBytes: passwordBytes, device: device, lastAcceptedKDF: nil
        )
        guard case .twoFactorRequired(_, let pending) = outcome else {
            return XCTFail("expected a 2FA challenge")
        }

        do {
            _ = try await authenticator.completeTwoFactor(
                pending,
                proof: VaultwardenTwoFactorProof(provider: .authenticator, token: "000000", rememberDevice: false)
            )
            XCTFail("a still-challenged proof must be rejected")
        } catch let error as VaultwardenAPIError {
            XCTAssertEqual(error.category, .badCredentials)
        }
    }

    func testUnsupportedTwoFactorProofRejectedWithoutRequest() async throws {
        stubConfig()
        stubPrelogin(kdf: 0, iterations: pbkdf2Case.iterations)
        StubServer.shared.on(
            "/connect/token",
            respond: .json(400, "{\"TwoFactorProviders2\":{\"2\":{},\"7\":{}}}")
        )

        let authenticator = try makeAuthenticator()
        let outcome = try await authenticator.login(
            email: email, masterPasswordBytes: passwordBytes, device: device, lastAcceptedKDF: nil
        )
        guard case .twoFactorRequired(let challenge, let pending) = outcome else {
            return XCTFail("expected a 2FA challenge")
        }
        // Duo (2) and WebAuthn (7) are recognized but not user-completable yet.
        XCTAssertTrue(challenge.hasNoCompletableProvider)
        XCTAssertEqual(challenge.offered.map(\.rawValue).sorted(), [2, 7])

        do {
            _ = try await authenticator.completeTwoFactor(
                pending,
                proof: VaultwardenTwoFactorProof(provider: .duo, token: "x", rememberDevice: false)
            )
            XCTFail("unsupported provider must be rejected")
        } catch let error as VaultwardenAPIError {
            XCTAssertEqual(error.category, .unsupportedTwoFactorProvider)
        }
    }

    // Effective-origin approval gate: a differing origin needs approval.
    func testDifferingEffectiveOriginRequiresApproval() async throws {
        StubServer.shared.on(
            "/api/config",
            respond: .json(200, "{\"environment\":{\"identity\":\"https://identity.other.com\"}}")
        )
        stubPrelogin(kdf: 0, iterations: pbkdf2Case.iterations)

        do {
            _ = try await makeAuthenticator(origin: RejectAllOriginPolicy()).login(
                email: email, masterPasswordBytes: passwordBytes, device: device, lastAcceptedKDF: nil
            )
            XCTFail("unapproved cross-origin must abort before prelogin")
        } catch let error as VaultwardenAPIError {
            XCTAssertEqual(error.category, .unexpected)
        }
        // Prelogin (which carries the email) was never sent.
        XCTAssertNil(StubServer.shared.lastRequest(pathSuffix: "/accounts/prelogin/password"))
    }

    func testApprovedEffectiveOriginIsActuallyUsedForPreloginAndGrant() async throws {
        // Config advertises identity on a different host; with approval, the
        // prelogin and token grant must target that approved host, not the
        // entered one.
        StubServer.shared.on(
            "/api/config",
            respond: .json(200, "{\"environment\":{\"identity\":\"https://identity.other.com/identity\"}}")
        )
        stubPrelogin(kdf: 0, iterations: pbkdf2Case.iterations)
        StubServer.shared.on("/connect/token", respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"r\"}"))

        _ = try await makeAuthenticator().login(
            email: email, masterPasswordBytes: passwordBytes, device: device, lastAcceptedKDF: nil
        )

        let prelogin = try XCTUnwrap(
            StubServer.shared.lastRequest(pathSuffix: "/accounts/prelogin/password")
        )
        XCTAssertEqual(prelogin.url.host, "identity.other.com")
        let grant = try XCTUnwrap(StubServer.shared.lastRequest(pathSuffix: "/connect/token"))
        XCTAssertEqual(grant.url.host, "identity.other.com")
    }

    func testHTTPAdvertisedServiceURLsFallBackToEnteredOriginWithoutApproval() async throws {
        // A server whose DOMAIN setting is unset advertises http://localhost
        // service URLs. A plaintext-http advertisement is unusable, so login
        // must stay on the entered origin without consulting the approval
        // policy — proven with a policy that would reject any prompt.
        StubServer.shared.on(
            "/api/config",
            respond: .json(200, "{\"environment\":{\"identity\":\"http://localhost/identity\",\"api\":\"http://localhost/api\"}}")
        )
        stubPrelogin(kdf: 0, iterations: pbkdf2Case.iterations)
        StubServer.shared.on("/connect/token", respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"r\"}"))

        let outcome = try await makeAuthenticator(origin: RejectAllOriginPolicy()).login(
            email: email, masterPasswordBytes: passwordBytes, device: device, lastAcceptedKDF: nil
        )

        guard case .authenticated = outcome else {
            return XCTFail("an http advertisement should fall back to the entered origin and authenticate")
        }
        let prelogin = try XCTUnwrap(
            StubServer.shared.lastRequest(pathSuffix: "/accounts/prelogin/password")
        )
        XCTAssertEqual(prelogin.url.host, "vault.example.com")
        let grant = try XCTUnwrap(StubServer.shared.lastRequest(pathSuffix: "/connect/token"))
        XCTAssertEqual(grant.url.host, "vault.example.com")
    }

    func testTraversalBearingAdvertisedServiceFallsBackToEnteredOrigin() async throws {
        StubServer.shared.on(
            "/api/config",
            respond: .json(200, "{\"environment\":{\"identity\":\"https://identity.other.com/p/%2e%2e/identity\"}}")
        )
        stubPrelogin(kdf: 0, iterations: pbkdf2Case.iterations)
        StubServer.shared.on(
            "/connect/token",
            respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"r\"}")
        )

        let outcome = try await makeAuthenticator(origin: RejectAllOriginPolicy()).login(
            email: email,
            masterPasswordBytes: passwordBytes,
            device: device,
            lastAcceptedKDF: nil
        )
        guard case .authenticated = outcome else {
            return XCTFail("a non-canonical service path should fall back safely")
        }
        XCTAssertEqual(
            StubServer.shared.lastRequest(pathSuffix: "/accounts/prelogin/password")?.url.host,
            "vault.example.com"
        )
    }

    func testMalformedConfigFallsBackToEnteredOriginAndProceeds() async throws {
        // A config body that is not decodable must not abort login; the client
        // falls back to the entered origin (the safe same-origin default).
        StubServer.shared.on("/api/config", respond: .json(200, "}{ not json"))
        stubPrelogin(kdf: 0, iterations: pbkdf2Case.iterations)
        StubServer.shared.on("/connect/token", respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"r\"}"))

        let outcome = try await makeAuthenticator().login(
            email: email, masterPasswordBytes: passwordBytes, device: device, lastAcceptedKDF: nil
        )
        guard case .authenticated = outcome else {
            return XCTFail("malformed config should fall back and authenticate")
        }
        let prelogin = try XCTUnwrap(
            StubServer.shared.lastRequest(pathSuffix: "/accounts/prelogin/password")
        )
        XCTAssertEqual(prelogin.url.host, "vault.example.com")
    }

    func testEmailChallengeCarriesAuthHashAndDeviceIdentifier() async throws {
        stubConfig()
        stubPrelogin(kdf: 0, iterations: pbkdf2Case.iterations)
        StubServer.shared.on(
            "/connect/token",
            respond: .json(400, "{\"TwoFactorProviders2\":{\"1\":{}}}")
        )
        StubServer.shared.on("/two-factor/send-email-login", respond: .json(200, "{}"))

        let authenticator = try makeAuthenticator()
        let outcome = try await authenticator.login(
            email: email, masterPasswordBytes: passwordBytes, device: device, lastAcceptedKDF: nil
        )
        guard case .twoFactorRequired(_, let pending) = outcome else {
            return XCTFail("expected an email 2FA challenge")
        }

        try await authenticator.sendEmailChallenge(pending: pending)

        let send = try XCTUnwrap(
            StubServer.shared.lastRequest(pathSuffix: "/two-factor/send-email-login")
        )
        XCTAssertTrue(send.bodyString.contains("masterPasswordHash"))
        XCTAssertTrue(send.bodyString.contains("deviceIdentifier"))
        // The auth hash, not the master password, is what is sent.
        XCTAssertFalse(send.bodyString.contains(VaultwardenCryptoFixtures.password))
    }

    func testPreloginLegacyAliasFallback() async throws {
        stubConfig()
        StubServer.shared.on("/accounts/prelogin/password", respond: .json(404, "{}"))
        StubServer.shared.on(
            "/accounts/prelogin",
            respond: .json(200, "{\"Kdf\":0,\"KdfIterations\":\(pbkdf2Case.iterations)}")
        )
        StubServer.shared.on("/connect/token", respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"r\"}"))

        let outcome = try await makeAuthenticator().login(
            email: email, masterPasswordBytes: passwordBytes, device: device, lastAcceptedKDF: nil
        )
        guard case .authenticated = outcome else {
            return XCTFail("legacy prelogin fallback should authenticate")
        }
    }
}
