import XCTest
@testable import VaultSquire

/// The cipher-model fidelity contract: unknown types are preserved, trashed
/// and archived items never present as live, server permission flags are
/// enforced at the use-case boundary, and per-item cipher keys actually
/// decrypt the ciphers that carry them.
final class VaultwardenCipherFidelityTests: XCTestCase {
    private let account = AccountID.vaultwardenPrimary
    private let userKey = try! VaultwardenSymmetricKey(keyData: Data((0..<64).map { UInt8($0) }))

    private func enc(_ plaintext: String, under key: VaultwardenSymmetricKey? = nil) throws -> String {
        try VaultwardenCipher.encryptToType2(Data(plaintext.utf8), key: key ?? userKey)
    }

    private var keyring: VaultwardenKeyring { VaultwardenKeyring(userKey: userKey) }

    // MARK: - Wire fidelity

    func testUnknownAndNewerItemTypesSurviveRoundTrips() throws {
        for rawType in [5, 6, 7, 8, 99] {
            let wire = Data("{\"Id\":\"c1\",\"Type\":\(rawType),\"Name\":\"2.n|n|n\"}".utf8)
            let model = try JSONDecoder().decode(VaultwardenCipherModel.self, from: wire)
            XCTAssertEqual(model.type.rawValue, rawType, "type \(rawType) must not be flattened")
            let reencoded = try JSONEncoder().encode(model)
            let redecoded = try JSONDecoder().decode(VaultwardenCipherModel.self, from: reencoded)
            XCTAssertEqual(redecoded.type.rawValue, rawType, "type \(rawType) must survive persistence")
        }
    }

    func testSSHKeyTypeIsNamedButNotCoercedIntoADisplayCategory() throws {
        let type = VaultwardenCipherModel.ItemType.sshKey
        XCTAssertEqual(VaultwardenItemDecryptor.category(for: type), .unsupported)
        XCTAssertEqual(VaultwardenCipherModel.ItemType(rawValue: 99).rawValue, 99)
    }

    func testPreservationFieldsDecodeAndRoundTrip() throws {
        let wire = Data("""
        {"Id":"c1","Type":1,"OrganizationId":"org-1","CollectionIds":["col-1"],
         "FolderId":"f1","Key":"2.k|k|k","Reprompt":1,"Edit":false,"ViewPassword":false,
         "Permissions":{"Delete":true,"Restore":false},
         "PasswordHistory":[{"Password":"2.p|p|p","LastUsedDate":"2026-01-02T03:04:05.000Z"}],
         "CreationDate":"2025-12-31T23:59:59.000Z",
         "DeletedDate":null,"ArchivedDate":"2026-02-01T00:00:00.000Z",
         "Name":"2.n|n|n"}
        """.utf8)
        let model = try JSONDecoder().decode(VaultwardenCipherModel.self, from: wire)

        XCTAssertEqual(model.key, "2.k|k|k")
        XCTAssertEqual(model.reprompt, 1)
        XCTAssertTrue(model.requiresReprompt)
        XCTAssertEqual(model.edit, false)
        XCTAssertEqual(model.viewPassword, false)
        XCTAssertEqual(model.permissions?.delete, true)
        XCTAssertEqual(model.permissions?.restore, false)
        XCTAssertEqual(model.collectionIds, ["col-1"])
        XCTAssertEqual(model.organizationID, "org-1")
        XCTAssertNotNil(model.creationDate)
        XCTAssertNil(model.deletedDate)
        XCTAssertFalse(model.isTrashed)
        XCTAssertTrue(model.isArchived)
        XCTAssertEqual(model.passwordHistory.count, 1)
        XCTAssertEqual(model.passwordHistory[0].password, "2.p|p|p")
        XCTAssertNotNil(model.passwordHistory[0].lastUsedDate)

        let reencoded = try JSONEncoder().encode(model)
        let redecoded = try JSONDecoder().decode(VaultwardenCipherModel.self, from: reencoded)
        XCTAssertEqual(redecoded, model, "the sealed-cache round trip must be lossless")
    }

    // MARK: - Trash and archive visibility

    private func makeLiveCipher(deletedDate: Date? = nil, archivedDate: Date? = nil) throws -> VaultwardenCipherModel {
        VaultwardenCipherModel(
            id: "c1",
            type: .login,
            revisionDate: Date(timeIntervalSince1970: 1_700_000_000),
            deletedDate: deletedDate,
            archivedDate: archivedDate,
            name: try enc("GitHub")
        )
    }

