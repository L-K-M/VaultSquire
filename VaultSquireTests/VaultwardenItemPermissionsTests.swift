import CryptoKit
import XCTest
@testable import VaultSquire

/// Server-enforced item permissions (IMPLEMENTATION_REPORT.md §"Cipher
/// Model"): the sync's `edit` and `viewPassword` flags must be honored by
/// every entry point — a hide-passwords policy is a client enforcement
/// requirement even though the ciphertext decrypts locally — and an unknown
/// item type must never be coerced into a nearby kind.
final class VaultwardenItemPermissionsTests: XCTestCase {
    private let account = AccountID(provider: .vaultwarden, rawValue: "VSQ-Canary-account")

    private var userKey: VaultwardenSymmetricKey {
        try! VaultwardenSymmetricKey(keyData: Data((0..<64).map { UInt8($0) }))
    }

    private func keyring() -> VaultwardenKeyring {
        VaultwardenKeyring(userKey: userKey)
    }

    private func cipher(
        type: VaultwardenCipherModel.ItemType = .login,
        organizationID: String? = nil,
        edit: Bool? = nil,
        viewPassword: Bool? = nil,
        login: VaultwardenCipherModel.Login? = nil
    ) throws -> VaultwardenCipherModel {
        VaultwardenCipherModel(
            id: "cipher-1",
            type: type,
            organizationID: organizationID,
            revisionDate: Date(timeIntervalSince1970: 1_700_000_000),
            name: try VaultwardenCipher.encryptToType2(Data("GitHub".utf8), key: userKey),
            login: login,
            edit: edit,
            viewPassword: viewPassword
        )
    }

    private func loginWithPassword(_ password: String = "VSQ-Canary-hunter2") throws -> VaultwardenCipherModel.Login {
        .init(
            username: try VaultwardenCipher.encryptToType2(Data("octocat".utf8), key: userKey),
            password: try VaultwardenCipher.encryptToType2(Data(password.utf8), key: userKey),
            totp: nil,
            uris: []
        )
    }

    // MARK: - viewPassword (hide-passwords policy)

    func testViewPasswordFalseDropsRevealAndCopyCapabilities() throws {
        let item = try cipher(viewPassword: false, login: try loginWithPassword())
        let projection = VaultwardenItemDecryptor.projection(
            for: item, keyring: keyring(), account: account, folderNames: [:], generation: 1
        )
        XCTAssertFalse(projection.capabilities.contains(.revealSecret))
        XCTAssertFalse(projection.capabilities.contains(.copySecret))
        XCTAssertTrue(projection.capabilities.contains(.viewItems), "browsing stays available")
    }

    func testViewPasswordFalseMarksTheDetailAsNotRevealable() throws {
        let item = try cipher(viewPassword: false, login: try loginWithPassword())
        let detail = VaultwardenItemDecryptor.detail(
            for: item, keyring: keyring(), account: account, generation: 1
        )
        XCTAssertFalse(detail.canRevealSecrets)
    }

    func testAbsentViewPasswordAllowsRevealAndCopy() throws {
        let item = try cipher(login: try loginWithPassword())
        let projection = VaultwardenItemDecryptor.projection(
            for: item, keyring: keyring(), account: account, folderNames: [:], generation: 1
        )
        XCTAssertTrue(projection.capabilities.contains(.revealSecret))
        XCTAssertTrue(projection.capabilities.contains(.copySecret))
        let detail = VaultwardenItemDecryptor.detail(
            for: item, keyring: keyring(), account: account, generation: 1
        )
        XCTAssertTrue(detail.canRevealSecrets)
    }

    // MARK: - Wire decoding of the new fields

    func testModelDecodesPermissionAndRepromptFieldsPascalCase() throws {
        let wire = Data("""
        {"id":"c1","type":1,"revisionDate":"2026-01-02T03:04:05Z","name":"2.n|n|n",
         "Edit":false,"ViewPassword":false,"Reprompt":1,
         "PasswordHistory":[{"Password":"2.h|h|h","LastUsedDate":"2026-01-01T00:00:00Z"}]}
        """.utf8)
        let model = try JSONDecoder().decode(VaultwardenCipherModel.self, from: wire)
        XCTAssertEqual(model.edit, false as Bool?)
        XCTAssertEqual(model.viewPassword, false as Bool?)
        XCTAssertEqual(model.reprompt, 1)
        XCTAssertEqual(model.passwordHistory?.count, 1)
        XCTAssertEqual(model.passwordHistory?.first?.password, "2.h|h|h")
        XCTAssertEqual(model.passwordHistory?.first?.lastUsedDate, "2026-01-01T00:00:00Z")

        // The sealed cache round-trip preserves them.
        let reDecoded = try JSONDecoder().decode(
            VaultwardenCipherModel.self, from: try JSONEncoder().encode(model)
        )
        XCTAssertEqual(reDecoded.edit, false as Bool?)
        XCTAssertEqual(reDecoded.viewPassword, false as Bool?)
        XCTAssertEqual(reDecoded.reprompt, 1)
        XCTAssertEqual(reDecoded.passwordHistory, model.passwordHistory)
    }

