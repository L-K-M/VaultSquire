import CryptoKit
import XCTest
@testable import VaultSquire

final class VaultwardenAccountServiceTests: XCTestCase {
    private func makeService() -> (
        service: VaultwardenAccountService,
        descriptors: AccountDescriptorStore,
        cache: VaultwardenVaultCache,
        account: AccountID
    ) {
        let account = AccountID.vaultwardenPrimary
        let defaults = UserDefaults(suiteName: "VaultSquireTest-\(UUID().uuidString)")!
        let descriptors = AccountDescriptorStore(defaults: defaults)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VSQ-acct-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let cache = VaultwardenVaultCache(keyProvider: { key }, directory: directory)
        let service = VaultwardenAccountService(
            account: account,
            credentialStore: InMemoryCredentialStore(),
            vaultCache: cache,
            descriptorStore: descriptors
        )
        return (service, descriptors, cache, account)
    }

    private func session(wrappedUserKey: String?) -> VaultwardenAuthSession {
        VaultwardenAuthSession(
            refreshToken: "r",
            wrappedUserKey: wrappedUserKey,
            wrappedPrivateKey: nil,
            rememberTwoFactorToken: nil,
            kdfConfiguration: .pbkdf2SHA256(iterations: 600_000),
            identityBaseURL: URL(string: "https://vault.example.com/identity")!,
            apiBaseURL: URL(string: "https://api.example.net/api")!
        )
    }

    /// The regression: a login whose token carried no wrapped user key must
    /// still leave a descriptor, so the shell shows an unlock prompt instead of
    /// the dead promptless locked state.
    func testPersistAfterLoginWritesDescriptorWhenTokenHasNoWrappedKey() async throws {
        let (service, descriptors, cache, account) = makeService()

        try await service.persistAfterLogin(
            session: session(wrappedUserKey: nil),
            serverBaseURL: URL(string: "https://vault.example.com")!,
            email: "User@Example.com"
        )

        XCTAssertEqual(descriptors.all().map(\.account), [account])
        // The cache is seeded with an empty key the first unlock's sync fills.
        let snapshot = try XCTUnwrap(try cache.load(for: account))
        XCTAssertTrue(snapshot.wrappedUserKey.isEmpty)
        XCTAssertEqual(snapshot.serverBaseURL, "https://vault.example.com")
        // The approved API base is stored so sync and writes target the
        // advertised API service, not a URL derived from the configured base.
        XCTAssertEqual(snapshot.apiBaseURL, "https://api.example.net/api")
    }

    @MainActor
    func testDeviceIdentityRegeneratesMalformedIdentifierAndSanitizesName() {
        let defaults = UserDefaults(suiteName: "VSQ-device-\(UUID().uuidString)")!
        defaults.set(
            "--not-a-device-id",
            forKey: VaultwardenDeviceIdentityStore.identifierKey
        )

        let identity = VaultwardenDeviceIdentityStore.current(
            defaults: defaults,
            deviceName: "Mac\nVSQ-injected"
        )

        XCTAssertNotNil(UUID(uuidString: identity.identifier))
        XCTAssertEqual(identity.name, "MacVSQ-injected")
    }

    /// Real servers emit ISO 8601 dates with no fractional digits, three, or
    /// six; all must parse rather than falling back to the epoch.
    func testWireDateParsingToleratesEveryFractionalPrecision() throws {
        let milli = try XCTUnwrap(VaultwardenCipherModel.parseWireDate("2026-01-02T03:04:05.678Z"))
        XCTAssertEqual(milli.timeIntervalSince1970, 1_767_323_045.678, accuracy: 0.001)

        let micro = try XCTUnwrap(VaultwardenCipherModel.parseWireDate("2026-01-02T03:04:05.678901Z"))
        XCTAssertEqual(micro.timeIntervalSince1970, 1_767_323_045.678, accuracy: 0.001)

        let plain = try XCTUnwrap(VaultwardenCipherModel.parseWireDate("2026-01-02T03:04:05Z"))
        XCTAssertEqual(plain.timeIntervalSince1970, 1_767_323_045, accuracy: 0.001)

        XCTAssertNil(VaultwardenCipherModel.parseWireDate("not a date"))
    }