    func testTrashedAndArchivedCiphersProduceNoProjectionOrDetail() throws {
        let live = try makeLiveCipher()
        XCTAssertNotNil(
            VaultwardenItemDecryptor.projection(
                for: live, keyring: keyring, account: account, folderNames: [:], generation: 1
            )
        )

        for cipher in [
            try makeLiveCipher(deletedDate: Date()),
            try makeLiveCipher(archivedDate: Date()),
        ] {
            XCTAssertNil(
                VaultwardenItemDecryptor.projection(
                    for: cipher, keyring: keyring, account: account, folderNames: [:], generation: 1
                ),
                "trashed and archived ciphers stay out of default lists and search"
            )
            XCTAssertNil(
                VaultwardenItemDecryptor.detail(
                    for: cipher, keyring: keyring, account: account, generation: 1
                ),
                "trashed and archived ciphers have no detail to reveal"
            )
        }
    }

    // MARK: - Server permission enforcement

    func testViewPasswordFalseEmitsNoConcealedFields() throws {
        let cipher = VaultwardenCipherModel(
            id: "c1",
            type: .login,
            revisionDate: Date(timeIntervalSince1970: 1_700_000_000),
            viewPassword: false,
            name: try enc("GitHub"),
            login: .init(
                username: try enc("octocat"),
                password: try enc("VSQ-secret"),
                totp: try enc("JBSWY3DPEHPK3PXP")
            ),
            fields: [.init(type: 1, name: try enc("API key"), value: try enc("VSQ-hidden"))]
        )

        let detail = try XCTUnwrap(VaultwardenItemDecryptor.detail(
            for: cipher, keyring: keyring, account: account, generation: 1
        ))
        // Non-secret fields still show; nothing concealable is emitted.
        XCTAssertEqual(detail.title, "GitHub")
        XCTAssertEqual(detail.fields.first { $0.label == "Username" }?.value, "octocat")
        XCTAssertNil(detail.fields.first { $0.kind == .secret }, "no secret field may be emitted")
        XCTAssertNil(detail.fields.first { $0.kind == .totpSeed }, "no TOTP field may be emitted")
        XCTAssertNil(detail.fields.first { $0.label == "API key" }, "hidden custom fields are concealed too")
    }

    func testViewPasswordTrueStillReveals() throws {
        let cipher = VaultwardenCipherModel(
            id: "c1",
            type: .login,
            revisionDate: Date(timeIntervalSince1970: 1_700_000_000),
            viewPassword: true,
            name: try enc("GitHub"),
            login: .init(username: try enc("octocat"), password: try enc("VSQ-secret"))
        )
        let detail = try XCTUnwrap(VaultwardenItemDecryptor.detail(
            for: cipher, keyring: keyring, account: account, generation: 1
        ))
        XCTAssertEqual(detail.fields.first { $0.label == "Password" }?.value, "VSQ-secret")
    }

    // MARK: - Per-item cipher keys

    private func makeItemKeyedCipher() throws -> (cipher: VaultwardenCipherModel, itemKey: VaultwardenSymmetricKey) {
        let itemKey = try VaultwardenSymmetricKey(keyData: Data(repeating: 0xAB, count: 64))
        let wrappedItemKey = try VaultwardenCipher.encryptToType2(Data(repeating: 0xAB, count: 64), key: userKey)
        let cipher = VaultwardenCipherModel(
            id: "c1",
            type: .login,
            revisionDate: Date(timeIntervalSince1970: 1_700_000_000),
            key: wrappedItemKey,
            name: try enc("GitHub", under: itemKey),
            login: .init(
                username: try enc("octocat", under: itemKey),
                password: try enc("VSQ-secret", under: itemKey),
                uris: [.init(uri: try enc("https://github.com", under: itemKey))]
            )
        )
        return (cipher, itemKey)
    }

    func testCipherKeyDecryptsFieldsUnderTheItemKey() throws {
        let (cipher, _) = try makeItemKeyedCipher()
        let detail = try XCTUnwrap(VaultwardenItemDecryptor.detail(
            for: cipher, keyring: keyring, account: account, generation: 1
        ))
        XCTAssertEqual(detail.title, "GitHub")
        XCTAssertEqual(detail.fields.first { $0.label == "Password" }?.value, "VSQ-secret")

        let projection = try XCTUnwrap(VaultwardenItemDecryptor.projection(
            for: cipher, keyring: keyring, account: account, folderNames: [:], generation: 1
        ))
        XCTAssertEqual(projection.displayTitle, "GitHub")
        XCTAssertEqual(projection.username, "octocat")
        XCTAssertEqual(projection.websites, ["https://github.com"])
    }

