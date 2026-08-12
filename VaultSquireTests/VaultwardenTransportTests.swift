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

    // MARK: - Refusing a destination before it reaches Foundation

    /// A credential in the URL would be handed to Foundation and could end up
    /// in its own state before any header is set. The request is refused
    /// instead of built.
    func testRejectsAURLCarryingEmbeddedCredentials() async throws {
        let transport = try VaultwardenTestFactory.stubbedTransport()
        let url = try XCTUnwrap(URL(string: "https://user:secret@vault.example.com/api/config"))
        await assertTransportFailure { try await transport.send(.get, url: url) }
    }

    func testRejectsAURLCarryingAFragment() async throws {
        let transport = try VaultwardenTestFactory.stubbedTransport()
        let url = try XCTUnwrap(URL(string: "https://vault.example.com/api/config#frag"))
        await assertTransportFailure { try await transport.send(.get, url: url) }
    }

    /// An encoded dot or slash makes the path Foundation resolves differ from
    /// the one the redirect policy and the origin check reasoned about.
    func testRejectsANonCanonicalPath() async throws {
        let transport = try VaultwardenTestFactory.stubbedTransport()
        for raw in [
            "https://vault.example.com/api/%2e%2e/admin",
            "https://vault.example.com/api/%2fadmin",
            "https://vault.example.com/api/..%5cadmin",
            "https://vault.example.com/api/../admin"
        ] {
            let url = try XCTUnwrap(URL(string: raw))
            await assertTransportFailure(raw) { try await transport.send(.get, url: url) }
        }
    }

    /// Plain HTTP is admitted only for the origin the user already approved,
    /// which is how the documented loopback development exception works.
    func testRejectsPlainHTTPToAnUnapprovedOrigin() async throws {
        let transport = try VaultwardenTestFactory.stubbedTransport()
        let url = try XCTUnwrap(URL(string: "http://elsewhere.example.com/api/config"))
        await assertTransportFailure { try await transport.send(.get, url: url) }
    }

    /// The classification exists so a proxy interposing on the connection is
    /// not reported as an ordinary "couldn't reach the server".
    func testTLSFailureCodesAreClassifiedApartFromOtherTransportFailures() {
        for code: URLError.Code in [
            .secureConnectionFailed,
            .serverCertificateUntrusted,
            .serverCertificateHasBadDate,
            .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid
        ] {
            XCTAssertTrue(VaultwardenTransport.isTLSFailure(code), "\(code)")
        }
        for code: URLError.Code in [.timedOut, .notConnectedToInternet, .cannotFindHost] {
            XCTAssertFalse(VaultwardenTransport.isTLSFailure(code), "\(code)")
        }
    }

    private func assertTransportFailure(
        _ label: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected the request to be refused \(label)", file: file, line: line)
        } catch let error as VaultwardenTransportError {
            XCTAssertEqual(error, .transportFailure, label, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error) \(label)", file: file, line: line)
        }
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

    func testRetryAfterIsCappedAtOneDay() {
        // A far-future value must not disable retries for an arbitrary span.
        XCTAssertEqual(VaultwardenTransport.parseRetryAfter("999999999"), 86_400)
        XCTAssertEqual(VaultwardenTransport.parseRetryAfter("86400"), 86_400)
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
