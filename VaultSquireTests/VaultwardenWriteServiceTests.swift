import XCTest
@testable import VaultSquire

final class VaultwardenWriteServiceTests: XCTestCase {
    private let userKey = try! VaultwardenSymmetricKey(keyData: Data((0..<64).map { UInt8($0) }))

    override func setUp() {
        super.setUp()
        StubServer.shared.reset()
    }

    override func tearDown() {
        StubServer.shared.reset()
        super.tearDown()
    }

    private func makeService() throws -> VaultwardenWriteService {
        VaultwardenWriteService(transport: try VaultwardenTestFactory.stubbedTransport())
    }

    private func decrypt(_ encString: String) throws -> String {
        let parsed = try VaultwardenEncString.parse(encString)
        let data = try VaultwardenCipher.decrypt(parsed, key: userKey)
        return String(decoding: data, as: UTF8.self)
    }

    func testEncodeBodyEncryptsEveryUserField() throws {
        let draft = VaultItemDraft(
            title: "GitHub",
            username: "octocat",
            password: "VSQ-Canary-hunter2",
            totp: "JBSWY3DPEHPK3PXP",
            websites: ["https://github.com", "https://gist.github.com"],
            notes: "a note",
            favorite: true
        )
        let body = try makeService().encodeBody(draft: draft, userKey: userKey)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(json["Type"] as? Int, 1)
        XCTAssertEqual(json["Favorite"] as? Bool, true)
        XCTAssertEqual(try decrypt(try XCTUnwrap(json["Name"] as? String)), "GitHub")
        XCTAssertEqual(try decrypt(try XCTUnwrap(json["Notes"] as? String)), "a note")

        let login = try XCTUnwrap(json["Login"] as? [String: Any])
        XCTAssertEqual(try decrypt(try XCTUnwrap(login["Username"] as? String)), "octocat")
        XCTAssertEqual(try decrypt(try XCTUnwrap(login["Password"] as? String)), "VSQ-Canary-hunter2")
        XCTAssertEqual(try decrypt(try XCTUnwrap(login["Totp"] as? String)), "JBSWY3DPEHPK3PXP")

        let uris = try XCTUnwrap(login["Uris"] as? [[String: Any]])
        XCTAssertEqual(uris.count, 2)
        XCTAssertEqual(try decrypt(try XCTUnwrap(uris[0]["Uri"] as? String)), "https://github.com")

        // No plaintext of any field leaks into the request bytes.
        let raw = String(decoding: body, as: UTF8.self)
        for secret in ["GitHub", "octocat", "VSQ-Canary-hunter2", "github.com", "a note"] {
            XCTAssertFalse(raw.contains(secret), "\(secret) must not appear in plaintext")
        }
    }

