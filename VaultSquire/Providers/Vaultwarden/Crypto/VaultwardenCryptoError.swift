import Foundation

/// Reasons a KDF configuration is rejected before any derivation work. These
/// are pre-derivation configuration diagnostics, not decryption outcomes, so
/// they may be specific without forming an oracle.
enum VaultwardenKDFParameterIssue: String, Hashable, Sendable {
    case unknownAlgorithm
    case iterationsBelowFloor
    case iterationsAboveCeiling
    case memoryBelowFloor
    case memoryAboveCeiling
    case parallelismBelowFloor
    case parallelismAboveCeiling
    case arithmeticOverflow
}

enum VaultwardenCryptoError: Error, Equatable, Sendable {
    /// The single generic failure for every MAC, padding, tag, malformed
    /// ciphertext, or failed decryption condition. Distinguishing them would
    /// hand an attacker a CBC oracle, so there is exactly one case.
    case integrityFailure
    /// Legacy unauthenticated type-0 material was detected. The ciphertext is
    /// retained by the caller and the account must be migrated with a
    /// compatible client; no legacy plaintext is ever returned.
    case legacyEncryptionDetected
    /// The encryption type is unknown or unsupported. The caller retains the
    /// original ciphertext unchanged; no near-miss algorithm is attempted.
    case unsupportedEncryptionType
    /// Argon2id is required by the account but no reviewed implementation is
    /// adopted. The account's ciphertext is preserved and derivation refuses;
    /// PBKDF2 or weaker parameters are never substituted.
    case argon2idUnavailable
    case invalidKDFParameters(VaultwardenKDFParameterIssue)
    /// Key material handed to the module has the wrong size or structure.
    /// This is a caller contract violation, not an attacker-observable
    /// decryption outcome.
    case invalidKeyMaterial
}

enum VaultwardenCryptoZeroize {
    /// Best-effort zeroization: Swift, Foundation, bridging, and
    /// copy-on-write can retain copies, so this reduces exposure rather than
    /// guaranteeing erasure.
    static func zero(_ data: inout Data) {
        data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }

            memset_s(baseAddress, buffer.count, 0, buffer.count)
        }
    }
}
