import XCTest
@testable import VaultSquire

final class VaultwardenVaultUnlockTests: XCTestCase {
    private let account = AccountID(provider: .vaultwarden, rawValue: "VSQ-Canary-account")
    private let email = "vsq-canary@example.com"
    private let password = "VSQ-Canary-correct-horse"
    // At the reviewed floor so the round trip stays fast but exercises real PBKDF2.
    private let iterations = VaultwardenKDFConfiguration.pbkdf2IterationFloor

    /// Builds a snapshot whose wrapped user key and cipher fields are produced by
    /// the production encrypt path under the key the password derives, so unlock
    /// is exercised end to end against real ciphertext.
    private func makeSealedSnapshot(
        loginName: String = "GitHub",
        username: String = "octocat",
        secret: String = "VSQ-Canary-hunter2",
        useIndividualCipherKey: Bool = false,
        malformedCipherKey: Bool = false,
        viewPassword: Bool = true
    ) async throws -> VaultwardenVaultSnapshot {
        let masterKey = try await VaultwardenKeyDerivation.deriveMasterKey(
            passwordBytes: Data(password.utf8),
            email: email,
            configuration: .pbkdf2SHA256(iterations: iterations)
        )
        let stretched = try VaultwardenKeyDerivation.stretchMasterKey(masterKey)
        let stretchedKey = try VaultwardenSymmetricKey(keyData: stretched)

        let userKeyBytes = Data((0..<64).map { UInt8($0) })
        let userKey = try VaultwardenSymmetricKey(keyData: userKeyBytes)
        let wrappedUserKey = try VaultwardenCipher.encryptToType2(userKeyBytes, key: stretchedKey)

        let contentKey: VaultwardenSymmetricKey
        let wrappedCipherKey: String?
        if useIndividualCipherKey {
            let bytes = Data((64..<128).map { UInt8($0) })
            contentKey = try VaultwardenSymmetricKey(keyData: bytes)
            wrappedCipherKey = try VaultwardenCipher.encryptToType2(bytes, key: userKey)
        } else {
            contentKey = userKey
            wrappedCipherKey = malformedCipherKey ? "2.not-valid" : nil
        }

        func enc(_ text: String) throws -> String {
            try VaultwardenCipher.encryptToType2(Data(text.utf8), key: contentKey)
        }

        let cipher = VaultwardenCipherModel(
            id: "cipher-1",
            type: .login,
            revisionDate: Date(timeIntervalSince1970: 1_700_000_000),
            key: wrappedCipherKey,
            viewPassword: viewPassword,
            name: try enc(loginName),
            login: .init(
                username: try enc(username),
                password: try enc(secret),
                totp: nil,
                uris: [.init(uri: try enc("https://github.com"))]
            )
        )

        return VaultwardenVaultSnapshot(
            version: VaultwardenVaultSnapshot.currentVersion,
            serverBaseURL: "https://vault.example.com",
            identityBaseURL: "https://vault.example.com/identity",
            email: email,
            kdf: .init(configuration: .pbkdf2SHA256(iterations: iterations)),
            wrappedUserKey: wrappedUserKey,
            wrappedPrivateKey: nil,
            organizations: [],
            folders: [],
            ciphers: [cipher],
            syncedAt: Date(timeIntervalSince1970: 1_700_000_000),
            generation: 1
        )
    }

