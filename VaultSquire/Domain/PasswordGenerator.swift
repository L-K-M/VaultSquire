import Foundation

/// Builds a random password from an explicit character policy, and estimates
/// the strength of one that was typed.
///
/// Everything here is local and deterministic in its rules but not in its
/// output: characters come from `SystemRandomNumberGenerator`, which is the
/// platform's cryptographic source, through `randomElement(using:)`, which is
/// unbiased — a modulo over `arc4random()` is not, and a password generator is
/// exactly where that matters.
///
/// A generated password exists only in the draft the edit sheet holds. It is
/// never logged, never persisted in the clear, and reaches the provider the
/// same way a typed one does.
enum PasswordGenerator {
    /// The character classes a password may draw from. Each is written out
    /// rather than derived from a character set, so what can be produced is
    /// visible in the source and cannot change under a locale.
    enum CharacterClass: String, CaseIterable, Sendable {
        case lowercase = "abcdefghijkmnopqrstuvwxyz"
        case uppercase = "ABCDEFGHJKLMNPQRSTUVWXYZ"
        case digits = "23456789"
        case symbols = "!#$%&*+-=?@^_"

        /// The characters that are easy to confuse when a password is read off
        /// a screen or over the phone: `l`, `I`, `1`, `O`, `0`. They are absent
        /// from the classes above, and added back when the user says they do
        /// not mind them.
        var ambiguousCharacters: String {
            switch self {
            case .lowercase: return "l"
            case .uppercase: return "IO"
            case .digits: return "01"
            case .symbols: return ""
            }
        }

        func characters(includingAmbiguous: Bool) -> [Character] {
            Array(includingAmbiguous ? rawValue + ambiguousCharacters : rawValue)
        }
    }

    /// What to generate. The defaults are what a password manager should hand
    /// someone who presses the button without reading anything: long, mixed,
    /// and readable.
    struct Options: Equatable, Sendable {
        static let minimumLength = 8
        static let maximumLength = 64
        static let defaultLength = 20

        var length: Int
        var classes: Set<CharacterClass>
        /// Whether the confusable characters are allowed. Off by default,
        /// because a password is retyped by hand more often than anyone plans.
        var allowsAmbiguous: Bool

        init(
            length: Int = Options.defaultLength,
            classes: Set<CharacterClass> = [.lowercase, .uppercase, .digits, .symbols],
            allowsAmbiguous: Bool = false
        ) {
            self.length = length
            self.classes = classes
            self.allowsAmbiguous = allowsAmbiguous
        }

        /// The length actually used, clamped to the supported range so a stored
        /// or mistyped value can never ask for a one-character password.
        var effectiveLength: Int {
            min(max(length, Self.minimumLength), Self.maximumLength)
        }

        /// Every character the policy permits, in class order.
        var pool: [Character] {
            CharacterClass.allCases
                .filter { classes.contains($0) }
                .flatMap { $0.characters(includingAmbiguous: allowsAmbiguous) }
        }

        /// False when every class has been turned off, which is the one policy
        /// that cannot produce anything.
        var isSatisfiable: Bool {
            !classes.isEmpty
        }
    }

    /// Generates a password, or nil when the policy permits no characters at
    /// all. Every enabled class is guaranteed to appear: sites that require a
    /// digit or a symbol reject a password that happens not to have drawn one,
    /// and a user who has to press the button five times learns to widen the
    /// policy rather than to trust it.
    static func generate(_ options: Options = Options()) -> String? {
        guard options.isSatisfiable else { return nil }
        var generator = SystemRandomNumberGenerator()
        return generate(options, using: &generator)
    }

    /// The generator with its randomness injected, so the tests can pin an
    /// output without weakening the production path.
    static func generate<Source: RandomNumberGenerator>(
        _ options: Options,
        using generator: inout Source
    ) -> String? {
        guard options.isSatisfiable else { return nil }
        let pool = options.pool
        guard !pool.isEmpty else { return nil }

        let ordered = CharacterClass.allCases.filter { options.classes.contains($0) }
        var characters: [Character] = []
        // One from each enabled class first, so none can be missing …
        for characterClass in ordered {
            let members = characterClass.characters(includingAmbiguous: options.allowsAmbiguous)
            guard let pick = members.randomElement(using: &generator) else { continue }
            characters.append(pick)
        }
        // … then the rest from everything, and shuffled so the guaranteed ones
        // are not always at the front.
        while characters.count < options.effectiveLength {
            guard let pick = pool.randomElement(using: &generator) else { break }
            characters.append(pick)
        }
        characters = Array(characters.prefix(options.effectiveLength))
        characters.shuffle(using: &generator)
        return String(characters)
    }

    // MARK: - Strength

    /// A coarse verdict on a password, for the meter beside the field.
    enum Strength: Int, Comparable, Sendable, CaseIterable {
        case weak
        case fair
        case strong
        case excellent

        static func < (lhs: Strength, rhs: Strength) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var label: String {
            switch self {
            case .weak: return "Weak"
            case .fair: return "Fair"
            case .strong: return "Strong"
            case .excellent: return "Excellent"
            }
        }
    }

    /// An upper bound on how much work guessing this password would take, in
    /// bits, assuming an attacker who knows only which character classes it
    /// draws from.
    ///
    /// Deliberately an upper bound, and deliberately simple. It cannot tell
    /// that `Password123!` is a dictionary word with a suffix, and nothing here
    /// pretends otherwise: the meter's job is to make a six-character password
    /// visibly worse than a twenty-character one, not to score human choices.
    /// The one concession to that is a repeated-character discount, which stops
    /// `aaaaaaaaaaaaaaaaaaaa` from reading as strong.
    static func entropyBits(of password: String) -> Double {
        guard !password.isEmpty else { return 0 }
        var poolSize = 0
        var sawLower = false
        var sawUpper = false
        var sawDigit = false
        var sawOther = false
        for character in password {
            if character.isLowercase { sawLower = true }
            else if character.isUppercase { sawUpper = true }
            else if character.isNumber { sawDigit = true }
            else { sawOther = true }
        }
        if sawLower { poolSize += 26 }
        if sawUpper { poolSize += 26 }
        if sawDigit { poolSize += 10 }
        if sawOther { poolSize += 33 }
        guard poolSize > 1 else { return 0 }

        // A password with few distinct characters carries far less than its
        // length suggests, so the count is discounted towards its distinct
        // characters rather than taken at face value.
        let distinct = Set(password).count
        let effectiveLength = Double(min(password.count, distinct * 2))
        return effectiveLength * log2(Double(poolSize))
    }

    static func strength(of password: String) -> Strength {
        switch entropyBits(of: password) {
        case ..<40: return .weak
        case ..<60: return .fair
        case ..<90: return .strong
        default: return .excellent
        }
    }
}
