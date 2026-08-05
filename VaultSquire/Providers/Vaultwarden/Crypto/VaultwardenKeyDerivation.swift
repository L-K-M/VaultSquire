import CommonCrypto
import CryptoKit
import Foundation

/// Server-selected KDF configuration. Prelogin values are untrusted network
/// data: a hostile server can hand out cheap parameters to make offline
/// attack easy or huge ones to exhaust the client, so both a reviewed floor
/// and a ceiling are enforced before any allocation.
enum VaultwardenKDFConfiguration: Hashable, Sendable {
    case pbkdf2SHA256(iterations: Int)
    case argon2id(iterations: Int, memoryMiB: Int, parallelism: Int)

    static let pbkdf2IterationFloor = 5_000
    static let pbkdf2IterationCeiling = 2_000_000
    static let argon2IterationFloor = 2
    static let argon2IterationCeiling = 10
    static let argon2MemoryFloorMiB = 16
    static let argon2MemoryCeilingMiB = 1_024
    static let argon2ParallelismFloor = 1
    static let argon2ParallelismCeiling = 16

    /// Validates algorithm parameters, ranges, and arithmetic before any
    /// memory is allocated or work begins. Uses non-trapping arithmetic so
    /// hostile values are reported as errors, never as a crash.
    func validate() throws {
        switch self {
        case .pbkdf2SHA256(let iterations):
            guard iterations >= Self.pbkdf2IterationFloor else {
                throw VaultwardenCryptoError.invalidKDFParameters(.iterationsBelowFloor)
            }
            guard iterations <= Self.pbkdf2IterationCeiling else {
                throw VaultwardenCryptoError.invalidKDFParameters(.iterationsAboveCeiling)
            }
        case .argon2id(let iterations, let memoryMiB, let parallelism):
            guard iterations >= Self.argon2IterationFloor else {
                throw VaultwardenCryptoError.invalidKDFParameters(.iterationsBelowFloor)
            }
            guard iterations <= Self.argon2IterationCeiling else {
                throw VaultwardenCryptoError.invalidKDFParameters(.iterationsAboveCeiling)
            }
            guard memoryMiB >= Self.argon2MemoryFloorMiB else {
                throw VaultwardenCryptoError.invalidKDFParameters(.memoryBelowFloor)
            }
            guard memoryMiB <= Self.argon2MemoryCeilingMiB else {
                throw VaultwardenCryptoError.invalidKDFParameters(.memoryAboveCeiling)
            }
            guard parallelism >= Self.argon2ParallelismFloor else {
                throw VaultwardenCryptoError.invalidKDFParameters(.parallelismBelowFloor)
            }
            guard parallelism <= Self.argon2ParallelismCeiling else {
                throw VaultwardenCryptoError.invalidKDFParameters(.parallelismAboveCeiling)
            }
            // Prelogin memory arrives in MiB and Argon2 consumes KiB; the
            // conversion is checked so an extreme value cannot overflow.
            let (memoryKiB, overflow) = memoryMiB.multipliedReportingOverflow(by: 1_024)
            guard !overflow, memoryKiB > 0 else {
                throw VaultwardenCryptoError.invalidKDFParameters(.arithmeticOverflow)
            }
        }
    }
}

enum VaultwardenKeyDerivation {
    /// The only input the protocol normalizes. A master password is never
    /// trimmed, normalized, or case-folded.
    static func normalizedEmail(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Derives the 32-byte master key from the exact master-password bytes
    /// and the normalized email. PBKDF2-HMAC-SHA256 uses the normalized email
    /// bytes as the salt. Argon2id fails closed: no reviewed implementation
    /// is adopted, ciphertext stays preserved, and nothing weaker is
    /// substituted. Cancellation is checked before and after the derivation;
    /// the underlying primitive is not interruptible mid-run, so the caller's
    /// generation check remains the invariant for discarding late results.
    static func deriveMasterKey(
        passwordBytes: Data,
        email: String,
        configuration: VaultwardenKDFConfiguration
    ) async throws -> Data {
        try configuration.validate()
        guard !passwordBytes.isEmpty else {
            throw VaultwardenCryptoError.invalidKeyMaterial
        }

        switch configuration {
        case .pbkdf2SHA256(let iterations):
            try Task.checkCancellation()
            let salt = Data(normalizedEmail(email).utf8)
            let derived = try pbkdf2SHA256(
                password: passwordBytes,
                salt: salt,
                iterations: iterations,
                outputLength: 32
            )
            try Task.checkCancellation()
            return derived
        case .argon2id:
            throw VaultwardenCryptoError.argon2idUnavailable
        }
    }

    /// The server-authentication hash: PBKDF2-HMAC-SHA256 with the 32-byte
    /// master key as the password input, the raw master-password bytes as the
    /// salt, exactly one iteration, Base64-encoded. This is what the token
    /// grant carries; the master password itself is never sent.
    static func authenticationHash(
        masterKey: Data,
        passwordBytes: Data
    ) throws -> String {
        guard masterKey.count == 32, !passwordBytes.isEmpty else {
            throw VaultwardenCryptoError.invalidKeyMaterial
        }

        var digest = try pbkdf2SHA256(
            password: masterKey,
            salt: passwordBytes,
            iterations: 1,
            outputLength: 32
        )
        let encoded = digest.base64EncodedString()
        // `digest` is a freshly allocated buffer this function solely owns, so
        // zeroizing it here shortens the lifetime of derived key material
        // without touching anything the caller still holds.
        VaultwardenCryptoZeroize.zero(&digest)
        return encoded
    }

    /// Stretches the 32-byte master key to 64 bytes with HKDF-SHA256 Expand
    /// ONLY (RFC 5869 section 2.3): the master key is the PRK directly, with
    /// no extract step and no salt. Running extract first derives different
    /// bytes and every user-key unwrap fails. The result is the expansion
    /// with info "enc" followed by the expansion with info "mac".
    static func stretchMasterKey(_ masterKey: Data) throws -> Data {
        guard masterKey.count == 32 else {
            throw VaultwardenCryptoError.invalidKeyMaterial
        }

        let prk = SymmetricKey(data: masterKey)
        let encHalf = HKDF<SHA256>.expand(
            pseudoRandomKey: prk,
            info: Data("enc".utf8),
            outputByteCount: 32
        )
        let macHalf = HKDF<SHA256>.expand(
            pseudoRandomKey: prk,
            info: Data("mac".utf8),
            outputByteCount: 32
        )

        var stretched = Data(capacity: 64)
        encHalf.withUnsafeBytes { stretched.append(contentsOf: $0) }
        macHalf.withUnsafeBytes { stretched.append(contentsOf: $0) }
        return stretched
    }

    private static func pbkdf2SHA256(
        password: Data,
        salt: Data,
        iterations: Int,
        outputLength: Int
    ) throws -> Data {
        var derived = Data(count: outputLength)
        let status = derived.withUnsafeMutableBytes { derivedBuffer in
            password.withUnsafeBytes { passwordBuffer in
                salt.withUnsafeBytes { saltBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        outputLength
                    )
                }
            }
        }
        // CCKeyDerivationPBKDF returns Int32; kCCSuccess imports as Int.
        guard status == Int32(kCCSuccess) else {
            throw VaultwardenCryptoError.invalidKeyMaterial
        }

        return derived
    }
}
