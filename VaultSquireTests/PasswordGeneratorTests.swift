import XCTest
@testable import VaultSquire

/// The generator's contract: it produces what the policy asked for, it refuses
/// a policy it cannot satisfy rather than inventing one, and the meter beside
/// the field ranks length and variety in the order a person would.
final class PasswordGeneratorTests: XCTestCase {
    // MARK: - Generation

    func testDefaultPolicyProducesTheRequestedLength() {
        let password = PasswordGenerator.generate()
        XCTAssertEqual(password?.count, PasswordGenerator.Options.defaultLength)
    }

    /// A site that requires a digit rejects a password that happened not to
    /// draw one, so every enabled class has to appear.
    func testEveryEnabledClassAppears() {
        let options = PasswordGenerator.Options(length: 8)
        // Run it many times: this is the property that fails intermittently
        // when it is left to chance rather than guaranteed.
        for _ in 0..<200 {
            guard let password = PasswordGenerator.generate(options) else {
                XCTFail("the default policy must be able to generate")
                return
            }
            XCTAssertTrue(password.contains { $0.isLowercase }, password)
            XCTAssertTrue(password.contains { $0.isUppercase }, password)
            XCTAssertTrue(password.contains { $0.isNumber }, password)
            XCTAssertTrue(
                password.contains { !$0.isLetter && !$0.isNumber },
                "a symbol was requested: \(password)"
            )
        }
    }

    func testOnlyTheEnabledClassesAreUsed() {
        let options = PasswordGenerator.Options(length: 40, classes: [.digits])
        let password = PasswordGenerator.generate(options) ?? ""
        XCTAssertEqual(password.count, 40)
        XCTAssertTrue(password.allSatisfy(\.isNumber), password)
    }

    /// Confusable characters are excluded by default, because a password is
    /// retyped by hand more often than anyone plans for.
    func testAmbiguousCharactersAreExcludedUnlessAskedFor() {
        let cautious = PasswordGenerator.Options(length: 64, classes: [.lowercase, .uppercase, .digits])
        for _ in 0..<50 {
            let password = PasswordGenerator.generate(cautious) ?? ""
            XCTAssertFalse(password.contains { "lIO01".contains($0) }, password)
        }

        var permissive = cautious
        permissive.allowsAmbiguous = true
        XCTAssertTrue(
            permissive.pool.contains("0"),
            "the confusable characters come back when they are allowed"
        )
    }

    func testLengthIsClampedToTheSupportedRange() {
        var tooShort = PasswordGenerator.Options(length: 1)
        XCTAssertEqual(tooShort.effectiveLength, PasswordGenerator.Options.minimumLength)
        XCTAssertEqual(
            PasswordGenerator.generate(tooShort)?.count, PasswordGenerator.Options.minimumLength
        )

        tooShort.length = 10_000
        XCTAssertEqual(tooShort.effectiveLength, PasswordGenerator.Options.maximumLength)
    }

    /// Turning every class off is the one policy that cannot produce anything.
    /// It returns nil rather than an empty string, so a caller cannot mistake
    /// "nothing was asked for" for "here is your password".
    func testAnUnsatisfiablePolicyGeneratesNothing() {
        let empty = PasswordGenerator.Options(length: 20, classes: [])
        XCTAssertFalse(empty.isSatisfiable)
        XCTAssertNil(PasswordGenerator.generate(empty))
    }

    func testTwoGenerationsDiffer() {
        let first = PasswordGenerator.generate()
        let second = PasswordGenerator.generate()
        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, second, "a 20-character password repeating is a broken source")
    }

    // MARK: - Strength

    func testStrengthRanksLengthAndVariety() {
        XCTAssertEqual(PasswordGenerator.strength(of: ""), .weak)
        XCTAssertEqual(PasswordGenerator.strength(of: "hunter2"), .weak)
        XCTAssertLessThan(
            PasswordGenerator.strength(of: "abcdefgh"),
            PasswordGenerator.strength(of: "aB3$aB3$aB3$xY7!")
        )
        XCTAssertGreaterThanOrEqual(
            PasswordGenerator.strength(of: PasswordGenerator.generate() ?? ""),
            .strong,
            "the default policy has to produce something the meter calls strong"
        )
    }

    /// The meter cannot spot a dictionary word, and says so in its own
    /// documentation — but one character repeated must not read as strong
    /// merely because there are twenty of it.
    func testRepetitionDoesNotBuyStrength() {
        XCTAssertLessThan(
            PasswordGenerator.entropyBits(of: String(repeating: "a", count: 20)),
            PasswordGenerator.entropyBits(of: "qwertyuiopasdfghjklz")
        )
    }

    func testEntropyGrowsWithLengthAndPool() {
        XCTAssertGreaterThan(
            PasswordGenerator.entropyBits(of: "abcdefghijklmnop"),
            PasswordGenerator.entropyBits(of: "abcdefgh")
        )
        XCTAssertGreaterThan(
            PasswordGenerator.entropyBits(of: "aB3$eF7%"),
            PasswordGenerator.entropyBits(of: "abcdefgh")
        )
    }
}
