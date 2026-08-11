import Foundation
import Security

enum VaultwardenKeyUnwrap {
    /// Unwraps the account's 64-byte user key from its type-2 wrapping under
    /// the 64-byte stretched master key. Legacy type-0 wrappers are detected
    /// here, for both recorded legacy key lengths, and refused without
    /// producing any plaintext; the account must migrate with a compatible
    /// client.
    static func unwrapUserKey(
        wrapped: String,
        stretchedMasterKey: Data
    ) throws -> VaultwardenSymmetricKey {
        let key = try VaultwardenSymmetricKey(keyData: stretchedMasterKey)
        let parsed = try VaultwardenEncString.parse(wrapped)
        let unwrapped = try VaultwardenCipher.decrypt(parsed, key: key)
        guard unwrapped.count == 64 else {
            throw VaultwardenCryptoError.invalidKeyMaterial
        }

        return try VaultwardenSymmetricKey(keyData: unwrapped)
    }

    /// Decrypts the user's PKCS#8 RSA private key from its type-2 wrapping
    /// under the user key.
    static func decryptPrivateKey(
        wrapped: String,
        userKey: VaultwardenSymmetricKey
    ) throws -> Data {
        let parsed = try VaultwardenEncString.parse(wrapped)
        return try VaultwardenCipher.decrypt(parsed, key: userKey)
    }

    /// Unwraps a per-item cipher key: a 64-byte symmetric key, type-2 wrapped
    /// under the account key for the cipher's scope (the user key for a
    /// personal cipher, the organization key for an organization cipher).
    /// Current official clients encrypt every new cipher's fields under such
    /// an item key instead of under the account key directly, so a cipher
    /// carrying `Key` is unreadable — and unsafe to edit — without this step.
    static func unwrapCipherKey(
        wrapped: String,
        accountKey: VaultwardenSymmetricKey
    ) throws -> VaultwardenSymmetricKey {
        let parsed = try VaultwardenEncString.parse(wrapped)
        let unwrapped = try VaultwardenCipher.decrypt(parsed, key: accountKey)
        guard unwrapped.count == 64 else {
            throw VaultwardenCryptoError.invalidKeyMaterial
        }
        return try VaultwardenSymmetricKey(keyData: unwrapped)
    }

    /// Unwraps a 64-byte organization key: RSA-2048 OAEP-SHA1 decapsulation
    /// of the wrapped key bytes through the user's private key (PKCS#8 DER).
    /// This is the recorded V1 sharing path.
    static func unwrapOrganizationKey(
        wrappedOrganizationKey: Data,
        privateKeyPKCS8: Data
    ) throws -> VaultwardenSymmetricKey {
        let pkcs1 = try rsaPrivateKeyDER(fromPKCS8: privateKeyPKCS8)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        var creationError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(
            pkcs1 as CFData,
            attributes as CFDictionary,
            &creationError
        ) else {
            creationError?.release()
            throw VaultwardenCryptoError.invalidKeyMaterial
        }
        guard SecKeyIsAlgorithmSupported(privateKey, .decrypt, .rsaEncryptionOAEPSHA1) else {
            throw VaultwardenCryptoError.invalidKeyMaterial
        }

        var decryptionError: Unmanaged<CFError>?
        guard let unwrapped = SecKeyCreateDecryptedData(
            privateKey,
            .rsaEncryptionOAEPSHA1,
            wrappedOrganizationKey as CFData,
            &decryptionError
        ) as Data? else {
            decryptionError?.release()
            throw VaultwardenCryptoError.integrityFailure
        }
        guard unwrapped.count == 64 else {
            throw VaultwardenCryptoError.integrityFailure
        }

        return try VaultwardenSymmetricKey(keyData: unwrapped)
    }

    /// Extracts the PKCS#1 RSAPrivateKey DER from a PKCS#8 PrivateKeyInfo
    /// envelope, because the Security framework expects the PKCS#1 form.
    /// This is strict format parsing of the fixed rsaEncryption envelope,
    /// not a cryptographic primitive.
    static func rsaPrivateKeyDER(fromPKCS8 der: Data) throws -> Data {
        var reader = DERReader(der)
        try reader.expectSequenceHeader()
        try reader.expectIntegerZero()
        try reader.expectRSAAlgorithmIdentifier()
        let inner = try reader.expectOctetString()
        return inner
    }
}

/// Minimal strict DER reader for exactly the PKCS#8 rsaEncryption envelope.
/// Definite lengths only; anything unexpected is rejected.
private struct DERReader {
    private let bytes: [UInt8]
    private var offset = 0

    // 1.2.840.113549.1.1.1 (rsaEncryption) with NULL parameters.
    private static let rsaAlgorithmIdentifier: [UInt8] = [
        0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86,
        0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00,
    ]

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    mutating func expectSequenceHeader() throws {
        guard try readByte() == 0x30 else {
            throw VaultwardenCryptoError.invalidKeyMaterial
        }
        let length = try readLength()
        guard offset + length == bytes.count else {
            throw VaultwardenCryptoError.invalidKeyMaterial
        }
    }

    mutating func expectIntegerZero() throws {
        guard try readByte() == 0x02,
              try readLength() == 1,
              try readByte() == 0x00 else {
            throw VaultwardenCryptoError.invalidKeyMaterial
        }
    }

    mutating func expectRSAAlgorithmIdentifier() throws {
        let expected = Self.rsaAlgorithmIdentifier
        guard offset + expected.count <= bytes.count,
              Array(bytes[offset..<offset + expected.count]) == expected else {
            throw VaultwardenCryptoError.invalidKeyMaterial
        }

        offset += expected.count
    }

    mutating func expectOctetString() throws -> Data {
        guard try readByte() == 0x04 else {
            throw VaultwardenCryptoError.invalidKeyMaterial
        }
        let length = try readLength()
        guard length > 0, offset + length <= bytes.count else {
            throw VaultwardenCryptoError.invalidKeyMaterial
        }

        let value = Data(bytes[offset..<offset + length])
        offset += length
        return value
    }

    private mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else {
            throw VaultwardenCryptoError.invalidKeyMaterial
        }

        let byte = bytes[offset]
        offset += 1
        return byte
    }

    private mutating func readLength() throws -> Int {
        let first = try readByte()
        if first < 0x80 {
            return Int(first)
        }

        let byteCount = Int(first & 0x7F)
        guard byteCount >= 1, byteCount <= 4 else {
            throw VaultwardenCryptoError.invalidKeyMaterial
        }

        var length = 0
        for _ in 0..<byteCount {
            length = (length << 8) | Int(try readByte())
        }
        // Long-form lengths below 0x80 are non-minimal encodings; reject.
        guard length >= 0x80 else {
            throw VaultwardenCryptoError.invalidKeyMaterial
        }

        return length
    }
}
