import Foundation

/// Generates passwords for the edit sheet.
///
/// Randomness comes from `SystemRandomNumberGenerator`, which is backed by the
/// system CSPRNG on Apple platforms, and every index is drawn by rejection
/// sampling so no character is more likely than any other. The generated value
/// lives only in the draft being edited: it is never logged, never persisted,
/// and never touches the clipboard until the user copies it themselves.
enum PasswordGenerator {
    /// The user-tunable shape of a generated password.
    struct Options: Hashable, Sendable {
        var length: Int = 20
        var includeUppercase = true
        var includeLowercase = true
        var includeDigits = true
        var includeSymbols = true

        static let minimumLength = 8
        static let maximumLength = 64
    }

    private static let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
    private static let uppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let digits = Array("0123456789")
    private static let symbols = Array("!@#$%^&*()-_=+[]{};:,.<>?/")

    /// The enabled character pools, in a stable order.
    static func pools(for options: Options) -> [[Character]] {
        var pools: [[Character]] = []
        if options.includeLowercase { pools.append(lowercase) }
        if options.includeUppercase { pools.append(uppercase) }
        if options.includeDigits { pools.append(digits) }
        if options.includeSymbols { pools.append(symbols) }
        return pools
    }

    /// Builds a password containing at least one character from each enabled
    /// pool. With every class off it falls back to alphanumeric, so the
    /// control can never produce an empty or constant password.
    static func generate(options: Options) -> String {
        let enabled = pools(for: options)
        let activePools = enabled.isEmpty ? [lowercase + uppercase + digits] : enabled
        let union = activePools.flatMap { $0 }
        let length = min(
            max(options.length, activePools.count, Options.minimumLength),
            Options.maximumLength
        )

        var generator = SystemRandomNumberGenerator()
        // Guarantee one character per pool, then fill the rest from the union.
        var characters = activePools.map { $0[randomIndex($0.count, using: &generator)] }
        while characters.count < length {
            characters.append(union[randomIndex(union.count, using: &generator)])
        }
        // Fisher–Yates, so the guaranteed characters are not always in front.
        for index in characters.indices.dropFirst() {
            let swap = index - randomIndex(index + 1, using: &generator)
            characters.swapAt(index, swap)
        }
        return String(characters)
    }

    /// A uniform index in `0..<count` without modulo bias: draws that fall in
    /// the generator's surplus range are rejected and redrawn.
    private static func randomIndex(
        _ count: Int,
        using generator: inout SystemRandomNumberGenerator
    ) -> Int {
        let bound = UInt64(count)
        let limit = UInt64.max - (UInt64.max % bound)
        while true {
            let value = generator.next()
            if value < limit {
                return Int(value % bound)
            }
        }
    }
}
