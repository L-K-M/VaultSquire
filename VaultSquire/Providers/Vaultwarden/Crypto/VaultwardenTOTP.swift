import CryptoKit
import Foundation

/// RFC 6238 time-based one-time passwords, derived from a decrypted seed. The
/// seed is either an `otpauth://totp/...` URI (whose parameters override the
/// defaults) or a bare Base32 secret. Only Apple's CryptoKit HMAC is used, so
/// no dependency is added. The seed itself is never displayed or logged.
enum VaultwardenTOTP {
    struct Parameters: Sendable, Hashable {
        var secret: Data
        var digits: Int
        var period: Int
        var algorithm: Algorithm

        enum Algorithm: String, Sendable, Hashable {
            case sha1 = "SHA1"
            case sha256 = "SHA256"
            case sha512 = "SHA512"
        }
    }

    /// A generated code and the wall-clock instant its window ends, so the UI can
    /// show a countdown and refresh exactly when it rolls over.
    struct Generated: Sendable, Hashable {
        let code: String
        let periodEnd: Date
        let period: Int
    }

    /// Parses a seed and generates the code for `date`. Returns nil for an
    /// unparseable seed or secret.
    static func generate(seed: String, at date: Date) -> Generated? {
        guard var parameters = parse(seed: seed) else { return nil }
        defer { VaultwardenCryptoZeroize.zero(&parameters.secret) }
        let timestamp = date.timeIntervalSince1970
        guard timestamp.isFinite else { return nil }
        let counterValue = max(0, timestamp) / Double(parameters.period)
        // `Double(UInt64.max)` rounds up to 2^64, which is outside UInt64.
        // Strict comparison excludes that trapping conversion boundary.
        guard counterValue.isFinite, counterValue < Double(UInt64.max) else { return nil }
        let counter = UInt64(counterValue)
        guard let code = code(parameters: parameters, counter: counter) else { return nil }

        let windowStart = Double(counter) * Double(parameters.period)
        return Generated(
            code: code,
            periodEnd: Date(timeIntervalSince1970: windowStart + Double(parameters.period)),
            period: parameters.period
        )
    }

    static func parse(seed: String) -> Parameters? {
        // TOTP seeds are tiny. Bound hostile item content before URL parsing,
        // uppercasing, or output allocation.
        guard seed.utf8.count <= 8_192 else { return nil }
        let trimmed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("otpauth://") {
            return parseURI(trimmed)
        }
        guard let secret = base32Decode(trimmed) else { return nil }
        return Parameters(secret: secret, digits: 6, period: 30, algorithm: .sha1)
    }

    private static func parseURI(_ uri: String) -> Parameters? {
        guard let components = URLComponents(string: uri),
              components.scheme?.lowercased() == "otpauth",
              components.host?.lowercased() == "totp",
              components.user == nil,
              components.password == nil,
              components.fragment == nil else {
            return nil
        }
        let items = components.queryItems ?? []
        func uniqueValue(_ name: String) -> String?? {
            let matches = items.filter { $0.name.lowercased() == name }
            guard matches.count <= 1 else { return nil }
            return .some(matches.first?.value)
        }
        guard let secretField = uniqueValue("secret"),
              let secretString = secretField,
              let secret = base32Decode(secretString) else {
            return nil
        }

        let digits: Int
        guard let digitsField = uniqueValue("digits") else { return nil }
        if let rawDigits = digitsField {
            guard let parsed = Int(rawDigits) else { return nil }
            digits = parsed
        } else {
            digits = 6
        }

        let period: Int
        guard let periodField = uniqueValue("period") else { return nil }
        if let rawPeriod = periodField {
            guard let parsed = Int(rawPeriod) else { return nil }
            period = parsed
        } else {
            period = 30
        }

        let algorithm: Parameters.Algorithm
        guard let algorithmField = uniqueValue("algorithm") else { return nil }
        if let rawAlgorithm = algorithmField {
            guard let parsed = Parameters.Algorithm(rawValue: rawAlgorithm.uppercased()) else {
                return nil
            }
            algorithm = parsed
        } else {
            algorithm = .sha1
        }

        guard digits >= 6, digits <= 8, period >= 1, period <= 300 else { return nil }
        return Parameters(secret: secret, digits: digits, period: period, algorithm: algorithm)
    }

    private static func code(parameters: Parameters, counter: UInt64) -> String? {
        guard !parameters.secret.isEmpty else { return nil }
        var bigEndianCounter = counter.bigEndian
        let message = withUnsafeBytes(of: &bigEndianCounter) { Data($0) }
        let key = SymmetricKey(data: parameters.secret)

        let digest: Data
        switch parameters.algorithm {
        case .sha1:
            digest = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256:
            digest = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512:
            digest = Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }

        // RFC 4226 dynamic truncation.
        let offset = Int(digest[digest.count - 1] & 0x0F)
        let bytes = [UInt8](digest)
        let binary = (UInt32(bytes[offset] & 0x7F) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
        // Integer power: pow() on Double can land a hair below an exact power of
        // ten and truncate to the wrong modulus.
        let modulus = (0..<parameters.digits).reduce(UInt32(1)) { product, _ in product * 10 }
        let value = binary % modulus
        return String(format: "%0\(parameters.digits)u", value)
    }

    /// RFC 4648 Base32 decode, uppercasing and ignoring spaces and padding.
    static func base32Decode(_ input: String) -> Data? {
        guard input.utf8.count <= 8_192 else { return nil }
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        var lookup: [Character: UInt8] = [:]
        for (index, character) in alphabet.enumerated() {
            lookup[character] = UInt8(index)
        }

        let cleaned = input
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "=", with: "")
        guard !cleaned.isEmpty, cleaned.utf8.count <= 4_096 else { return nil }

        // Keep only the not-yet-emitted low bits. Retaining the complete bit
        // history and shifting it for every character overflows `Int` on an
        // ordinary 32-character TOTP secret and turns vault content into a
        // deterministic process crash.
        var bits = 0
        var accumulator: UInt32 = 0
        var output = [UInt8]()
        output.reserveCapacity(cleaned.utf8.count * 5 / 8)
        for character in cleaned {
            guard let value = lookup[character] else { return nil }
            accumulator = (accumulator << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((accumulator >> UInt32(bits)) & 0xFF))
                if bits == 0 {
                    accumulator = 0
                } else {
                    accumulator &= (UInt32(1) << UInt32(bits)) - 1
                }
            }
        }
        // Unpadded Base32 is accepted, but its unused trailing bits must be
        // zero. Reject encodings that cannot represent even one secret byte.
        guard !output.isEmpty, accumulator == 0 else { return nil }
        return Data(output)
    }
}