    func testModelDecodesPermissionFieldsLowerCamel() throws {
        let wire = Data(#"{"id":"c1","type":1,"revisionDate":"2026-01-02T03:04:05Z","name":"2.n|n|n","edit":true,"viewPassword":true,"reprompt":0}"#.utf8)
        let model = try JSONDecoder().decode(VaultwardenCipherModel.self, from: wire)
        XCTAssertEqual(model.edit, true as Bool?)
        XCTAssertEqual(model.viewPassword, true as Bool?)
        XCTAssertEqual(model.reprompt, 0)
    }

    // MARK: - Unknown item types

    func testUnknownItemTypeIsUnsupportedNotASecureNote() throws {
        let item = try cipher(type: .unknown)
        let projection = VaultwardenItemDecryptor.projection(
            for: item, keyring: keyring(), account: account, folderNames: [:], generation: 1
        )
        XCTAssertEqual(projection.category, .unsupported)
    }

    func testUnknownWireTypeDecodesAsUnknownNotSecureNote() throws {
        let wire = Data(#"{"Id":"c1","Type":9,"RevisionDate":"2026-01-02T03:04:05Z","Name":"2.n|n|n"}"#.utf8)
        let model = try JSONDecoder().decode(VaultwardenCipherModel.self, from: wire)
        XCTAssertEqual(model.type, .unknown)
    }

    // MARK: - Write gating

    func testOrgItemsAreNotEditableInThisSlice() throws {
        let item = try cipher(organizationID: "org-1", login: try loginWithPassword())
        let snapshot = snapshot(ciphers: [item])
        let service = makeService()

        let id = VaultItemID(
            space: VaultSpaceID(account: account, scope: .personal), rawValue: "cipher-1"
        )
        XCTAssertNil(
            service.draft(for: id, keyring: keyring(), snapshot: snapshot),
            "organization items are read-only until the write contract is proven"
        )
    }

    func testServerReadOnlyItemsAreNotEditable() throws {
        let item = try cipher(edit: false, login: try loginWithPassword())
        let snapshot = snapshot(ciphers: [item])
        let service = makeService()

        let id = VaultItemID(
            space: VaultSpaceID(account: account, scope: .personal), rawValue: "cipher-1"
        )
        XCTAssertNil(service.draft(for: id, keyring: keyring(), snapshot: snapshot))
    }

    func testPersonalEditableItemsStillGetADraft() throws {
        let item = try cipher(edit: true, login: try loginWithPassword())
        let snapshot = snapshot(ciphers: [item])
        let service = makeService()

        let id = VaultItemID(
            space: VaultSpaceID(account: account, scope: .personal), rawValue: "cipher-1"
        )
        let draft = service.draft(for: id, keyring: keyring(), snapshot: snapshot)
        XCTAssertNotNil(draft)
        XCTAssertEqual(draft?.title, "GitHub")
    }

    // MARK: - Helpers

    private func snapshot(ciphers: [VaultwardenCipherModel]) -> VaultwardenVaultSnapshot {
        VaultwardenVaultSnapshot(
            version: VaultwardenVaultSnapshot.currentVersion,
            serverBaseURL: "https://vault.example.com",
            identityBaseURL: "https://vault.example.com/identity",
            email: "u@example.com",
            kdf: .init(configuration: .pbkdf2SHA256(iterations: 600_000)),
            wrappedUserKey: "2.k|k|k",
            wrappedPrivateKey: nil,
            organizations: [],
            folders: [],
            ciphers: ciphers,
            syncedAt: Date(timeIntervalSince1970: 1),
            generation: 1
        )
    }

    private func makeService() -> VaultwardenAccountService {
        VaultwardenAccountService(
            account: account,
            credentialStore: InMemoryCredentialStore(),
            vaultCache: VaultwardenVaultCache(keyProvider: { SymmetricKey(size: .bits256) }),
            descriptorStore: AccountDescriptorStore(
                defaults: UserDefaults(suiteName: "VaultSquireTest-\(UUID().uuidString)")!
            )
        )
    }
}
