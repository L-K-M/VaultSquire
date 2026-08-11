import XCTest
@testable import VaultSquire

final class VaultwardenSyncServiceTests: XCTestCase {
    private let account = AccountID(provider: .vaultwarden, rawValue: "VSQ-Canary-account")

    override func setUp() {
        super.setUp()
        StubServer.shared.reset()
    }

    override func tearDown() {
        StubServer.shared.reset()
        super.tearDown()
    }

    private func makeCurrentSnapshot() -> VaultwardenVaultSnapshot {
        VaultwardenVaultSnapshot(
            version: VaultwardenVaultSnapshot.currentVersion,
            serverBaseURL: "https://vault.example.com",
            identityBaseURL: "https://vault.example.com/identity",
            email: "user@example.com",
            kdf: .init(configuration: .pbkdf2SHA256(iterations: 600_000)),
            wrappedUserKey: "2.old|old|old",
            wrappedPrivateKey: nil,
            organizations: [],
            folders: [],
            ciphers: [],
            syncedAt: Date(timeIntervalSince1970: 1),
            generation: 3
        )
    }

    private func makeService() throws -> VaultwardenSyncService {
        VaultwardenSyncService(transport: try VaultwardenTestFactory.stubbedTransport())
    }

    private func makeRefresher() throws -> VaultwardenTokenRefresher {
        VaultwardenTokenRefresher(
            transport: try VaultwardenTestFactory.stubbedTransport(),
            refreshToken: "VSQ-Canary-refresh"
        )
    }

    func testSyncMergesCiphersAndBumpsGenerationAndRotatesToken() async throws {
        StubServer.shared.on(
            "/connect/token",
            respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"VSQ-refresh-2\"}")
        )
        StubServer.shared.on(
            "/api/sync",
            respond: .json(200, """
            {"Profile":{"Key":"2.old|old|old","PrivateKey":null,"Organizations":[]},
             "Folders":[{"Id":"f1","Name":"2.f|f|f"}],
             "Ciphers":[{"Id":"c1","Type":1,"RevisionDate":"2026-01-02T03:04:05.678Z","Name":"2.n|n|n"}]}
            """)
        )

        let result = await (try makeService()).sync(
            current: makeCurrentSnapshot(),
            refresher: try makeRefresher(),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        guard case .success(let success) = result else {
            return XCTFail("expected a successful sync, got \(result)")
        }
        XCTAssertEqual(success.snapshot.generation, 4, "generation must strictly advance")
        XCTAssertEqual(success.snapshot.ciphers.count, 1)
        XCTAssertEqual(success.snapshot.folders.first?.id, "f1")
        XCTAssertEqual(success.snapshot.wrappedUserKey, "2.old|old|old")
        XCTAssertEqual(success.snapshot.email, "user@example.com", "context is preserved from the prior snapshot")
        XCTAssertEqual(success.refreshToken, "VSQ-refresh-2", "the rotated refresh token is returned")
    }

    /// A sync response whose wrapped user key differs from the snapshot's is a
    /// key-hierarchy rotation. The candidate must NOT be promoted: the prior
    /// snapshot and bootstrap data stay current, so retained ciphertext is
    /// never decrypted under a rotated key and the old key is never used to
    /// write new ciphertext.
    func testSyncRefusesPromotionWhenWrappedUserKeyChanges() async throws {
        StubServer.shared.on(
            "/connect/token",
            respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"VSQ-refresh-2\"}")
        )
        StubServer.shared.on(
            "/api/sync",
            respond: .json(200, """
            {"Profile":{"Key":"2.rotated|rotated|rotated","PrivateKey":null,"Organizations":[]},
             "Folders":[],"Ciphers":[]}
            """)
        )

        let result = await (try makeService()).sync(
            current: makeCurrentSnapshot(),
            refresher: try makeRefresher(),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        guard case .failure(let error) = result else {
            return XCTFail("expected a failure, got \(result)")
        }
        XCTAssertEqual(error, .bootstrapChanged)
    }

    /// The empty-key case is the first-unlock fill, not a rotation: a snapshot
    /// seeded without a wrapped key must be allowed to receive one from the
    /// sync profile.
    func testSyncFillsAnEmptyWrappedUserKey() async throws {
        StubServer.shared.on(
            "/connect/token",
            respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"VSQ-refresh-2\"}")
        )
        StubServer.shared.on(
            "/api/sync",
            respond: .json(200, """
            {"Profile":{"Key":"2.first|first|first","PrivateKey":null,"Organizations":[]},
             "Folders":[],"Ciphers":[]}
            """)
        )

        var current = makeCurrentSnapshot()
        current.wrappedUserKey = ""
        let result = await (try makeService()).sync(
            current: current,
            refresher: try makeRefresher(),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        guard case .success(let success) = result else {
            return XCTFail("expected a successful sync, got \(result)")
        }
        XCTAssertEqual(success.snapshot.wrappedUserKey, "2.first|first|first")
    }

    func testRateLimitedRefreshIsReportedAsRefreshFailedNotUnreachable() async throws {
        StubServer.shared.on("/connect/token", respond: .json(429, "{}"))

        let result = await (try makeService()).sync(
            current: makeCurrentSnapshot(),
            refresher: try makeRefresher(),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        guard case .failure(let error) = result else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(error, .refreshFailed)
    }

    func testUnexpectedSyncStatusCarriesTheStatusCode() async throws {
        StubServer.shared.on(
            "/connect/token",
            respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"r2\"}")
        )
        StubServer.shared.on("/api/sync", respond: .json(503, "{}"))

        let result = await (try makeService()).sync(
            current: makeCurrentSnapshot(),
            refresher: try makeRefresher(),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        guard case .failure(let error) = result else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(error, .unexpectedStatus(503))
    }

    func testExpiredRefreshTokenReportsSessionExpiredWithoutFetching() async throws {
        StubServer.shared.on("/connect/token", respond: .json(400, "{\"error\":\"invalid_grant\"}"))

        let result = await (try makeService()).sync(
            current: makeCurrentSnapshot(),
            refresher: try makeRefresher(),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        guard case .failure(let error) = result else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(error, .sessionExpired)
        XCTAssertNil(StubServer.shared.lastRequest(pathSuffix: "/api/sync"), "sync must not run after a failed refresh")
    }

    func testMalformedSyncBodyIsReported() async throws {
        StubServer.shared.on(
            "/connect/token",
            respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"r2\"}")
        )
        StubServer.shared.on("/api/sync", respond: .json(200, "}{ not json"))

        let result = await (try makeService()).sync(
            current: makeCurrentSnapshot(),
            refresher: try makeRefresher(),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        guard case .failure(let error) = result else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(error, .malformedResponse)
    }
}
