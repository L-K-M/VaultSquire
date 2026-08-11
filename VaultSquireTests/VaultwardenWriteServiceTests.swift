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

    private func makePreservedCipher(
        folderID: String? = nil,
        fields: [VaultwardenCipherModel.CustomField] = [],
        passwordHistory: [VaultwardenCipherModel.PasswordHistoryEntry] = [],
        reprompt: Int? = nil,
        key: String? = nil,
        organizationID: String? = nil,
        collectionIds: [String] = []
    ) -> VaultwardenCipherModel {
        VaultwardenCipherModel(
            id: "cipher-1",
            type: .login,
            organizationID: organizationID,
            collectionIds: collectionIds,
            folderID: folderID,
            revisionDate: Date(timeIntervalSince1970: 1_700_000_000),
            key: key,
            reprompt: reprompt,
            passwordHistory: passwordHistory,
            name: "2.n|n|n",
            fields: fields
        )
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
        let body = try makeService().encodeBody(draft: draft, writeKey: userKey)
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
        let preserved = makePreservedCipher(
            folderID: "folder-1",
            fields: [VaultwardenCipherModel.CustomField(type: 1, name: "2.n|n|n", value: "2.v|v|v")]
        )
        let body = try makeService().encodeBody(
            draft: VaultItemDraft(title: "Renamed"),
            writeKey: userKey,
            preserved: preserved
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

    /// The regression this guards: a replacing PUT that omitted these fields
    /// silently reset them server-side — a wiped password history, a cleared
    /// reprompt requirement, a dropped per-item key.
    func testUpdatePreservesHistoryRepromptKeyAndMembershipVerbatim() throws {
        let preserved = makePreservedCipher(
            passwordHistory: [
                VaultwardenCipherModel.PasswordHistoryEntry(
                    password: "2.old|old|old",
                    lastUsedDate: Date(timeIntervalSince1970: 1_600_000_000)
                )
            ],
            reprompt: 1,
            key: "2.itemkey|itemkey|itemkey",
            organizationID: "org-1",
            collectionIds: ["col-1", "col-2"]
        )
        let body = try makeService().encodeBody(
            draft: VaultItemDraft(title: "Renamed"),
            writeKey: userKey,
            preserved: preserved
        )
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(json["Key"] as? String, "2.itemkey|itemkey|itemkey")
        XCTAssertEqual(json["Reprompt"] as? Int, 1)
        XCTAssertEqual(json["OrganizationId"] as? String, "org-1")
        XCTAssertEqual(json["CollectionIds"] as? [String], ["col-1", "col-2"])

        let history = try XCTUnwrap(json["PasswordHistory"] as? [[String: Any]])
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0]["Password"] as? String, "2.old|old|old")
        XCTAssertNotNil(history[0]["LastUsedDate"])

        // The concurrency precondition is the revision the edit is based on.
        XCTAssertEqual(
            json["lastKnownRevisionDate"] as? String,
            VaultwardenCipherModel.wireDateString(Date(timeIntervalSince1970: 1_700_000_000))
        )
    }

    /// A create carries no preservation fields at all, so the server's
    /// defaults apply rather than stale client state.
    func testCreateOmitsPreservationFields() throws {
        let body = try makeService().encodeBody(draft: VaultItemDraft(title: "Bare"), writeKey: userKey)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["FolderId"])
        XCTAssertNil(json["Fields"])
        XCTAssertNil(json["PasswordHistory"])
        XCTAssertNil(json["Reprompt"])
        XCTAssertNil(json["Key"])
        XCTAssertNil(json["OrganizationId"])
        XCTAssertNil(json["CollectionIds"])
        XCTAssertNil(json["lastKnownRevisionDate"])
    }

    func testEmptyFieldsAreOmitted() throws {
        let draft = VaultItemDraft(title: "Bare", username: "", password: "", totp: "", websites: [], notes: "")
        let body = try makeService().encodeBody(draft: draft, writeKey: userKey)
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
            cipherID: "cipher-1",
            draft: draft,
            writeKey: userKey,
            accessToken: "t",
            preserved: makePreservedCipher()
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

    /// A revision precondition failure is its own outcome: never a generic
    /// rejection the caller might blindly retry over a concurrent edit.
    func testRevisionConflictIsReportedDistinctly() async throws {
        StubServer.shared.on("/api/ciphers/cipher-1", respond: .json(409, "{}"))
        let result = await (try makeService()).updateLogin(
            cipherID: "cipher-1",
            draft: VaultItemDraft(title: "x"),
            writeKey: userKey,
            accessToken: "t",
            preserved: makePreservedCipher()
        )
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .conflict)
    }
}
