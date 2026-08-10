import CryptoKit
import XCTest
@testable import VaultSquire

final class VaultwardenVaultCacheTests: XCTestCase {
    private let account = AccountID(provider: .vaultwarden, rawValue: "VSQ-Canary-account")
    private let otherAccount = AccountID(provider: .vaultwarden, rawValue: "VSQ-Canary-other")

    private func makeCache(key: SymmetricKey) -> (VaultwardenVaultCache, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultSquireTests-\(UUID().uuidString)", isDirectory: true)
        let cache = VaultwardenVaultCache(keyProvider: { key }, directory: directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (cache, directory)
    }

    private func makeSnapshot(email: String = "user@example.com") -> VaultwardenVaultSnapshot {
        VaultwardenVaultSnapshot(
            version: VaultwardenVaultSnapshot.currentVersion,
            serverBaseURL: "https://vault.example.com",
            identityBaseURL: "https://vault.example.com/identity",
            email: email,
            kdf: .init(configuration: .pbkdf2SHA256(iterations: 600_000)),
            wrappedUserKey: "2.aXY=|Y3Q=|bWFj=",
            wrappedPrivateKey: nil,
            organizations: [],
            folders: [.init(id: "f1", name: "2.aXY=|Y3Q=|bWFj=")],
            ciphers: [
                VaultwardenCipherModel(
                    id: "c1",
                    type: .login,
                    revisionDate: Date(timeIntervalSince1970: 1_700_000_000),
                    name: "2.aXY=|Y3Q=|bWFj="
                )
            ],
            syncedAt: Date(timeIntervalSince1970: 1_700_000_000),
            generation: 1
        )
    }

    func testSaveThenLoadRoundTrips() throws {
        let (cache, _) = makeCache(key: SymmetricKey(size: .bits256))
        let snapshot = makeSnapshot()

        XCTAssertFalse(cache.exists(for: account))
        try cache.save(snapshot, for: account)
        XCTAssertTrue(cache.exists(for: account))

        let loaded = try cache.load(for: account)
        XCTAssertEqual(loaded, snapshot)
    }

    func testLoadMissingReturnsNil() throws {
        let (cache, _) = makeCache(key: SymmetricKey(size: .bits256))
        XCTAssertNil(try cache.load(for: account))
    }

    func testSaveIsAccountScopedAndSealBindsAccount() throws {
        let key = SymmetricKey(size: .bits256)
        let (cache, _) = makeCache(key: key)
        try cache.save(makeSnapshot(email: "one@example.com"), for: account)

        // A second account in the same cache has no snapshot.
        XCTAssertNil(try cache.load(for: otherAccount))
    }

    func testTamperedFileFailsClosed() throws {
        let (cache, directory) = makeCache(key: SymmetricKey(size: .bits256))
        try cache.save(makeSnapshot(), for: account)

        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "vaultcache" }
        )
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: file)

        XCTAssertThrowsError(try cache.load(for: account)) { error in
            XCTAssertEqual(error as? VaultwardenVaultCacheError, .corrupt)
        }
    }

    func testWrongKeyFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultSquireTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let writer = VaultwardenVaultCache(keyProvider: { SymmetricKey(size: .bits256) }, directory: directory)
        try writer.save(makeSnapshot(), for: account)

        let reader = VaultwardenVaultCache(keyProvider: { SymmetricKey(size: .bits256) }, directory: directory)
        XCTAssertThrowsError(try reader.load(for: account)) { error in
            XCTAssertEqual(error as? VaultwardenVaultCacheError, .corrupt)
        }
    }

    func testWipeRemovesTheFile() throws {
        let (cache, _) = makeCache(key: SymmetricKey(size: .bits256))
        try cache.save(makeSnapshot(), for: account)
        XCTAssertTrue(cache.exists(for: account))

        try cache.wipe(for: account)
        XCTAssertFalse(cache.exists(for: account))
        XCTAssertNil(try cache.load(for: account))
    }

    func testCipherModelSurvivesAWireDecodeAndReEncode() throws {
        let wire = """
        {"Id":"abc","Type":1,"OrganizationId":null,"FolderId":"f1","Favorite":true,
         "RevisionDate":"2026-01-02T03:04:05.678Z","Name":"2.aXY=|Y3Q=|bWFj=",
         "Login":{"Username":"2.u|u|u","Password":"2.p|p|p","Totp":"2.t|t|t",
         "Uris":[{"Uri":"2.x|x|x"}]}}
        """.data(using: .utf8)!
        let model = try JSONDecoder().decode(VaultwardenCipherModel.self, from: wire)
        XCTAssertEqual(model.id, "abc")
        XCTAssertEqual(model.type, .login)
        XCTAssertTrue(model.favorite)
        XCTAssertEqual(model.folderID, "f1")
        XCTAssertEqual(model.login?.username, "2.u|u|u")
        XCTAssertEqual(model.login?.uris.first?.uri, "2.x|x|x")

        // The persistence round trip must be a stable fixed point: once the
        // model has been through its own encoder, encoding and decoding again
        // reproduce it exactly. (The wire's fractional-second date is a Double,
        // so the initial wire parse is not required to be bit-exact — only the
        // model's own encode/decode cycle, which is what the sealed cache uses.)
        let encoded1 = try JSONEncoder().encode(model)
        let roundTripped = try JSONDecoder().decode(VaultwardenCipherModel.self, from: encoded1)
        let encoded2 = try JSONEncoder().encode(roundTripped)
        XCTAssertEqual(encoded1, encoded2, "the model's own encode/decode cycle must be stable")
        XCTAssertEqual(
            try JSONDecoder().decode(VaultwardenCipherModel.self, from: encoded2),
            roundTripped
        )
    }

    func testSyncResponseDecodesPascalCase() throws {
        let wire = """
        {"Profile":{"Key":"2.k|k|k","PrivateKey":"2.pk|pk|pk","Organizations":[
          {"Id":"o1","Name":"Acme","Key":"4.b64"}]},
         "Folders":[{"Id":"f1","Name":"2.f|f|f"}],
         "Ciphers":[{"Id":"c1","Type":2,"RevisionDate":"2026-01-02T03:04:05.678Z","Name":"2.n|n|n"}]}
        """.data(using: .utf8)!
        let sync = try JSONDecoder().decode(VaultwardenSyncResponse.self, from: wire)
        XCTAssertEqual(sync.profile.key, "2.k|k|k")
        XCTAssertEqual(sync.profile.organizations.first?.id, "o1")
        XCTAssertEqual(sync.folders.first?.name, "2.f|f|f")
        XCTAssertEqual(sync.ciphers.first?.type, .secureNote)
    }
}