    func testCorrectPasswordUnlocksAndDecryptsItems() async throws {
        let snapshot = try await makeSealedSnapshot()
        let keyring = try await VaultwardenVaultUnlock.unlock(
            snapshot: snapshot, masterPasswordBytes: Data(password.utf8)
        )

        let cipher = snapshot.ciphers[0]
        let projection = VaultwardenItemDecryptor.projection(
            for: cipher, keyring: keyring, account: account, folderNames: [:], generation: snapshot.generation
        )
        XCTAssertEqual(projection.displayTitle, "GitHub")
        XCTAssertEqual(projection.username, "octocat")
        XCTAssertEqual(projection.websites, ["https://github.com"])
        XCTAssertEqual(projection.category, .login)
        XCTAssertEqual(projection.cacheReference.captureGeneration, SnapshotGeneration(rawValue: 1))

        let detail = VaultwardenItemDecryptor.detail(
            for: cipher, keyring: keyring, account: account, generation: snapshot.generation
        )
        let passwordField = try XCTUnwrap(detail.fields.first { $0.label == "Password" })
        XCTAssertEqual(passwordField.value, "VSQ-Canary-hunter2")
        XCTAssertTrue(passwordField.isConcealable)
    }

    func testIndividualCipherKeyIsResolvedBeforeDecryptingFields() async throws {
        let snapshot = try await makeSealedSnapshot(useIndividualCipherKey: true)
        let keyring = try await VaultwardenVaultUnlock.unlock(
            snapshot: snapshot, masterPasswordBytes: Data(password.utf8)
        )

        let projection = VaultwardenItemDecryptor.projection(
            for: snapshot.ciphers[0],
            keyring: keyring,
            account: account,
            folderNames: [:],
            generation: snapshot.generation
        )

        XCTAssertEqual(projection.displayTitle, "GitHub")
        XCTAssertEqual(projection.username, "octocat")
    }

    func testDeniedPasswordPermissionConcealsSecretFieldsAndCapabilities() async throws {
        let snapshot = try await makeSealedSnapshot(viewPassword: false)
        let keyring = try await VaultwardenVaultUnlock.unlock(
            snapshot: snapshot, masterPasswordBytes: Data(password.utf8)
        )
        let cipher = snapshot.ciphers[0]

        let projection = VaultwardenItemDecryptor.projection(
            for: cipher,
            keyring: keyring,
            account: account,
            folderNames: [:],
            generation: snapshot.generation
        )
        let detail = VaultwardenItemDecryptor.detail(
            for: cipher,
            keyring: keyring,
            account: account,
            generation: snapshot.generation
        )

        XCTAssertFalse(projection.capabilities.contains(.revealSecret))
        XCTAssertFalse(projection.capabilities.contains(.copySecret))
        XCTAssertNil(detail.fields.first { $0.label == "Password" })
    }

    func testMalformedPresentCipherKeyNeverFallsBackToOwnerKey() async throws {
        let snapshot = try await makeSealedSnapshot(malformedCipherKey: true)
        let keyring = try await VaultwardenVaultUnlock.unlock(
            snapshot: snapshot, masterPasswordBytes: Data(password.utf8)
        )

        let projection = VaultwardenItemDecryptor.projection(
            for: snapshot.ciphers[0],
            keyring: keyring,
            account: account,
            folderNames: [:],
            generation: snapshot.generation
        )

        XCTAssertEqual(projection.displayTitle, "Unreadable item")
        XCTAssertNil(projection.username)
    }

    func testWrongPasswordFailsClosed() async throws {
        let snapshot = try await makeSealedSnapshot()
        do {
            _ = try await VaultwardenVaultUnlock.unlock(
                snapshot: snapshot, masterPasswordBytes: Data("VSQ-Canary-wrong".utf8)
            )
            XCTFail("a wrong password must not unlock")
        } catch {
            XCTAssertEqual(error as? VaultwardenUnlockError, .wrongPassword)
        }
    }

    func testArgon2idAccountFailsClosedAsUnsupported() async throws {
        var snapshot = try await makeSealedSnapshot()
        snapshot.kdf = .init(configuration: .argon2id(iterations: 3, memoryMiB: 64, parallelism: 4))
        do {
            _ = try await VaultwardenVaultUnlock.unlock(
                snapshot: snapshot, masterPasswordBytes: Data(password.utf8)
            )
            XCTFail("Argon2id must fail closed")
        } catch {
            XCTAssertEqual(error as? VaultwardenUnlockError, .unsupportedKDF)
        }
    }
}
