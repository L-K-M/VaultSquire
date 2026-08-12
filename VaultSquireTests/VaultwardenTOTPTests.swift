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

    // MARK: - Bounds on the seed

    /// A seed is decrypted item content, so its size is the server's choice
    /// rather than the app's assumption — and the detail view re-reads it once
    /// a second while the row is on screen.
    func testAnOversizeSeedIsRefusedBeforeItIsParsed() {
        let atTheLimit = String(repeating: "A", count: VaultwardenTOTP.maximumSeedBytes)
        let overTheLimit = atTheLimit + "A"
        XCTAssertNotNil(VaultwardenTOTP.parse(seed: atTheLimit))
        XCTAssertNil(VaultwardenTOTP.parse(seed: overTheLimit))
        XCTAssertNil(VaultwardenTOTP.generate(seed: overTheLimit, at: Date()))
        // The Steam path does not go through `parse`, so it needs the bound
        // applied at the entry point rather than inside the parser.
        XCTAssertNil(VaultwardenTOTP.generate(seed: "steam://" + overTheLimit, at: Date()))
    }

    /// `UInt64(_: Double)` traps on a value it cannot represent, so the
    /// conversion refuses instead. Nothing the app reads produces such a date;
    /// this pins that the boundary is excluded rather than approached.
    func testATimeThatCannotBecomeACounterReturnsNil() {
        for interval in [Double.infinity, -.infinity, .nan, Double(UInt64.max) * 30] {
            XCTAssertNil(VaultwardenTOTP.generate(
                seed: rfcSecretBase32, at: Date(timeIntervalSince1970: interval)
            ), "\(interval)")
            XCTAssertNil(VaultwardenTOTP.generate(
                seed: "steam://\(rfcSecretBase32)", at: Date(timeIntervalSince1970: interval)
            ), "steam \(interval)")
        }
        // A time before the epoch is clamped, not refused: it is an ordinary
        // clock being wrong, and the first window is the honest answer.
        XCTAssertNotNil(VaultwardenTOTP.generate(
            seed: rfcSecretBase32, at: Date(timeIntervalSince1970: -1)
        ))
    }

    // MARK: - Bounds on the URI

    /// `otpauth://hotp/` is a counter-based seed whose parameters mean
    /// something else. Reading it as time-based prints a plausible code that
    /// never works.
    func testOnlyATOTPURIIsAccepted() {
        XCTAssertNil(VaultwardenTOTP.parse(seed: "otpauth://hotp/x?secret=\(rfcSecretBase32)"))
        XCTAssertNil(VaultwardenTOTP.parse(seed: "otpauth:///x?secret=\(rfcSecretBase32)"))
        XCTAssertNil(VaultwardenTOTP.parse(
            seed: "otpauth://totp/x?secret=\(rfcSecretBase32)#fragment"
        ))
        XCTAssertNotNil(VaultwardenTOTP.parse(seed: "otpauth://TOTP/x?secret=\(rfcSecretBase32)"))
    }

    /// A parameter given twice produces two different codes and the seed does
    /// not say which was meant, so taking the first would be the app choosing
    /// on the user's behalf and not saying so.
    func testARepeatedParameterIsRefusedRatherThanResolved() {
        for seed in [
            "otpauth://totp/x?secret=\(rfcSecretBase32)&secret=\(rfcSecretBase32)",
            "otpauth://totp/x?secret=\(rfcSecretBase32)&digits=6&digits=8",
            "otpauth://totp/x?secret=\(rfcSecretBase32)&period=30&period=60",
            "otpauth://totp/x?secret=\(rfcSecretBase32)&algorithm=SHA1&algorithm=SHA256"
        ] {
            XCTAssertNil(VaultwardenTOTP.parse(seed: seed), seed)
        }
    }

    /// An unreadable value is not quietly replaced by the default. A seed that
    /// says `digits=x` when it meant eight would otherwise show a
    /// working-looking six-digit code that is simply wrong.
    func testAnUnreadableParameterFailsClosedInsteadOfDefaulting() {
        for seed in [
            "otpauth://totp/x?secret=\(rfcSecretBase32)&digits=x",
            "otpauth://totp/x?secret=\(rfcSecretBase32)&period=soon",
            "otpauth://totp/x?secret=\(rfcSecretBase32)&algorithm=MD5",
            "otpauth://totp/x?secret=\(rfcSecretBase32)&digits=9",
            "otpauth://totp/x?secret=\(rfcSecretBase32)&digits=5",
            "otpauth://totp/x?secret=\(rfcSecretBase32)&period=0",
            "otpauth://totp/x?secret=\(rfcSecretBase32)&period=-30",
            "otpauth://totp/x?secret=\(rfcSecretBase32)&period="
                + String(VaultwardenTOTP.maximumPeriod + 1)
        ] {
            XCTAssertNil(VaultwardenTOTP.parse(seed: seed), seed)
        }
    }

    /// And an absent parameter still takes its default, which is the whole
    /// point of distinguishing absent from unreadable.
    func testAnAbsentParameterStillTakesItsDefault() {
        let parsed = VaultwardenTOTP.parse(seed: "otpauth://totp/x?secret=\(rfcSecretBase32)")
        XCTAssertEqual(parsed?.digits, 6)
        XCTAssertEqual(parsed?.period, 30)
        XCTAssertEqual(parsed?.algorithm, .sha1)
    }

    // MARK: - Base32

    /// An input that carries no whole byte is a failed decode, not an empty
    /// secret: five bits produce nothing, and returning empty `Data` would
    /// make "there was no secret here" look like a success.
    func testBase32InputThatYieldsNoBytesIsAFailure() {
        XCTAssertNil(VaultwardenTOTP.base32Decode("A"))
        XCTAssertNil(VaultwardenTOTP.base32Decode("="))
        XCTAssertNil(VaultwardenTOTP.base32Decode("   "))
        XCTAssertNil(VaultwardenTOTP.base32Decode(String(
            repeating: "A", count: VaultwardenTOTP.maximumSeedBytes + 1
        )))
    }

    /// The decoder keeps only the bits it has not emitted. This pins the
    /// output against a known vector so that change is not a silent one.
    func testBase32DecodesTheRFCSecretExactly() {
        XCTAssertEqual(
            VaultwardenTOTP.base32Decode(rfcSecretBase32),
            Data("12345678901234567890".utf8)
        )
        // Padded, spaced and lowercase spellings of the same secret.
        XCTAssertEqual(VaultwardenTOTP.base32Decode("MZXW6==="), Data("foo".utf8))
        XCTAssertEqual(VaultwardenTOTP.base32Decode("mz xw 6"), Data("foo".utf8))
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