    /// `favorite` decodes and round-trips already (`testPreservationFieldsDecodeAndRoundTrip`
    /// covers the wire model); this is the read side, which previously had no
    /// field on `VaultItemProjection` at all to carry it into.
    func testFavoriteSurfacesOnTheProjection() throws {
        let favorited = VaultwardenCipherModel(
            id: "c1", type: .login, favorite: true,
            revisionDate: Date(timeIntervalSince1970: 1_700_000_000), name: try enc("GitHub")
        )
        let notFavorited = VaultwardenCipherModel(
            id: "c2", type: .login, favorite: false,
            revisionDate: Date(timeIntervalSince1970: 1_700_000_000), name: try enc("GitLab")
        )

        let favoritedProjection = try XCTUnwrap(VaultwardenItemDecryptor.projection(
            for: favorited, keyring: keyring, account: account, folderNames: [:], generation: 1
        ))
        let notFavoritedProjection = try XCTUnwrap(VaultwardenItemDecryptor.projection(
            for: notFavorited, keyring: keyring, account: account, folderNames: [:], generation: 1
        ))

        XCTAssertTrue(favoritedProjection.favorite)
        XCTAssertFalse(notFavoritedProjection.favorite)
    }

    func testACipherKeyFromAnotherCipherDecryptsNothingRatherThanGarbage() throws {
        let (cipher, _) = try makeItemKeyedCipher()
        // Rewrap the same item key under a DIFFERENT account key: the unwrap
        // must fail closed and the item must show nothing decrypted.
        let otherAccountKey = try VaultwardenSymmetricKey(keyData: Data(repeating: 0x11, count: 64))
        let wrongWrapped = try VaultwardenCipher.encryptToType2(Data(repeating: 0xAB, count: 64), key: otherAccountKey)
        let tampered = VaultwardenCipherModel(
            id: cipher.id,
            type: cipher.type,
            revisionDate: cipher.revisionDate,
            key: wrongWrapped,
            name: cipher.name,
            login: cipher.login
        )
        let detail = try XCTUnwrap(VaultwardenItemDecryptor.detail(
            for: tampered, keyring: keyring, account: account, generation: 1
        ))
        XCTAssertEqual(detail.title, "Unnamed item")
        XCTAssertNil(detail.fields.first { $0.label == "Password" })
    }

    func testUnwrapCipherKeyRejectsWrongWidths() throws {
        let narrow = try VaultwardenCipher.encryptToType2(Data(repeating: 1, count: 32), key: userKey)
        XCTAssertThrowsError(try VaultwardenKeyUnwrap.unwrapCipherKey(wrapped: narrow, accountKey: userKey)) { error in
            XCTAssertEqual(error as? VaultwardenCryptoError, .invalidKeyMaterial)
        }
        // A legacy unauthenticated wrapper is never opened either.
        XCTAssertThrowsError(try VaultwardenKeyUnwrap.unwrapCipherKey(wrapped: "0.abc|def", accountKey: userKey))
    }

    // MARK: - Draft gating

    func testDraftIsNilForEditForbiddenTrashedOrArchivedItems() throws {
        // `draft(for:)` is a pure function of keyring and snapshot, so the
        // default service exercises it without any store I/O.
        let service = VaultwardenAccountService()

        func cipher(edit: Bool?, deleted: Bool, archived: Bool) throws -> VaultwardenCipherModel {
            VaultwardenCipherModel(
                id: "c1",
                type: .login,
                revisionDate: Date(timeIntervalSince1970: 1_700_000_000),
                deletedDate: deleted ? Date() : nil,
                archivedDate: archived ? Date() : nil,
                edit: edit,
                name: try enc("GitHub"),
                login: .init(username: try enc("octocat"), password: try enc("pw"))
            )
        }
        let snapshot = VaultwardenVaultSnapshot(
            version: 1, serverBaseURL: "https://vault.example.com",
            identityBaseURL: "https://vault.example.com/identity",
            email: "user@example.com",
            kdf: .init(configuration: .pbkdf2SHA256(iterations: 600_000)),
            wrappedUserKey: "2.w|w|w", wrappedPrivateKey: nil,
            organizations: [], folders: [],
            ciphers: [
                try cipher(edit: false, deleted: false, archived: false),
            ],
            syncedAt: Date(), generation: 1
        )
        let itemID = VaultwardenItemDecryptor.itemID(for: snapshot.ciphers[0], account: account)
        XCTAssertNil(
            service.draft(for: itemID, keyring: keyring, snapshot: snapshot),
            "edit: false must refuse the draft in the use case, not only in the UI"
        )

        for (deleted, archived) in [(true, false), (false, true)] {
            let c = try cipher(edit: nil, deleted: deleted, archived: archived)
            let snap = VaultwardenVaultSnapshot(
                version: 1, serverBaseURL: "https://vault.example.com",
                identityBaseURL: "https://vault.example.com/identity",
                email: "user@example.com",
                kdf: .init(configuration: .pbkdf2SHA256(iterations: 600_000)),
                wrappedUserKey: "2.w|w|w", wrappedPrivateKey: nil,
                organizations: [], folders: [], ciphers: [c],
                syncedAt: Date(), generation: 1
            )
            XCTAssertNil(
                service.draft(for: VaultwardenItemDecryptor.itemID(for: c, account: account),
                              keyring: keyring, snapshot: snap)
            )
        }
    }
}
