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
        let trimmed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bitwarden's own "steam://<base32 secret>" seed form, used for Steam
        // Guard codes: a fixed 30-second HMAC-SHA1 counter like standard TOTP,
        // but the truncated value picks five characters from Steam's own
        // alphabet instead of formatting six decimal digits. Handled as its
        // own path rather than through `parse`/`code`, whose output is
        // decimal-digits-shaped throughout.
        if trimmed.lowercased().hasPrefix("steam://") {
            return generateSteam(trimmed, at: date)
        }
        guard let parameters = parse(seed: seed) else { return nil }
        let counter = UInt64(max(0, date.timeIntervalSince1970) / Double(parameters.period))
        guard let code = code(parameters: parameters, counter: counter) else { return nil }

        let windowStart = Double(counter) * Double(parameters.period)
        return Generated(
            code: code,
            periodEnd: Date(timeIntervalSince1970: windowStart + Double(parameters.period)),
            period: parameters.period
        )
    }

    /// Steam Guard's alphabet: 26 characters chosen to avoid visually
    /// ambiguous ones (no 0/O/1/I, no vowels besides those excluded by the
    /// same reasoning). Codes are always 5 characters, always HMAC-SHA1,
    /// always a 30-second period — Steam's scheme has no equivalent of
    /// otpauth's digits/algorithm/period parameters to override.
    private static let steamAlphabet = Array("23456789BCDFGHJKMNPQRTVWXY")
    private static let steamPeriod = 30

    private static func generateSteam(_ seed: String, at date: Date) -> Generated? {
        let secretString = String(seed.dropFirst("steam://".count))
        guard let secret = base32Decode(secretString), !secret.isEmpty else { return nil }

        let counter = UInt64(max(0, date.timeIntervalSince1970) / Double(steamPeriod))
        var bigEndianCounter = counter.bigEndian
        let message = withUnsafeBytes(of: &bigEndianCounter) { Data($0) }
        let key = SymmetricKey(data: secret)
        let digest = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))

        // The same RFC 4226 dynamic truncation `code(parameters:counter:)`
        // uses, stopping at the 31-bit integer: Steam maps that integer to
        // its own alphabet instead of a decimal modulus.
        let offset = Int(digest[digest.count - 1] & 0x0F)
        let bytes = [UInt8](digest)
        var fullCode = (UInt32(bytes[offset] & 0x7F) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])

        var characters: [Character] = []
        for _ in 0..<5 {
            characters.append(steamAlphabet[Int(fullCode % UInt32(steamAlphabet.count))])
            fullCode /= UInt32(steamAlphabet.count)
        }

        let windowStart = Double(counter) * Double(steamPeriod)
        return Generated(
            code: String(characters),
            periodEnd: Date(timeIntervalSince1970: windowStart + Double(steamPeriod)),
            period: steamPeriod
        )
    }

    static func parse(seed: String) -> Parameters? {
        let trimmed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("otpauth://") {
            return parseURI(trimmed)
        }
        guard let secret = base32Decode(trimmed) else { return nil }
        return Parameters(secret: secret, digits: 6, period: 30, algorithm: .sha1)
    }

    private static func parseURI(_ uri: String) -> Parameters? {
        guard let components = URLComponents(string: uri) else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value
        }
        guard let secretString = value("secret"),
              let secret = base32Decode(secretString) else {
            return nil
        }
        let digits = value("digits").flatMap(Int.init) ?? 6
        let period = value("period").flatMap(Int.init) ?? 30
        let algorithm = value("algorithm")
            .flatMap { Parameters.Algorithm(rawValue: $0.uppercased()) } ?? .sha1
        guard digits >= 6, digits <= 8, period > 0 else { return nil }
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
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        var lookup: [Character: UInt8] = [:]
        for (index, character) in alphabet.enumerated() {
            lookup[character] = UInt8(index)
        }

        let cleaned = input
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "=", with: "")
        guard !cleaned.isEmpty else { return nil }

        var bits = 0
        var accumulator = 0
        var output = [UInt8]()
        for character in cleaned {
            guard let value = lookup[character] else { return nil }
            accumulator = (accumulator << 5) | Int(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((accumulator >> bits) & 0xFF))
            }
        }
        return Data(output)
    }
}
