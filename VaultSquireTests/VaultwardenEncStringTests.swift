import XCTest
@testable import VaultSquire

final class VaultwardenEncStringTests: XCTestCase {
    private var userKey: VaultwardenSymmetricKey {
        get throws {
            try VaultwardenSymmetricKey(
                keyData: Data(hexFixture: VaultwardenCryptoFixtures.userKeyHex)!
            )
        }
    }

    /// A `Data` slice inherits its parent's indices, so a composite key split
    /// with a bare `suffix(32)` hands out a MAC key that traps on `[0]`. Both
    /// halves must be addressable from zero and must still carry the right
    /// bytes.
    func testCompositeKeyHalvesAreZeroBasedAndCarryTheCorrectBytes() throws {
        let keyData = Data(hexFixture: VaultwardenCryptoFixtures.userKeyHex)!

        let key = try VaultwardenSymmetricKey(keyData: keyData)

        XCTAssertEqual(key.encryptionKey.startIndex, 0)
        XCTAssertEqual(key.macKey.startIndex, 0)
        XCTAssertEqual(key.encryptionKey.count, 32)
        XCTAssertEqual(key.macKey.count, 32)
        XCTAssertEqual(key.encryptionKey[0], keyData[0])
        XCTAssertEqual(key.macKey[0], keyData[32])
        XCTAssertEqual(key.macKey[31], keyData[63])
    }

    func testCompositeKeyRejectsEveryLengthButSixtyFour() {
        for count in [0, 32, 63, 65, 128] {
            XCTAssertThrowsError(
                try VaultwardenSymmetricKey(keyData: Data(count: count)),
                "\(count)"
            ) { error in
                XCTAssertEqual(
                    error as? VaultwardenCryptoError,
                    .invalidKeyMaterial,
                    "\(count)"
                )
            }
        }
    }

    // CRYPTO-01: exact plaintext and serialization round trip.
    func testType2KnownAnswerDecryptsAndReserializes() throws {
        let parsed = try VaultwardenEncString.parse(
            VaultwardenCryptoFixtures.itemEncString
        )

        let plaintext = try VaultwardenCipher.decrypt(parsed, key: try userKey)

        XCTAssertEqual(
            String(decoding: plaintext, as: UTF8.self),
            VaultwardenCryptoFixtures.itemPlaintext
        )
        XCTAssertEqual(
            parsed.serializedString,
            VaultwardenCryptoFixtures.itemEncString
        )
    }

    func testEncryptDecryptRoundTripWithFreshIV() throws {
        let plaintext = Data("VSQ-Canary-round-trip-plaintext".utf8)

        let first = try VaultwardenCipher.encryptToType2(plaintext, key: try userKey)
        let second = try VaultwardenCipher.encryptToType2(plaintext, key: try userKey)

        XCTAssertNotEqual(first, second, "IVs must be fresh per encryption")
        for serialized in [first, second] {
            let parsed = try VaultwardenEncString.parse(serialized)
            XCTAssertEqual(try VaultwardenCipher.decrypt(parsed, key: try userKey), plaintext)
        }
    }

    // CRYPTO-02: flipped IV, ciphertext, and MAC bits all fail with the one
    // generic error, indistinguishable from each other and from padding
    // damage.
    func testBitFlipsFailWithOneGenericError() throws {
        let serialized = VaultwardenCryptoFixtures.itemEncString
        guard case .aesCbc256HmacSha256(let iv, let ciphertext, let mac) =
            try VaultwardenEncString.parse(serialized) else {
            return XCTFail("fixture must parse as type 2")
        }

        var flippedIV = iv
        flippedIV[5] ^= 0x40
        var flippedCiphertext = ciphertext
        flippedCiphertext[ciphertext.count / 2] ^= 0x01
        var flippedMac = mac
        flippedMac[31] ^= 0x80

        let damaged: [VaultwardenEncString] = [
            .aesCbc256HmacSha256(iv: flippedIV, ciphertext: ciphertext, mac: mac),
            .aesCbc256HmacSha256(iv: iv, ciphertext: flippedCiphertext, mac: mac),
            .aesCbc256HmacSha256(iv: iv, ciphertext: ciphertext, mac: flippedMac),
        ]
        for encString in damaged {
            XCTAssertThrowsError(
                try VaultwardenCipher.decrypt(encString, key: try userKey)
            ) { error in
                XCTAssertEqual(
                    error as? VaultwardenCryptoError,
                    .integrityFailure
                )
            }
        }
    }

