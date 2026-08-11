import XCTest
@testable import VaultSquire

final class VaultwardenTOTPTests: XCTestCase {
    // RFC 6238 test seed: the ASCII secret "12345678901234567890", Base32-encoded.
    private let rfcSecretBase32 = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

    func testRFC6238KnownAnswerSHA1() {
        // RFC 6238 Appendix B, SHA-1, 8 digits: T=59s -> 94287082.
        let seed = "otpauth://totp/Example?secret=\(rfcSecretBase32)&digits=8&period=30&algorithm=SHA1"
        let generated = VaultwardenTOTP.generate(seed: seed, at: Date(timeIntervalSince1970: 59))
        XCTAssertEqual(generated?.code, "94287082")
        // The window ends at the next 30s boundary after T=1 (i.e. 60s).
        XCTAssertEqual(generated?.periodEnd, Date(timeIntervalSince1970: 60))
    }

    func testRFC6238KnownAnswerLaterWindow() {
        // T=1111111109s -> 07081804 (SHA-1, 8 digits).
        let seed = "otpauth://totp/Example?secret=\(rfcSecretBase32)&digits=8&algorithm=SHA1"
        let generated = VaultwardenTOTP.generate(seed: seed, at: Date(timeIntervalSince1970: 1_111_111_109))
        XCTAssertEqual(generated?.code, "07081804")
    }

    func testBareBase32SecretDefaultsToSixDigitSHA1() {
        let generated = VaultwardenTOTP.generate(
            seed: rfcSecretBase32, at: Date(timeIntervalSince1970: 59)
        )
        // The last six digits of the 8-digit vector.
        XCTAssertEqual(generated?.code, "287082")
        XCTAssertEqual(generated?.period, 30)
    }

    func testLowercaseAndSpacedSecretStillDecodes() {
        let spaced = "gezd gnbv gy3t qojq gezd gnbv gy3t qojq"
        let generated = VaultwardenTOTP.generate(
            seed: spaced, at: Date(timeIntervalSince1970: 59)
        )
        XCTAssertEqual(generated?.code, "287082")
    }

    func testUnparseableSeedReturnsNil() {
        XCTAssertNil(VaultwardenTOTP.generate(seed: "not a secret!!", at: Date()))
        XCTAssertNil(VaultwardenTOTP.generate(seed: "", at: Date()))
        XCTAssertNil(VaultwardenTOTP.generate(
            seed: "otpauth://totp/x?digits=6", at: Date()
        ), "a URI with no secret must not generate")
    }

    // MARK: - Steam Guard

    // Steam's own alphabet has no published RFC test vectors the way RFC 6238
    // does, so these test the shape and determinism of the algorithm — five
    // characters, all from Steam's alphabet, stable within one 30-second
    // window, changing across one — rather than a hand-computed HMAC-SHA1
    // digest this environment cannot execute to verify.
    private let steamAlphabet = Set("23456789BCDFGHJKMNPQRTVWXY")

    func testSteamSeedProducesAFiveCharacterCodeFromItsOwnAlphabet() {
        let generated = VaultwardenTOTP.generate(
            seed: "steam://\(rfcSecretBase32)", at: Date(timeIntervalSince1970: 59)
        )
        XCTAssertEqual(generated?.code.count, 5)
        XCTAssertEqual(generated?.period, 30)
        // Same 30s-boundary arithmetic as the standard-TOTP window: T=59 falls
        // in the window that ends at T=60.
        XCTAssertEqual(generated?.periodEnd, Date(timeIntervalSince1970: 60))
        for character in generated?.code ?? "" {
            XCTAssertTrue(steamAlphabet.contains(character), "\(character) is not in Steam's alphabet")
        }
    }

    func testSteamSeedIsStableWithinItsWindowAndChangesAcrossOne() {
        let secondsIntoWindow = VaultwardenTOTP.generate(
            seed: "steam://\(rfcSecretBase32)", at: Date(timeIntervalSince1970: 31)
        )
        let laterInSameWindow = VaultwardenTOTP.generate(
            seed: "steam://\(rfcSecretBase32)", at: Date(timeIntervalSince1970: 59)
        )
        let nextWindow = VaultwardenTOTP.generate(
            seed: "steam://\(rfcSecretBase32)", at: Date(timeIntervalSince1970: 61)
        )
        XCTAssertEqual(secondsIntoWindow?.code, laterInSameWindow?.code)
        XCTAssertNotEqual(laterInSameWindow?.code, nextWindow?.code)
    }

    func testSteamPrefixIsCaseInsensitive() {
        let lower = VaultwardenTOTP.generate(
            seed: "steam://\(rfcSecretBase32)", at: Date(timeIntervalSince1970: 59)
        )
        let upper = VaultwardenTOTP.generate(
            seed: "Steam://\(rfcSecretBase32)", at: Date(timeIntervalSince1970: 59)
        )
        XCTAssertEqual(lower?.code, upper?.code)
    }

    func testMalformedSteamSeedReturnsNil() {
        XCTAssertNil(VaultwardenTOTP.generate(seed: "steam://not-valid-base32!!", at: Date()))
        XCTAssertNil(VaultwardenTOTP.generate(seed: "steam://", at: Date()), "an empty secret must not generate")
    }
}
