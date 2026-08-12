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

    /// The largest seed this will look at.
    ///
    /// A seed is a Base32 secret, or a URI with one in it: a few dozen bytes,
    /// a few hundred at the outside. The value is decrypted item content from
    /// a server, so its size is not the app's to assume — and the detail view
    /// regenerates the code once a second while the row is on screen, so the
    /// cost of trimming, lowercasing and decoding it is paid on every tick.
    static let maximumSeedBytes = 4_096

    /// The largest period a seed may ask for, in seconds. RFC 6238 recommends
    /// thirty and real deployments use thirty or sixty; this is not a policy
    /// on what is sensible but a bound on what the window arithmetic and the
    /// countdown ring are handed. Without it a seed can name a period of
    /// `Int.max` and produce a code that never rolls over.
    static let maximumPeriod = 3_600

    /// Parses a seed and generates the code for `date`. Returns nil for an
    /// unparseable seed or secret.
    static func generate(seed: String, at date: Date) -> Generated? {
        // Bounded here rather than only in `parse`, because the Steam path
        // below does not go through `parse`, and because this is ahead of the
        // trimming and lowercasing that would otherwise copy the whole thing.
        guard seed.utf8.count <= maximumSeedBytes else { return nil }
        let trimmed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bitwarden's own "steam://<base32 secret>" seed form, used for Steam
        // Guard codes: a fixed 30-second HMAC-SHA1 counter like standard TOTP,
        // but the truncated value picks five characters from Steam's own
        // alphabet instead of formatting six decimal digits. Handled as its
        // own path rather than through `parse`/`code`, whose output is
        // decimal-digits-shaped throughout.
        if trimmed.prefix(8).lowercased() == "steam://" {
            return generateSteam(trimmed, at: date)
        }
        guard var parameters = parse(seed: seed) else { return nil }
        // The decoded secret is 2FA proof, and this runs once a second while
        // the row is visible. Releasing each copy is cheap and keeps the
        // number of live ones at one.
        defer { VaultwardenCryptoZeroize.zero(&parameters.secret) }
        guard let counter = Self.counter(at: date, period: parameters.period),
              let code = code(parameters: parameters, counter: counter) else {
            return nil
        }

        let windowStart = Double(counter) * Double(parameters.period)
        return Generated(
            code: code,
            periodEnd: Date(timeIntervalSince1970: windowStart + Double(parameters.period)),
            period: parameters.period
        )
    }

    /// The RFC 6238 counter for an instant, or nil for one it cannot express.
    ///
    /// `UInt64(_: Double)` traps rather than saturating, on a value that is
    /// not finite and on one that does not fit. The comparison has to be
    /// strict because `Double(UInt64.max)` rounds *up* to 2^64 — written as
    /// `<=` it would admit the one value it exists to exclude. No clock the
    /// app reads produces such an instant; this is the conversion declining
    /// to be the place where a bad `Date` becomes a crash.
    private static func counter(at date: Date, period: Int) -> UInt64? {
        let timestamp = date.timeIntervalSince1970
        guard timestamp.isFinite, period > 0 else { return nil }
        let value = max(0, timestamp) / Double(period)
        guard value.isFinite, value < Double(UInt64.max) else { return nil }
        return UInt64(value)
    }

    /// Steam Guard's alphabet: 26 characters chosen to avoid visually
    /// ambiguous ones (no 0/O/1/I, no vowels besides those excluded by the
    /// same reasoning). Codes are always 5 characters, always HMAC-SHA1,
    /// always a 30-second period — Steam's scheme has no equivalent of
    /// otpauth's digits/algorithm/period parameters to override.
    private static let steamAlphabet = Array("23456789BCDFGHJKMNPQRTVWXY")
    private static let steamPeriod = 30

    private static func generateSteam(_ seed: String, at date: Date) -> Generated? {
        let secretString = String(seed.dropFirst(8))
        guard var secret = base32Decode(secretString), !secret.isEmpty else { return nil }
        defer { VaultwardenCryptoZeroize.zero(&secret) }

        guard let counter = Self.counter(at: date, period: steamPeriod) else { return nil }
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
        guard seed.utf8.count <= maximumSeedBytes else { return nil }
        let trimmed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("otpauth://") {
            return parseURI(trimmed)
        }
        guard let secret = base32Decode(trimmed) else { return nil }
        return Parameters(secret: secret, digits: 6, period: 30, algorithm: .sha1)
    }

    /// One optional URI parameter, as read rather than as resolved.
    ///
    /// The third case is the reason this is not just `String?`. A parameter
    /// that appears twice is ambiguous, not merely odd: the two spellings
    /// produce different codes and nothing in the seed says which was meant,
    /// so quietly taking the first is the app choosing on the user's behalf
    /// and showing a code that may be wrong without saying so.
    private enum URIParameter {
        case absent
        case present(String)
        case repeated
    }

    private static func parseURI(_ uri: String) -> Parameters? {
        // `parse` established the `otpauth://` prefix; this establishes that
        // it is a *TOTP* URI. `otpauth://hotp/...` is a counter-based seed
        // whose parameters mean something else, and treating it as
        // time-based would print a plausible code that never works.
        guard let components = URLComponents(string: uri),
              components.scheme?.lowercased() == "otpauth",
              components.host?.lowercased() == "totp",
              components.user == nil,
              components.password == nil,
              components.fragment == nil else {
            return nil
        }
        let items = components.queryItems ?? []
        func read(_ name: String) -> URIParameter {
            let matches = items.filter { $0.name.lowercased() == name }
            guard matches.count <= 1 else { return .repeated }
            guard let value = matches.first?.value else { return .absent }
            return .present(value)
        }
        /// A parameter takes its default when absent, must parse when
        /// present, and is refused when repeated. An unreadable value is not
        /// silently replaced by the default: a seed saying `digits=x` when it
        /// meant eight would otherwise show a working-looking six-digit code.
        func parameter<T>(
            _ name: String, default fallback: T, convert: (String) -> T?
        ) -> T? {
            switch read(name) {
            case .absent: return fallback
            case .present(let raw): return convert(raw)
            case .repeated: return nil
            }
        }

        guard case .present(let secretString) = read("secret"),
              let secret = base32Decode(secretString) else {
            return nil
        }
        guard let digits = parameter("digits", default: 6, convert: { Int($0) }),
              let period = parameter("period", default: 30, convert: { Int($0) }),
              let algorithm = parameter(
                  "algorithm", default: Parameters.Algorithm.sha1,
                  convert: { Parameters.Algorithm(rawValue: $0.uppercased()) }
              ) else {
            return nil
        }
        guard digits >= 6, digits <= 8, period >= 1, period <= maximumPeriod else { return nil }
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
    ///
    /// Nil for anything that is not a decodable secret, which includes an
    /// input that decodes to no bytes at all: a single character carries five
    /// bits and yields nothing, and returning empty `Data` for it would make
    /// "there was no secret here" look like a successful decode.
    static func base32Decode(_ input: String) -> Data? {
        // Ahead of the uppercasing and the two replacements, each of which
        // copies the whole string.
        guard input.utf8.count <= maximumSeedBytes else { return nil }
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
        var accumulator: UInt32 = 0
        var output = [UInt8]()
        output.reserveCapacity(cleaned.utf8.count * 5 / 8)
        for character in cleaned {
            guard let value = lookup[character] else { return nil }
            // Only the bits not yet emitted are kept. Retaining the whole
            // history and shifting it worked — Swift's `<<` on a fixed-width
            // integer discards what it shifts out rather than trapping, and
            // the read is masked to a byte — but it left the accumulator
            // holding a growing prefix of garbage that the correctness of
            // every line below had to be checked against.
            accumulator = (accumulator << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((accumulator >> UInt32(bits)) & 0xFF))
                accumulator &= (UInt32(1) << UInt32(bits)) - 1
            }
        }
        guard !output.isEmpty else { return nil }
        return Data(output)
    }
}
