import XCTest
@testable import VaultSquire

/// Asserts that credential-derived material never crosses the boundary in
/// error text or in request bodies where it does not belong, and that the
/// transport keeps no on-disk state.
final class VaultwardenLeakageTests: XCTestCase {
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

    func testMasterPasswordNeverAppearsInAnyRequestBody() async throws {
        StubServer.shared.on("/api/config", respond: .json(200, "{}"))
        StubServer.shared.on(
            "/accounts/prelogin/password",
            respond: .json(200, "{\"Kdf\":0,\"KdfIterations\":100000}")
        )
        StubServer.shared.on(
            "/connect/token",
            respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"r\"}")
        )

        let authenticator = VaultwardenAuthenticator(
            transport: try VaultwardenTestFactory.stubbedTransport(),
            kdfChangePolicy: ApproveAllKDFChangePolicy(),
            originApprovalPolicy: ApproveAllOriginPolicy()
        )
        _ = try await authenticator.login(
            email: VaultwardenCryptoFixtures.emailRaw,
            masterPasswordBytes: Data(VaultwardenCryptoFixtures.password.utf8),
            device: device,
            lastAcceptedKDF: nil
        )

        let password = VaultwardenCryptoFixtures.password
        for request in StubServer.shared.requests {
            XCTAssertFalse(
                request.bodyString.contains(password),
                "master password leaked into \(request.url.path)"
            )
        }
    }

    func testTransportErrorDoesNotCarryTheFailingURL() async throws {
        // No route registered -> the stub fails the request; the transport must
        // surface only a category, not the URL-bearing underlying error.
        let transport = try VaultwardenTestFactory.stubbedTransport(
            base: "https://secret-host.example.com"
        )
        do {
            _ = try await transport.send(
                .get, url: transport.environment.apiURL.appendingPathComponent("config")
            )
            XCTFail("expected a transport failure")
        } catch let error as VaultwardenTransportError {
            XCTAssertEqual(error, .transportFailure)
            XCTAssertFalse("\(error)".contains("secret-host"))
        } catch {
            XCTFail("Expected VaultwardenTransportError.transportFailure, got: \(error)")
        }
    }

    func testTypedErrorMessageOmitsTokensAndCodes() throws {
        // A server error whose body echoes a bearer token must not surface that
        // token: the decoder only lifts documented message fields, and a body
        // with none falls back to a generic status string. Decode with `try` so
        // a decode failure fails the test rather than passing vacuously.
        let body = try JSONDecoder().decode(
            VaultwardenErrorBody.self,
            from: Data(#"{"access_token":"leaked-token","unexpected":"x"}"#.utf8)
        )
        let message = VaultwardenErrorDecoder.safeMessage(from: body, httpStatus: 400)
        XCTAssertFalse(message.contains("leaked-token"))
    }

    func testEphemeralSessionDoesNotPersistCookiesAcrossRequests() async throws {
        // The first response sets a cookie; the ephemeral no-cookie session must
        // not echo it back on a second request to the same origin.
        let transport = try VaultwardenTestFactory.stubbedTransport()
        let configURL = transport.environment.apiURL.appendingPathComponent("config")
        StubServer.shared.on(
            "/api/config",
            respond: .json(200, "{}", headers: ["Set-Cookie": "session=VSQ-Canary-secret; Path=/"])
        )

        _ = try await transport.send(.get, url: configURL, bearer: "VSQ-Canary-access")
        _ = try await transport.send(.get, url: configURL, bearer: "VSQ-Canary-access")

        let configRequests = StubServer.shared.requests.filter {
            $0.url.path.hasSuffix("/api/config")
        }
        XCTAssertEqual(configRequests.count, 2)
        XCTAssertNil(
            configRequests.last?.headers["Cookie"],
            "ephemeral session must not persist cookies across requests"
        )
    }
}