    /// An old sealed snapshot (no apiBaseURL field) must still decode, and the
    /// sync merge must carry the stored API base forward.
    func testSnapshotWithoutAPIBaseStillDecodes() async throws {
        let (service, _, cache, account) = makeService()
        try await service.persistAfterLogin(
            session: session(wrappedUserKey: "2.k|k"),
            serverBaseURL: URL(string: "https://vault.example.com")!,
            email: "u@example.com"
        )
        var snapshot = try XCTUnwrap(try cache.load(for: account))
        snapshot.apiBaseURL = nil
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(VaultwardenVaultSnapshot.self, from: data)
        XCTAssertNil(decoded.apiBaseURL)
    }

    func testPersistAfterLoginSeedsTheWrappedKeyWhenTheTokenProvidesIt() async throws {
        let (service, descriptors, cache, account) = makeService()

        try await service.persistAfterLogin(
            session: session(wrappedUserKey: "2.userkey|mac"),
            serverBaseURL: URL(string: "https://vault.example.com")!,
            email: "u@example.com"
        )

        XCTAssertEqual(descriptors.all().count, 1)
        let snapshot = try XCTUnwrap(try cache.load(for: account))
        XCTAssertEqual(snapshot.wrappedUserKey, "2.userkey|mac")
    }

    func testHierarchyChangePersistsReauthenticationMarkerAndBlocksOfflineUnlock() async throws {
        StubServer.shared.reset()
        defer { StubServer.shared.reset() }
        let account = AccountID.vaultwardenPrimary
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VSQ-reauth-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let cache = VaultwardenVaultCache(keyProvider: { key }, directory: directory)
        let credentials = InMemoryCredentialStore()
        try credentials.save(
            VaultwardenStoredCredentials(refreshToken: "VSQ-refresh"),
            for: .primary
        )
        let transport = try VaultwardenTestFactory.stubbedTransport()
        let service = VaultwardenAccountService(
            credentialStore: credentials,
            vaultCache: cache,
            descriptorStore: AccountDescriptorStore(
                defaults: UserDefaults(suiteName: "VSQ-reauth-\(UUID().uuidString)")!
            ),
            makeTransport: { _ in transport }
        )
        try await service.persistAfterLogin(
            session: session(wrappedUserKey: "2.old|old|old"),
            serverBaseURL: URL(string: "https://vault.example.com")!,
            email: "user@example.com"
        )
        StubServer.shared.on(
            "/connect/token",
            respond: .json(200, "{\"access_token\":\"a\",\"refresh_token\":\"VSQ-refresh-2\"}")
        )
        StubServer.shared.on(
            "/api/sync",
            respond: .json(200, """
            {"Profile":{"Key":"2.changed|changed|changed","Organizations":[]},
             "Folders":[],"Ciphers":[]}
            """)
        )

        let result = await service.sync()

        guard case .failure(let error) = result else {
            return XCTFail("changed hierarchy must require reauthentication")
        }
        XCTAssertEqual(error, .reauthenticationRequired)
        XCTAssertEqual(try cache.load(for: account)?.reauthenticationRequired, true)
        let currentWrappedKey = await service.currentWrappedUserKey()
        XCTAssertNil(currentWrappedKey)
        do {
            _ = try await service.unlock(userKeyData: Data(repeating: 1, count: 64))
            XCTFail("offline key unlock must remain blocked")
        } catch {
            XCTAssertEqual(error as? VaultwardenAccountError, .reauthenticationRequired)
        }
    }