    func testWrongKeyFailsWithTheSameGenericError() throws {
        let parsed = try VaultwardenEncString.parse(
            VaultwardenCryptoFixtures.itemEncString
        )
        let wrongKey = try VaultwardenSymmetricKey(
            keyData: Data(hexFixture: VaultwardenCryptoFixtures.orgKeyHex)!
        )

        XCTAssertThrowsError(
            try VaultwardenCipher.decrypt(parsed, key: wrongKey)
        ) { error in
            XCTAssertEqual(error as? VaultwardenCryptoError, .integrityFailure)
        }
    }

    func testStructurallyMalformedType2FailsGenerically() {
        let malformed = [
            "2.only-one-part",
            "2.QQ==|QQ==",
            "2.QQ==|QQ==|QQ==|QQ==",
            "2.%%%|QQ==|QQ==",
            "2.QQ==|%%%|QQ==",
            "2.QQ==|QQ==|%%%",
            // IV wrong length (8 bytes).
            "2.QUFBQUFBQUE=|QUFBQUFBQUFBQUFBQUFBQQ==|"
                + "QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE=",
            // Empty ciphertext.
            "2.QUFBQUFBQUFBQUFBQUFBQQ==||"
                + "QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE=",
        ]
        for serialized in malformed {
            XCTAssertThrowsError(
                try VaultwardenEncString.parse(serialized),
                serialized
            ) { error in
                XCTAssertEqual(
                    error as? VaultwardenCryptoError,
                    .integrityFailure,
                    serialized
                )
            }
        }
    }

    // CRYPTO-05: unknown encryption types are rejected without a near-miss
    // fallback and the caller retains the original string.
    func testUnknownTypesAreRejectedWithoutFallback() {
        let unsupported = [
            "7.QQ==",
            "9.QQ==|QQ==|QQ==",
            "99.QQ==",
            "x.QQ==",
            "-1.QQ==",
            "QQ==",
            ".QQ==",
        ]
        for serialized in unsupported {
            XCTAssertThrowsError(
                try VaultwardenEncString.parse(serialized),
                serialized
            ) { error in
                XCTAssertEqual(
                    error as? VaultwardenCryptoError,
                    .unsupportedEncryptionType,
                    serialized
                )
            }
        }
    }

    func testLegacyType0IsDetectedNotDecrypted() throws {
        let parsed = try VaultwardenEncString.parse(
            VaultwardenCryptoFixtures.legacyType0UserKey32
        )

        guard case .legacyUnauthenticated(let raw) = parsed else {
            return XCTFail("type 0 must parse as legacy")
        }
        XCTAssertEqual(raw, VaultwardenCryptoFixtures.legacyType0UserKey32)
        XCTAssertNil(parsed.serializedString)
        XCTAssertThrowsError(
            try VaultwardenCipher.decrypt(parsed, key: try userKey)
        ) { error in
            XCTAssertEqual(
                error as? VaultwardenCryptoError,
                .legacyEncryptionDetected
            )
        }
    }

    func testAsymmetricTypesParseReadOnly() throws {
        for type in 3...6 {
            let parsed = try VaultwardenEncString.parse("\(type).QUJD")
            guard case .asymmetric(let parsedType, let payload) = parsed else {
                return XCTFail("type \(type) must parse as asymmetric")
            }
            XCTAssertEqual(parsedType, type)
            XCTAssertEqual(payload, Data("ABC".utf8))
            XCTAssertNil(parsed.serializedString)
            XCTAssertThrowsError(
                try VaultwardenCipher.decrypt(parsed, key: try userKey)
            ) { error in
                XCTAssertEqual(
                    error as? VaultwardenCryptoError,
                    .unsupportedEncryptionType
                )
            }
        }
    }
}
