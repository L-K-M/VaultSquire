import XCTest
@testable import VaultSquire

final class VaultwardenTransportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubServer.shared.reset()
    }

    override func tearDown() {
        StubServer.shared.reset()
        super.tearDown()
    }

    func testEphemeralSessionHasNoCacheCookieOrCredentialStore() {
        let session = VaultwardenTransport.makeEphemeralSession()
        let configuration = session.configuration

        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertEqual(
            configuration.requestCachePolicy,
            .reloadIgnoringLocalAndRemoteCacheData
        )
    }

    func testGetRequestCarriesFixedHeadersAndNoStore() async throws {
        let transport = try VaultwardenTestFactory.stubbedTransport()
        StubServer.shared.on("/api/config", respond: .json(200, "{\"version\":\"2026.6.0\"}"))

        _ = try await transport.send(.get, url: transport.environment.apiURL.appendingPathComponent("config"))

        let recorded = try XCTUnwrap(StubServer.shared.lastRequest(pathSuffix: "/api/config"))
        XCTAssertEqual(recorded.headers["Bitwarden-Client-Name"], "VaultSquire")
        XCTAssertEqual(recorded.headers["Device-Type"], "7")
        XCTAssertEqual(recorded.headers["Cache-Control"], "no-store")
        XCTAssertEqual(recorded.headers["Pragma"], "no-cache")
        // Bitwarden-Client-Version must remain unset until a contract lane
        // justifies an exact value.
        XCTAssertNil(recorded.headers["Bitwarden-Client-Version"])
    }

    func testBearerTokenAttachedWhenProvided() async throws {
        let transport = try VaultwardenTestFactory.stubbedTransport()
        StubServer.shared.on("/api/sync", respond: .json(200, "{}"))

        _ = try await transport.send(
            .get,
            url: transport.environment.apiURL.appendingPathComponent("sync"),
            bearer: "VSQ-Canary-access-token"
        )

        let recorded = try XCTUnwrap(StubServer.shared.lastRequest(pathSuffix: "/api/sync"))
        XCTAssertEqual(recorded.headers["Authorization"], "Bearer VSQ-Canary-access-token")
    }

    func testResponseOverTheByteBoundIsRejected() async throws {
        let environment = try VaultwardenEnvironment(configuredURL: "https://vault.example.com")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let transport = VaultwardenTransport(
            environment: environment,
            maximumResponseBytes: 16,
            session: URLSession(configuration: configuration)
        )
        StubServer.shared.on(
            "/api/config",
            respond: StubResponse(status: 200, body: Data(repeating: 0x41, count: 64))
        )

        do {
            _ = try await transport.send(
                .get, url: environment.apiURL.appendingPathComponent("config")
            )
            XCTFail("Oversized response must be rejected")
        } catch {
            XCTAssertEqual(error as? VaultwardenTransportError, .responseTooLarge)
        }
    }

    func testFormBodyIsEncodedAndRecorded() async throws {
        let transport = try VaultwardenTestFactory.stubbedTransport()
        StubServer.shared.on("/identity/connect/token", respond: .json(200, "{\"access_token\":\"t\"}"))

        _ = try await transport.send(
            .post,
            url: transport.environment.identityURL.appendingPathComponent("connect/token"),
            body: .form(["grant_type": "password", "scope": "api offline_access"])
        )

        let recorded = try XCTUnwrap(
            StubServer.shared.lastRequest(pathSuffix: "/identity/connect/token")
        )
        XCTAssertEqual(recorded.formFields["grant_type"], "password")
        XCTAssertEqual(recorded.formFields["scope"], "api offline_access")
        XCTAssertEqual(
            recorded.headers["Content-Type"],
            "application/x-www-form-urlencoded"
        )
    }

    func testRetryAfterParsing() {
        XCTAssertEqual(VaultwardenTransport.parseRetryAfter("30"), 30)
        XCTAssertEqual(VaultwardenTransport.parseRetryAfter("  5 "), 5)
        XCTAssertNil(VaultwardenTransport.parseRetryAfter("Wed, 21 Oct 2026 07:28:00 GMT"))
        XCTAssertNil(VaultwardenTransport.parseRetryAfter("-1"))
    }

    func testRetryAfterHeaderSurfacedOn429() async throws {
        let transport = try VaultwardenTestFactory.stubbedTransport()
        StubServer.shared.on(
            "/identity/connect/token",
            respond: .json(429, "{\"error\":\"too_many_requests\"}", headers: ["Retry-After": "12"])
        )

        let response = try await transport.send(
            .post,
            url: transport.environment.identityURL.appendingPathComponent("connect/token"),
            body: .form(["grant_type": "password"])
        )

        XCTAssertEqual(response.status, 429)
        XCTAssertEqual(response.retryAfter, 12)
    }
}
