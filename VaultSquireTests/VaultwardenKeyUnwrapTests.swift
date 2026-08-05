import XCTest
@testable import VaultSquire

final class VaultwardenKeyUnwrapTests: XCTestCase {
    private var stretchedMasterKey: Data {
        Data(hexFixture: VaultwardenCryptoFixtures.stretchedMasterKeyHex)!
    }

    func testUserKeyUnwrapKnownAnswer() throws {
        let userKey = try VaultwardenKeyUnwrap.unwrapUserKey(
            wrapped: VaultwardenCryptoFixtures.wrappedUserKey,
            stretchedMasterKey: stretchedMasterKey
        )

        let expected = Data(hexFixture: VaultwardenCryptoFixtures.userKeyHex)!
        XCTAssertEqual(userKey.encryptionKey, expected.prefix(32))
        XCTAssertEqual(userKey.macKey, expected.suffix(32))
    }

    func testUserKeyUnwrapWithWrongKeyFailsGenerically() {
        var wrongKey = stretchedMasterKey
        wrongKey[0] ^= 0xFF

        XCTAssertThrowsError(
            try VaultwardenKeyUnwrap.unwrapUserKey(
                wrapped: VaultwardenCryptoFixtures.wrappedUserKey,
                stretchedMasterKey: wrongKey
            )
        ) { error in
            XCTAssertEqual(error as? VaultwardenCryptoError, .integrityFailure)
        }
    }

    // CRYPTO-03: legacy type-0 user-key wrappers with both recorded key
    // lengths are detected, retained, and produce no plaintext.
    func testLegacyType0UserKeysAreDetectedForBothLengths() {
        let wrappers = [
            VaultwardenCryptoFixtures.legacyType0UserKey32,
            VaultwardenCryptoFixtures.legacyType0UserKey64,
        ]
        for wrapped in wrappers {
            XCTAssertThrowsError(
                try VaultwardenKeyUnwrap.unwrapUserKey(
                    wrapped: wrapped,
                    stretchedMasterKey: stretchedMasterKey
                ),
                wrapped
            ) { error in
                XCTAssertEqual(
                    error as? VaultwardenCryptoError,
                    .legacyEncryptionDetected,
                    wrapped
                )
            }
        }
    }

    // CRYPTO-04: RSA-2048 OAEP-SHA1 organization key unwrap, proven by the
    // organization cipher decrypting.
    func testOrganizationKeyUnwrapDecryptsOrganizationCipher() throws {
        let organizationKey = try VaultwardenKeyUnwrap.unwrapOrganizationKey(
            wrappedOrganizationKey: Data(
                hexFixture: VaultwardenCryptoFixtures.wrappedOrgKeyHex
            )!,
            privateKeyPKCS8: Data(
                hexFixture: VaultwardenCryptoFixtures.rsaPrivateKeyPkcs8Hex
            )!
        )

        let expected = Data(hexFixture: VaultwardenCryptoFixtures.orgKeyHex)!
        XCTAssertEqual(organizationKey.encryptionKey, expected.prefix(32))

        let parsed = try VaultwardenEncString.parse(
            VaultwardenCryptoFixtures.orgItemEncString
        )
        let plaintext = try VaultwardenCipher.decrypt(parsed, key: organizationKey)
        XCTAssertEqual(
            String(decoding: plaintext, as: UTF8.self),
            "VSQ-Canary-org-item-plaintext"
        )
    }

    func testCorruptedOrganizationKeyCiphertextFailsGenerically() {
        var corrupted = Data(hexFixture: VaultwardenCryptoFixtures.wrappedOrgKeyHex)!
        corrupted[10] ^= 0x01

        XCTAssertThrowsError(
            try VaultwardenKeyUnwrap.unwrapOrganizationKey(
                wrappedOrganizationKey: corrupted,
                privateKeyPKCS8: Data(
                    hexFixture: VaultwardenCryptoFixtures.rsaPrivateKeyPkcs8Hex
                )!
            )
        ) { error in
            XCTAssertEqual(error as? VaultwardenCryptoError, .integrityFailure)
        }
    }

    func testMalformedPKCS8EnvelopeIsRejected() {
        let malformed: [Data] = [
            Data(),
            Data([0x30, 0x03, 0x02, 0x01, 0x00]),
            Data(hexFixture: VaultwardenCryptoFixtures.rsaPublicKeySpkiHex)!,
        ]
        for der in malformed {
            XCTAssertThrowsError(
                try VaultwardenKeyUnwrap.rsaPrivateKeyDER(fromPKCS8: der)
            ) { error in
                XCTAssertEqual(
                    error as? VaultwardenCryptoError,
                    .invalidKeyMaterial
                )
            }
        }
    }

    func testPrivateKeyDecryptsFromType2Wrapping() throws {
        let userKey = try VaultwardenSymmetricKey(
            keyData: Data(hexFixture: VaultwardenCryptoFixtures.userKeyHex)!
        )
        let privateKeyDER = Data(
            hexFixture: VaultwardenCryptoFixtures.rsaPrivateKeyPkcs8Hex
        )!
        let wrapped = try VaultwardenCipher.encryptToType2(
            privateKeyDER,
            key: userKey
        )

        let decrypted = try VaultwardenKeyUnwrap.decryptPrivateKey(
            wrapped: wrapped,
            userKey: userKey
        )

        XCTAssertEqual(decrypted, privateKeyDER)
        XCTAssertNoThrow(
            try VaultwardenKeyUnwrap.rsaPrivateKeyDER(fromPKCS8: decrypted)
        )
    }
}
