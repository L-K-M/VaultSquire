import XCTest
@testable import VaultSquire

final class VaultwardenTokenRefresherTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubServer.shared.reset()
    }

    override func tearDown() {
        StubServer.shared.reset()
        super.tearDown()
    }

    func testSuccessfulRefreshReplacesTokenAtomically() async throws {
        let transport = try VaultwardenTestFactory.stubbedTransport()
        StubServer.shared.on(
            "/connect/token",
            respond: .json(200, "{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\",\"expires_in\":7200}")
        )
        let refresher = VaultwardenTokenRefresher(transport: transport, refreshToken: "old-refresh")

        let outcome = await refresher.refresh()

        guard case .refreshed(let accessToken, let refreshToken, let expiresIn) = outcome else {
            return XCTFail("expected a refreshed outcome")
        }
        XCTAssertEqual(accessToken, "new-access")
        XCTAssertEqual(refreshToken, "new-refresh")
        XCTAssertEqual(expiresIn, 7200)
        let current = await refresher.currentRefreshToken
        XCTAssertEqual(current, "new-refresh")

        let grant = try XCTUnwrap(StubServer.shared.lastRequest(pathSuffix: "/connect/token"))
        XCTAssertEqual(grant.formFields["grant_type"], "refresh_token")
        XCTAssertEqual(grant.formFields["refresh_token"], "old-refresh")
        XCTAssertEqual(grant.formFields["client_id"], "desktop")
    }

    func testInvalidGrantRefreshReportsSessionExpired() async throws {
        let transport = try VaultwardenTestFactory.stubbedTransport()
        StubServer.shared.on("/connect/token", respond: .json(400, "{\"error\":\"invalid_grant\"}"))
        let refresher = VaultwardenTokenRefresher(transport: transport, refreshToken: "stale")

        let outcome = await refresher.refresh()

        guard case .sessionExpired = outcome else {
            return XCTFail("expected sessionExpired")
        }
        // The stale token is not replaced by a failed refresh.
        let current = await refresher.currentRefreshToken
        XCTAssertEqual(current, "stale")
    }

    func testConcurrentRefreshesShareOneInFlightRequest() async throws {
        let transport = try VaultwardenTestFactory.stubbedTransport()
        StubServer.shared.on(
            "/connect/token",
            respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"b\"}")
        )
        let refresher = VaultwardenTokenRefresher(transport: transport, refreshToken: "start")

        let outcomes = await withTaskGroup(of: VaultwardenRefreshOutcome.self) { group in
            for _ in 0..<8 {
                group.addTask { await refresher.refresh() }
            }
            var collected: [VaultwardenRefreshOutcome] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        XCTAssertEqual(outcomes.count, 8)
        for outcome in outcomes {
            guard case .refreshed(_, let refreshToken, _) = outcome else {
                return XCTFail("all callers should share the successful refresh")
            }
            XCTAssertEqual(refreshToken, "b")
        }
        // The eight callers coalesced onto a single network request.
        let tokenRequests = StubServer.shared.requests.filter {
            $0.url.path.hasSuffix("/connect/token")
        }
        XCTAssertEqual(tokenRequests.count, 1)
    }
}