    func testInvalidRefreshGrantPersistsReauthenticationMarker() async throws {
        StubServer.shared.reset()
        defer { StubServer.shared.reset() }
        let account = AccountID.vaultwardenPrimary
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VSQ-expired-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let cache = VaultwardenVaultCache(keyProvider: { key }, directory: directory)
        let credentials = InMemoryCredentialStore()
        try credentials.save(
            VaultwardenStoredCredentials(refreshToken: "VSQ-expired"),
            for: .primary
        )
        let transport = try VaultwardenTestFactory.stubbedTransport()
        let service = VaultwardenAccountService(
            credentialStore: credentials,
            vaultCache: cache,
            descriptorStore: AccountDescriptorStore(
                defaults: UserDefaults(suiteName: "VSQ-expired-\(UUID().uuidString)")!
            ),
            makeTransport: { _ in transport }
        )
        try await service.persistAfterLogin(
            session: session(wrappedUserKey: "2.old|old|old"),
            serverBaseURL: URL(string: "https://vault.example.com")!,
            email: "user@example.com"
        )
        StubServer.shared.on(
            "/connect/token",
            respond: .json(400, "{\"error\":\"invalid_grant\"}")
        )

        let result = await service.sync()

        guard case .failure(let error) = result else {
            return XCTFail("invalid_grant must end the local session")
        }
        XCTAssertEqual(error, .sessionExpired)
        XCTAssertEqual(try cache.load(for: account)?.reauthenticationRequired, true)
        let currentWrappedKey = await service.currentWrappedUserKey()
        XCTAssertNil(currentWrappedKey)
    }

    func testReauthenticationDoesNotReplaceMarkedCacheUntilFullSyncSucceeds() async throws {
        StubServer.shared.reset()
        defer { StubServer.shared.reset() }
        let account = AccountID.vaultwardenPrimary
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VSQ-replace-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let cache = VaultwardenVaultCache(keyProvider: { key }, directory: directory)
        let credentials = InMemoryCredentialStore()
        try credentials.save(
            VaultwardenStoredCredentials(refreshToken: "new-refresh"),
            for: .primary
        )
        let transport = try VaultwardenTestFactory.stubbedTransport()
        let service = VaultwardenAccountService(
            credentialStore: credentials,
            vaultCache: cache,
            descriptorStore: AccountDescriptorStore(
                defaults: UserDefaults(suiteName: "VSQ-replace-\(UUID().uuidString)")!
            ),
            makeTransport: { _ in transport }
        )
        try await service.persistAfterLogin(
            session: session(wrappedUserKey: "2.old|old|old"),
            serverBaseURL: URL(string: "https://vault.example.com")!,
            email: "user@example.com"
        )
        var marked = try XCTUnwrap(try cache.load(for: account))
        marked.reauthenticationRequired = true
        try cache.save(marked, for: account)
        StubServer.shared.on("/connect/token", respond: .json(503, "{}"))

        do {
            try await service.persistAfterLogin(
                session: session(wrappedUserKey: "2.new|new|new"),
                serverBaseURL: URL(string: "https://vault.example.com")!,
                email: "user@example.com"
            )
            XCTFail("replacement sync failure must abort reauthentication")
        } catch {
            XCTAssertEqual(error as? VaultwardenAccountError, .replacementSyncFailed)
        }
        let retained = try XCTUnwrap(try cache.load(for: account))
        XCTAssertTrue(retained.reauthenticationRequired == true)
        XCTAssertEqual(retained.wrappedUserKey, "2.old|old|old")
    }

    /// Custom fields carry an imported item's real content, so they must decode
    /// (in either casing), survive a cache re-encode, and keep their kind.
    func testCipherCustomFieldsDecodeAndRoundTrip() throws {
        let wire = Data("""
        {"id":"c1","type":2,"revisionDate":"2026-01-02T03:04:05Z","name":"2.n|n|n",
         "fields":[{"type":0,"name":"2.serial|s|s","value":"2.v|v|v"},
                   {"Type":1,"Name":"2.hidden|h|h","Value":"2.hv|hv|hv"}]}
        """.utf8)
        let model = try JSONDecoder().decode(VaultwardenCipherModel.self, from: wire)
        XCTAssertEqual(model.fields.count, 2)
        XCTAssertEqual(model.fields[0].type, 0)
        XCTAssertEqual(model.fields[0].name, "2.serial|s|s")
        XCTAssertEqual(model.fields[1].type, 1)
        XCTAssertEqual(model.fields[1].value, "2.hv|hv|hv")

        let reDecoded = try JSONDecoder().decode(
            VaultwardenCipherModel.self, from: try JSONEncoder().encode(model)
        )
        XCTAssertEqual(reDecoded.fields, model.fields)
    }