    func testUpdatePreservesFolderAndCustomFieldsVerbatim() throws {
        let preserved = [
            VaultwardenCipherModel.CustomField(type: 1, name: "2.n|n|n", value: "2.v|v|v")
        ]
        let body = try makeService().encodeBody(
            draft: VaultItemDraft(title: "Renamed"),
            userKey: userKey,
            folderID: "folder-1",
            preservedFields: preserved
        )
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["FolderId"] as? String, "folder-1")
        let fields = try XCTUnwrap(json["Fields"] as? [[String: Any]])
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields[0]["Type"] as? Int, 1)
        // Pass-through: the EncStrings are byte-identical, never re-encrypted.
        XCTAssertEqual(fields[0]["Name"] as? String, "2.n|n|n")
        XCTAssertEqual(fields[0]["Value"] as? String, "2.v|v|v")
    }

    /// The pinned server replaces `reprompt` and `passwordHistory` with
    /// whatever the update body carries (Vaultwarden 1.37.1
    /// `update_cipher_from_data`), so an edit must send the existing values
    /// through or it silently strips an item's master-password reprompt
    /// protection and wipes its password history.
    func testUpdatePreservesRepromptPasswordHistoryAndSendsRevisionGuard() throws {
        let history = VaultwardenCipherModel.PasswordHistoryEntry(
            password: "2.old-pw|pw|pw", lastUsedDate: "2026-01-02T03:04:05.678Z"
        )
        let body = try makeService().encodeBody(
            draft: VaultItemDraft(title: "Renamed"),
            userKey: userKey,
            preservedReprompt: 1,
            preservedPasswordHistory: [history],
            lastKnownRevisionDate: "2026-02-03T04:05:06.789Z"
        )
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["Reprompt"] as? Int, 1)
        XCTAssertEqual(json["LastKnownRevisionDate"] as? String, "2026-02-03T04:05:06.789Z")
        let passwordHistory = try XCTUnwrap(json["PasswordHistory"] as? [[String: Any]])
        XCTAssertEqual(passwordHistory.count, 1)
        XCTAssertEqual(passwordHistory[0]["Password"] as? String, "2.old-pw|pw|pw")
        XCTAssertEqual(passwordHistory[0]["LastUsedDate"] as? String, "2026-01-02T03:04:05.678Z")
    }

    /// A create is a fresh object: no reprompt, no history, no revision guard.
    func testCreateOmitsRepromptHistoryAndRevisionGuard() throws {
        let body = try makeService().encodeBody(draft: VaultItemDraft(title: "Bare"), userKey: userKey)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["Reprompt"])
        XCTAssertNil(json["PasswordHistory"])
        XCTAssertNil(json["LastKnownRevisionDate"])
    }

    /// updateLogin derives the pass-through values from the existing cipher,
    /// so the caller cannot forget to preserve a protected field.
    func testUpdateLoginPassesExistingItemThrough() async throws {
        StubServer.shared.on("/api/ciphers/cipher-1", respond: .json(200, "{}"))
        let existing = VaultwardenCipherModel(
            id: "cipher-1",
            type: .login,
            folderID: "folder-1",
            revisionDate: Date(timeIntervalSince1970: 1_700_000_000),
            name: "2.n|n|n",
            fields: [.init(type: 0, name: "2.fn|fn|fn", value: "2.fv|fv|fv")],
            reprompt: 1,
            passwordHistory: [.init(password: "2.h|h|h", lastUsedDate: "2026-01-02T03:04:05.678Z")]
        )

        let result = await (try makeService()).updateLogin(
            cipherID: "cipher-1",
            draft: VaultItemDraft(title: "Renamed"),
            userKey: userKey,
            accessToken: "t",
            existing: existing
        )

        guard case .success = result else { return XCTFail("expected success") }
        let request = try XCTUnwrap(StubServer.shared.lastRequest(pathSuffix: "/api/ciphers/cipher-1"))
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        )
        XCTAssertEqual(json["FolderId"] as? String, "folder-1")
        XCTAssertEqual(json["Reprompt"] as? Int, 1)
        XCTAssertNotNil(json["LastKnownRevisionDate"])
        XCTAssertNotNil(json["PasswordHistory"])
        let fields = try XCTUnwrap(json["Fields"] as? [[String: Any]])
        XCTAssertEqual(fields[0]["Value"] as? String, "2.fv|fv|fv")
    }

    /// The pinned server's stale-write guard answers a 400 whose message names
    /// the out-of-date copy. That is a conflict the user must resolve by
    /// syncing — never a blind retry.
    func testStaleRevisionRejectionIsAConflictNotAGenericRejection() async throws {
        StubServer.shared.on(
            "/api/ciphers/cipher-1",
            respond: .json(400, "{\"Message\":\"The client copy of this cipher is out of date. Resync the client and try again.\"}")
        )
        let existing = VaultwardenCipherModel(
            id: "cipher-1",
            type: .login,
            revisionDate: Date(timeIntervalSince1970: 1_700_000_000),
            name: "2.n|n|n"
        )

        let result = await (try makeService()).updateLogin(
            cipherID: "cipher-1",
            draft: VaultItemDraft(title: "Renamed"),
            userKey: userKey,
            accessToken: "t",
            existing: existing
        )

        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .conflict)
    }

    func testCreateOmitsFolderAndFieldsWhenAbsent() throws {
        let body = try makeService().encodeBody(draft: VaultItemDraft(title: "Bare"), userKey: userKey)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["FolderId"])
        XCTAssertNil(json["Fields"])
    }

    func testEmptyFieldsAreOmitted() throws {
        let draft = VaultItemDraft(title: "Bare", username: "", password: "", totp: "", websites: [], notes: "")
        let body = try makeService().encodeBody(draft: draft, userKey: userKey)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["Notes"], "an empty note is omitted, not an empty EncString")
        let login = try XCTUnwrap(json["Login"] as? [String: Any])
        XCTAssertNil(login["Username"])
        XCTAssertNil(login["Password"])
        XCTAssertEqual((login["Uris"] as? [[String: Any]])?.count, 0)
    }

    func testCreateLoginPostsToCiphersWithBearer() async throws {
        StubServer.shared.on("/api/ciphers", respond: .json(200, "{\"Id\":\"new\"}"))
        let draft = VaultItemDraft(title: "GitHub", username: "octocat", password: "pw")

        let result = await (try makeService()).createLogin(
            draft: draft, userKey: userKey, accessToken: "VSQ-token"
        )

        guard case .success = result else { return XCTFail("expected success, got \(result)") }
        let request = try XCTUnwrap(StubServer.shared.lastRequest(pathSuffix: "/api/ciphers"))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Authorization"], "Bearer VSQ-token")
    }

    func testUpdateLoginPutsToCipherIDPath() async throws {
        StubServer.shared.on("/api/ciphers/cipher-1", respond: .json(200, "{}"))
        let draft = VaultItemDraft(title: "Renamed")

        let result = await (try makeService()).updateLogin(
            cipherID: "cipher-1", draft: draft, userKey: userKey, accessToken: "t"
        )

        guard case .success = result else { return XCTFail("expected success") }
        let request = try XCTUnwrap(StubServer.shared.lastRequest(pathSuffix: "/api/ciphers/cipher-1"))
        XCTAssertEqual(request.method, "PUT")
    }

    func testUnauthorizedResponseIsSessionExpired() async throws {
        StubServer.shared.on("/api/ciphers", respond: .json(401, "{}"))
        let result = await (try makeService()).createLogin(
            draft: VaultItemDraft(title: "x"), userKey: userKey, accessToken: "t"
        )
        // Result<Void, _> is not Equatable (Void is not), so match the case.
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .sessionExpired)
    }

    func testServerRejectionIsReported() async throws {
        StubServer.shared.on("/api/ciphers", respond: .json(400, "{\"message\":\"bad\"}"))
        let result = await (try makeService()).createLogin(
            draft: VaultItemDraft(title: "x"), userKey: userKey, accessToken: "t"
        )
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .rejected)
    }
}
