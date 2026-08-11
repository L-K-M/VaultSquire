import CommonCrypto
import CryptoKit
import Foundation
import Security

/// A 64-byte AES-256-CBC-HMAC composite key: encryption key is the first
/// 32 bytes, MAC key is the last 32 bytes.
struct VaultwardenSymmetricKey: Sendable {
    let encryptionKey: Data
    let macKey: Data

    init(keyData: Data) throws {
        guard keyData.count == 64 else {
            throw VaultwardenCryptoError.invalidKeyMaterial
        }

        // Each half is copied into its own zero-based buffer instead of being
        // kept as a slice of `keyData`. A `Data` slice inherits the parent's
        // indices, so `keyData.suffix(32)` would produce a MAC key whose
        // `startIndex` is 32 and whose `macKey[0]` traps at runtime. Every
        // current caller passes the halves whole, which is why that has not
        // bitten yet; the copy stops it from ever doing so.
        encryptionKey = Data(keyData.prefix(32))
        macKey = Data(keyData.suffix(32))
    }
}

/// Parsed protocol cipher string. Only the authenticated type-2 form is ever
/// decrypted or emitted. Legacy type 0 is detected and refused; asymmetric
/// types 3 through 6 parse read-only for existing shared material; anything
/// else fails closed while the caller retains the original string.
enum VaultwardenEncString: Hashable, Sendable {
    /// Bounds untrusted strings before Base64 creates additional allocations.
    /// Vault item fields are far smaller in practice; this leaves room for a
    /// large secure note while preventing one field from multiplying a whole
    /// sync response into unbounded transient memory.
    static let maximumSerializedBytes = 16 * 1024 * 1024
    static let maximumPlaintextBytes = 8 * 1024 * 1024
    static let maximumAsymmetricPayloadBytes = 64 * 1024
    /// Type 2: AES-256-CBC ciphertext authenticated by HMAC-SHA256 over
    /// IV || ciphertext.
    case aesCbc256HmacSha256(iv: Data, ciphertext: Data, mac: Data)
    /// Type 0: legacy unauthenticated AES-CBC. Never decrypted; the raw
    /// serialization is retained for migration.
    case legacyUnauthenticated(raw: String)
    /// Types 3-6: asymmetric single-part payloads accepted read-only.
    case asymmetric(type: Int, payload: Data)

    static func parse(_ serialized: String) throws -> VaultwardenEncString {
        guard serialized.utf8.count <= maximumSerializedBytes,
              let dotIndex = serialized.firstIndex(of: "."),
              dotIndex != serialized.startIndex else {
            throw VaultwardenCryptoError.unsupportedEncryptionType
        }

        let typePart = serialized[serialized.startIndex..<dotIndex]
        guard typePart.allSatisfy(\.isNumber),
              typePart.count <= 3,
              let type = Int(typePart) else {
            throw VaultwardenCryptoError.unsupportedEncryptionType
        }

        let body = String(serialized[serialized.index(after: dotIndex)...])
        switch type {
        case 0:
            return .legacyUnauthenticated(raw: serialized)
        case 2:
            let parts = body.components(separatedBy: "|")
            guard parts.count == 3,
                  let iv = Data(base64Encoded: parts[0]),
                  let ciphertext = Data(base64Encoded: parts[1]),
                  let mac = Data(base64Encoded: parts[2]),
                  iv.count == 16,
                  mac.count == 32,
                  !ciphertext.isEmpty,
                  ciphertext.count <= maximumSerializedBytes,
                  ciphertext.count % 16 == 0 else {
                throw VaultwardenCryptoError.integrityFailure
            }

            return .aesCbc256HmacSha256(iv: iv, ciphertext: ciphertext, mac: mac)
        case 3, 4, 5, 6:
            guard !body.isEmpty,
                  body.utf8.count <= ((maximumAsymmetricPayloadBytes + 2) / 3) * 4,
                  !body.contains("|"),
                  let payload = Data(base64Encoded: body),
                  !payload.isEmpty,
                  payload.count <= maximumAsymmetricPayloadBytes else {
                throw VaultwardenCryptoError.integrityFailure
            }

            return .asymmetric(type: type, payload: payload)
        default:
            throw VaultwardenCryptoError.unsupportedEncryptionType
        }
    }

