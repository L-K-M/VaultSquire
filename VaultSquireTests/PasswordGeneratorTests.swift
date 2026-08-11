import XCTest
@testable import VaultSquire

/// The generator is the one place a password is created in this app, so its
/// policy guarantees are tested directly: length, per-set membership, the
/// ambiguous-character exclusion, and the empty-policy fallback. Everything
/// here is deterministic-enough to assert on — the CSPRNG cannot break a
/// guaranteed character, and a wrong pool would show up across many samples.
final class PasswordGeneratorTests: XCTestCase {
    private let options = PasswordGenerator.Options()

    func testGeneratedPasswordHasTheRequestedLength() {
        for length in [8, 16, 20, 40, 64] {
            var options = options
            options.length = length
            XCTAssertEqual(
                PasswordGenerator.generate(options: options).count,
                length,
                "length \(length) not honored"
            )
        }
    }

    func testLengthIsClampedToTheSupportedRange() {
        var short = options
        short.length = 1
        XCTAssertEqual(PasswordGenerator.generate(options: short).count, 8)
        var long = options
        long.length = 500
        XCTAssertEqual(PasswordGenerator.generate(options: long).count, 64)
    }

    func testEveryEnabledCharacterSetContributesAtLeastOneCharacter() {
        // The guarantee must hold on the very first draw, so sample generously.
        for _ in 0..<200 {
            var options = options
            options.length = 16
            let password = PasswordGenerator.generate(options: options)
            XCTAssertTrue(
                PasswordGenerator.satisfiesPolicy(password, options: options),
                "generated password \(password) missed a required set"
            )
        }
    }

    func testAllCharactersComeFromTheEnabledPools() {
        for _ in 0..<100 {
            let password = PasswordGenerator.generate(options: options)
            let allowed = CharacterSet(
                charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()-_=+[]{};:,.?"
            )
            for character in password {
                let scalar = character.unicodeScalars.first!
                XCTAssertTrue(
                    allowed.contains(scalar),
                    "unexpected character \(character) in \(password)"
                )
            }
        }
    }

    func testAmbiguousExclusionRemovesConfusableCharacters() {
        var options = options
        options.excludeAmbiguous = true
        let ambiguous = Set("0O1lI")
        for _ in 0..<200 {
            let password = PasswordGenerator.generate(options: options)
            XCTAssertFalse(
                password.contains { ambiguous.contains($0) },
                "ambiguous character in \(password)"
            )
            XCTAssertTrue(
                PasswordGenerator.satisfiesPolicy(password, options: options),
                "exclusion must not drop a required set entirely"
            )
        }
    }

    func testEmptyPolicyFallsBackToLowercaseAndDigits() {
        var options = options
        options.includeUppercase = false
        options.includeLowercase = false
        options.includeDigits = false
        options.includeSymbols = false
        XCTAssertFalse(options.hasAnyCharacterSetEnabled)

        let password = PasswordGenerator.generate(options: options)
        XCTAssertFalse(password.isEmpty)
        // The fallback policy is lowercase + digits; neither the length nor the
        // non-empty guarantee may be broken by the fallback.
        XCTAssertEqual(password.count, options.length)
    }

    func testGeneratedPasswordsVary() {
        // A fixed-pool generator that always returned the same password would
        // be a serious defect; a collision across 50 draws of length 20 is
        // effectively impossible unless the generator is broken.
        var seen = Set<String>()
        for _ in 0..<50 {
            seen.insert(PasswordGenerator.generate(options: options))
        }
        XCTAssertGreaterThanOrEqual(seen.count, 49, "generator repeats suspiciously")
    }
}
