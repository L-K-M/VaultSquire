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
}