    func testUnknownCipherAndCustomFieldTypesRemainUnknownAcrossRoundTrip() throws {
        let wire = Data(#"{"id":"c1","type":99,"revisionDate":"2026-01-02T03:04:05Z","name":"2.n|n|n","fields":[{"name":"2.f|f|f","value":"2.v|v|v"}]}"#.utf8)

        let model = try JSONDecoder().decode(VaultwardenCipherModel.self, from: wire)
        XCTAssertEqual(model.type, .unknown)
        XCTAssertEqual(model.rawType, 99)
        XCTAssertEqual(model.fields.first?.type, -1)

        let decoded = try JSONDecoder().decode(
            VaultwardenCipherModel.self,
            from: try JSONEncoder().encode(model)
        )
        XCTAssertEqual(decoded.type, .unknown)
        XCTAssertEqual(decoded.rawType, 99)
        XCTAssertEqual(decoded.fields.first?.type, -1)
    }

    func testOrganizationPermissionsDefaultClosedWhilePersonalDefaultsOpen() throws {
        let organization = try JSONDecoder().decode(
            VaultwardenCipherModel.self,
            from: Data(#"{"id":"c1","type":1,"organizationId":"o1","revisionDate":"2026-01-02T03:04:05Z"}"#.utf8)
        )
        let personal = try JSONDecoder().decode(
            VaultwardenCipherModel.self,
            from: Data(#"{"id":"c2","type":1,"revisionDate":"2026-01-02T03:04:05Z"}"#.utf8)
        )

        XCTAssertFalse(organization.edit)
        XCTAssertFalse(organization.viewPassword)
        XCTAssertTrue(personal.edit)
        XCTAssertTrue(personal.viewPassword)
    }

    /// Folder and organization membership must survive every spelling the
    /// server uses. A CodingKey derived from the Swift property spells these
    /// with a capital D (`folderID`), which is not a wire form at all: the
    /// server sends `FolderId` or `folderId`. Missing the lowerCamel spelling
    /// left every item looking unfiled, so no folder ever reached the sidebar.
    func testCipherAcceptsEveryFolderAndOrganizationSpelling() throws {
        let pascal = try JSONDecoder().decode(
            VaultwardenCipherModel.self,
            from: Data(#"{"Id":"c1","Type":1,"RevisionDate":"2026-01-02T03:04:05Z","Name":"2.n|n|n","FolderId":"f1","OrganizationId":"o1"}"#.utf8)
        )
        XCTAssertEqual(pascal.folderID, "f1")
        XCTAssertEqual(pascal.organizationID, "o1")

        let camel = try JSONDecoder().decode(
            VaultwardenCipherModel.self,
            from: Data(#"{"id":"c2","type":1,"revisionDate":"2026-01-02T03:04:05Z","name":"2.n|n|n","folderId":"f2","organizationId":"o2"}"#.utf8)
        )
        XCTAssertEqual(camel.folderID, "f2")
        XCTAssertEqual(camel.organizationID, "o2")

        // The form the sealed cache round-trips through still decodes.
        let reDecoded = try JSONDecoder().decode(
            VaultwardenCipherModel.self, from: try JSONEncoder().encode(camel)
        )
        XCTAssertEqual(reDecoded.folderID, "f2")
        XCTAssertEqual(reDecoded.organizationID, "o2")
    }

    /// The token grant is snake_case, but the wrapped key material is PascalCase
    /// on most servers and lowerCamel on some. Both must decode so a login never
    /// silently loses the key.
    func testTokenResponseAcceptsBothKeyCasings() throws {
        let pascal = try JSONDecoder().decode(
            VaultwardenTokenResponse.self,
            from: Data(#"{"access_token":"a","Key":"2.k","PrivateKey":"2.pk"}"#.utf8)
        )
        XCTAssertEqual(pascal.key, "2.k")
        XCTAssertEqual(pascal.privateKey, "2.pk")

        let lower = try JSONDecoder().decode(
            VaultwardenTokenResponse.self,
            from: Data(#"{"access_token":"a","key":"2.k2","privateKey":"2.pk2"}"#.utf8)
        )
        XCTAssertEqual(lower.key, "2.k2")
        XCTAssertEqual(lower.privateKey, "2.pk2")
    }
}