    /// The canonical serialization of a parsed type-2 string:
    /// `2.<base64 iv>|<base64 ciphertext>|<base64 mac>`. Other forms return
    /// nil because they are never re-emitted.
    var serializedString: String? {
        switch self {
        case .aesCbc256HmacSha256(let iv, let ciphertext, let mac):
            return "2.\(iv.base64EncodedString())|\(ciphertext.base64EncodedString())|\(mac.base64EncodedString())"
        case .legacyUnauthenticated, .asymmetric:
            return nil
        }
    }
}

enum VaultwardenCipher {
    /// Decrypts an authenticated type-2 string. The MAC over IV || ciphertext
    /// is verified in constant time BEFORE any CBC decryption, and every
    /// verification or padding failure surfaces as the same generic error.
    static func decrypt(
        _ encString: VaultwardenEncString,
        key: VaultwardenSymmetricKey
    ) throws -> Data {
        switch encString {
        case .aesCbc256HmacSha256(let iv, let ciphertext, let mac):
            var authenticated = Data(capacity: iv.count + ciphertext.count)
            authenticated.append(iv)
            authenticated.append(ciphertext)
            let macKey = SymmetricKey(data: key.macKey)
            guard HMAC<SHA256>.isValidAuthenticationCode(
                mac,
                authenticating: authenticated,
                using: macKey
            ) else {
                throw VaultwardenCryptoError.integrityFailure
            }

            return try aesCbc(
                operation: CCOperation(kCCDecrypt),
                key: key.encryptionKey,
                iv: iv,
                input: ciphertext
            )
        case .legacyUnauthenticated:
            throw VaultwardenCryptoError.legacyEncryptionDetected
        case .asymmetric:
            throw VaultwardenCryptoError.unsupportedEncryptionType
        }
    }

    /// Encrypts plaintext into the canonical type-2 serialization with a
    /// fresh CSPRNG IV. This is the only form VaultSquire ever emits.
    static func encryptToType2(
        _ plaintext: Data,
        key: VaultwardenSymmetricKey
    ) throws -> String {
        guard plaintext.count <= VaultwardenEncString.maximumPlaintextBytes else {
            throw VaultwardenCryptoError.invalidKeyMaterial
        }
        var iv = Data(count: 16)
        let randomStatus = iv.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 16, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw VaultwardenCryptoError.invalidKeyMaterial
        }

        let ciphertext = try aesCbc(
            operation: CCOperation(kCCEncrypt),
            key: key.encryptionKey,
            iv: iv,
            input: plaintext
        )

        var authenticated = Data(capacity: iv.count + ciphertext.count)
        authenticated.append(iv)
        authenticated.append(ciphertext)
        let mac = HMAC<SHA256>.authenticationCode(
            for: authenticated,
            using: SymmetricKey(data: key.macKey)
        )

        let parsed = VaultwardenEncString.aesCbc256HmacSha256(
            iv: iv,
            ciphertext: ciphertext,
            mac: Data(mac)
        )
        guard let serialized = parsed.serializedString else {
            throw VaultwardenCryptoError.invalidKeyMaterial
        }

        return serialized
    }

    private static func aesCbc(
        operation: CCOperation,
        key: Data,
        iv: Data,
        input: Data
    ) throws -> Data {
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else {
            throw VaultwardenCryptoError.invalidKeyMaterial
        }

        var output = Data(count: input.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var movedBytes = 0
        let status = output.withUnsafeMutableBytes { outputBuffer in
            key.withUnsafeBytes { keyBuffer in
                iv.withUnsafeBytes { ivBuffer in
                    input.withUnsafeBytes { inputBuffer in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuffer.baseAddress,
                            kCCKeySizeAES256,
                            ivBuffer.baseAddress,
                            inputBuffer.baseAddress,
                            input.count,
                            outputBuffer.baseAddress,
                            outputCapacity,
                            &movedBytes
                        )
                    }
                }
            }
        }
        // CCCrypt returns CCCryptorStatus (Int32); kCCSuccess imports as Int.
        guard status == Int32(kCCSuccess), movedBytes >= 0, movedBytes <= output.count else {
            VaultwardenCryptoZeroize.zero(&output)
            throw VaultwardenCryptoError.integrityFailure
        }

        output.count = movedBytes
        return output
    }
}
