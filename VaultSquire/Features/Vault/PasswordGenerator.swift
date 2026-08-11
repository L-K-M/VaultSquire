import Foundation

/// An offline, local password generator for the create/edit sheet.
///
/// It uses only the system CSPRNG and character constants compiled into the
/// app: no network, no logging, and nothing derived from vault content. The
/// generated password is plaintext only while the edit sheet is open — exactly
/// like every other draft field — and the provider encrypts it before it leaves
/// the device. Nothing here is ever persisted or written to the pasteboard
/// automatically.
enum PasswordGenerator {
    struct Options: Equatable, Sendable {
        var length: Int = Self.defaultLength
        var includeUppercase = true
        var includeLowercase = true
        var includeDigits = true
        var includeSymbols = true
        /// Drops the easily confused characters `0O1lI` from every enabled set.
        var excludeAmbiguous = false

        static let lengthRange = 8...64
        static let defaultLength = 20

        /// Whether at least one character set is enabled. The UI uses this to
        /// refuse turning off the last set; the generator falls back to
        /// lowercase + digits for callers that bypass it.
        var hasAnyCharacterSetEnabled: Bool {
            includeUppercase || includeLowercase || includeDigits || includeSymbols
        }
    }

    private static let uppercase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    private static let lowercase = "abcdefghijklmnopqrstuvwxyz"
    private static let digits = "0123456789"
    private static let symbols = "!@#$%^&*()-_=+[]{};:,.?"
    private static let ambiguous = Set("0O1lI")

    /// Generates a password meeting `options`.
    ///
    /// At least one character from every enabled set is guaranteed, so a policy
    /// that asks for digits cannot come back digit-free by chance; the remaining
    /// positions are drawn from the union of the enabled sets, and the result is
    /// shuffled so the guaranteed characters are not always leading. The length
    /// is clamped to `lengthRange`. When no set is enabled the generator falls
    /// back to lowercase + digits rather than producing the empty string.
    static func generate(options: Options) -> String {
        let length = min(
            max(options.length, Options.lengthRange.lowerBound),
            Options.lengthRange.upperBound
        )

        var pools: [String] = []
        func pool(_ characters: String) -> String {
            options.excludeAmbiguous
                ? String(characters.filter { !ambiguous.contains($0) })
                : characters
        }
        if options.includeUppercase { pools.append(pool(uppercase)) }
        if options.includeLowercase { pools.append(pool(lowercase)) }
        if options.includeDigits { pools.append(pool(digits)) }
        if options.includeSymbols { pools.append(pool(symbols)) }
        pools = pools.filter { !$0.isEmpty }
        if pools.isEmpty { pools = [pool(lowercase), pool(digits)] }

        let union = pools.joined()
        var generator = SystemRandomNumberGenerator()
        var characters: [Character] = []
        // One guaranteed character per enabled set, up to the requested length.
        for set in pools.prefix(length) {
            characters.append(character(from: set, using: &generator))
        }
        while characters.count < length {
            characters.append(character(from: union, using: &generator))
        }
        characters.shuffle(using: &generator)
        return String(characters)
    }

    /// Whether a generated password satisfies `options` character-set policy.
    /// Used by tests and available to callers that want to validate a password
    /// a user typed instead of generated.
    static func satisfiesPolicy(_ password: String, options: Options) -> Bool {
        guard !password.isEmpty else { return false }
        func has(_ characters: String) -> Bool {
            password.contains { characters.contains($0) }
        }
        if options.includeUppercase, !has(uppercase) { return false }
        if options.includeLowercase, !has(lowercase) { return false }
        if options.includeDigits, !has(digits) { return false }
        if options.includeSymbols, !has(symbols) { return false }
        return true
    }

    private static func character(
        from pool: String,
        using generator: inout SystemRandomNumberGenerator
    ) -> Character {
        let offset = Int.random(in: 0..<pool.count, using: &generator)
        return pool[pool.index(pool.startIndex, offsetBy: offset)]
    }
}
