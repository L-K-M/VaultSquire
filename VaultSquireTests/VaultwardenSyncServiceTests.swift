import Foundation
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

    func testUnknownCipherTypeAndWireFieldsArePreservedWithoutCoercion() async throws {
        StubServer.shared.on(
            "/connect/token",
            respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"r2\"}")
        )
        StubServer.shared.on(
            "/api/sync",
            respond: .json(200, """
            {"Profile":{"Key":"2.old|old|old","Organizations":[]},
             "Folders":[],
             "Ciphers":[{"Id":"c1","Type":99,"RevisionDate":"2026-01-02T03:04:05Z",
                          "FutureCiphertext":"2.unknown|unknown|unknown"}]}
            """)
        )

        let result = await (try makeService()).sync(
            current: makeCurrentSnapshot(),
            refresher: try makeRefresher(),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        guard case .success(let success) = result else {
            return XCTFail("unknown forms should remain opaque, not corrupt known sync fields")
        }
        XCTAssertEqual(success.snapshot.ciphers.first?.type, .unknown)
        XCTAssertEqual(success.snapshot.ciphers.first?.rawType, 99)
        XCTAssertTrue(
            String(decoding: try XCTUnwrap(success.snapshot.rawSyncResponse), as: UTF8.self)
                .contains("FutureCiphertext")
        )
    }

    func testChangedWrappedHierarchyRequiresReauthenticationAndPreservesCurrent() async throws {
        StubServer.shared.on(
            "/connect/token",
            respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"r2\"}")
        )
        StubServer.shared.on(
            "/api/sync",
            respond: .json(200, """
            {"Profile":{"Key":"2.changed|changed|changed","Organizations":[]},
             "Folders":[],"Ciphers":[]}
            """)
        )
        let current = makeCurrentSnapshot()

        let result = await (try makeService()).sync(
            current: current,
            refresher: try makeRefresher(),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        guard case .failure(let error) = result else {
            return XCTFail("expected hierarchy change to fail closed")
        }
        XCTAssertEqual(error, .reauthenticationRequired)
        XCTAssertEqual(current.wrappedUserKey, "2.old|old|old")
        XCTAssertEqual(current.generation, 3)
    }

    func testPreviouslyPresentBootstrapMaterialCannotDisappear() async throws {
        StubServer.shared.on(
            "/connect/token",
            respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"r2\"}")
        )
        StubServer.shared.on(
            "/api/sync",
            respond: .json(200, """
            {"Profile":{"Key":"2.old|old|old","Organizations":[]},
             "Folders":[],"Ciphers":[]}
            """)
        )
        var current = makeCurrentSnapshot()
        current.wrappedPrivateKey = "4.private"
        current.securityStamp = "stamp"

        let result = await (try makeService()).sync(
            current: current,
            refresher: try makeRefresher(),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        guard case .failure(let error) = result else {
            return XCTFail("missing private key or stamp must require login")
        }
        XCTAssertEqual(error, .reauthenticationRequired)
    }

    func testPreviouslyPresentWrappedUserKeyCannotDisappear() async throws {
        StubServer.shared.on(
            "/connect/token",
            respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"r2\"}")
        )
        StubServer.shared.on(
            "/api/sync",
            respond: .json(200, """
            {"Profile":{"Organizations":[]},"Folders":[],"Ciphers":[]}
            """)
        )

        let result = await (try makeService()).sync(
            current: makeCurrentSnapshot(),
            refresher: try makeRefresher(),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        guard case .failure(let error) = result else {
            return XCTFail("missing wrapped user key must require login")
        }
        XCTAssertEqual(error, .reauthenticationRequired)
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

    func testRotatedRefreshTokenPersistsBeforeAFailedVaultFetch() async throws {
        StubServer.shared.on(
            "/connect/token",
            respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"r2\"}")
        )
        StubServer.shared.on("/api/sync", respond: .json(503, "{}"))
        let recorder = RefreshTokenRecorder()

        let result = await (try makeService()).sync(
            current: makeCurrentSnapshot(),
            refresher: try makeRefresher(),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            persistRefreshToken: { recorder.record($0) }
        )

        guard case .failure(let error) = result else {
            return XCTFail("expected the vault fetch to fail")
        }
        XCTAssertEqual(error, .unexpectedStatus(503))
        XCTAssertEqual(recorder.value, "r2")
    }

    func testRefreshTokenPersistenceFailureStopsBeforeVaultFetch() async throws {
        StubServer.shared.on(
            "/connect/token",
            respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"r2\"}")
        )

        let result = await (try makeService()).sync(
            current: makeCurrentSnapshot(),
            refresher: try makeRefresher(),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            persistRefreshToken: { _ in throw SyntheticPersistenceError.failed }
        )

        guard case .failure(let error) = result else {
            return XCTFail("expected persistence failure")
        }
        XCTAssertEqual(error, .localStorageFailed)
        XCTAssertNil(StubServer.shared.lastRequest(pathSuffix: "/api/sync"))
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

private enum SyntheticPersistenceError: Error {
    case failed
}

private final class RefreshTokenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    func record(_ token: String) {
        lock.lock(); defer { lock.unlock() }
        self.token = token
    }

    var value: String? {
        lock.lock(); defer { lock.unlock() }
        return token
    }
}
