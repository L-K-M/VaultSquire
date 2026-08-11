import XCTest
@testable import VaultSquire

final class VaultwardenErrorTests: XCTestCase {
    private func body(_ json: String) throws -> VaultwardenErrorBody {
        try JSONDecoder().decode(VaultwardenErrorBody.self, from: Data(json.utf8))
    }

    // ERR-01: server prose can echo submitted secrets or inject controls. It
    // remains a classification input only; user-facing messages are local.
    func testServerProvidedDescriptionsNeverReachDisplay() throws {
        let decoded = try body(
            #"{"error":"invalid_grant","error_description":"VSQ-password","Message":"spoof"}"#
        )
        let message = VaultwardenErrorDecoder.safeMessage(from: decoded, httpStatus: 400)
        XCTAssertEqual(message, "The server rejected the sign-in request.")
        XCTAssertFalse(message.contains("VSQ-password"))
        XCTAssertFalse(message.contains("spoof"))
    }

    func testFixedMessageIgnoresEveryProviderErrorShape() throws {
        XCTAssertEqual(
            VaultwardenErrorDecoder.safeMessage(from: try body(#"{"Message":"top"}"#), httpStatus: 400),
            "The server rejected the sign-in request."
        )
        XCTAssertEqual(
            VaultwardenErrorDecoder.safeMessage(
                from: try body(#"{"ErrorModel":{"Message":"model"}}"#), httpStatus: 400
            ),
            "The server rejected the sign-in request."
        )
        XCTAssertEqual(
            VaultwardenErrorDecoder.safeMessage(
                from: try body(#"{"validationErrors":{"":["v1","v2"]}}"#), httpStatus: 400
            ),
            "The server rejected the sign-in request."
        )
    }

    func testUnknownStatusMessageContainsOnlyTheNumericStatus() {
        XCTAssertEqual(
            VaultwardenErrorDecoder.safeMessage(from: nil, httpStatus: 418),
            "The server returned an error (status 418)."
        )
    }

    func testClassify429IsRateLimitWithBackoff() throws {
        let error = VaultwardenErrorDecoder.classify(
            httpStatus: 429, body: try body(#"{"error":"rate"}"#), retryAfter: 30
        )
        XCTAssertEqual(error.category, .rateLimit)
        XCTAssertEqual(error.retry, .backoffThenRetry(retryAfter: 30))
    }

    func testUntrustedMachineCodeIsDroppedInsteadOfRetained() throws {
        let error = VaultwardenErrorDecoder.classify(
            httpStatus: 429,
            body: try body(#"{"error":"VSQ-secret\\ninjected"}"#),
            retryAfter: nil
        )

        XCTAssertNil(error.machineCode)
        XCTAssertFalse(error.safeDisplayMessage.contains("VSQ-secret"))
    }

    func testClassifyInvalidGrantIsContextSensitive() throws {
        // On a login grant, invalid_grant means the credentials were rejected.
        let login = VaultwardenErrorDecoder.classify(
            httpStatus: 400, body: try body(#"{"error":"invalid_grant"}"#),
            retryAfter: nil, context: .login
        )
        XCTAssertEqual(login.category, .badCredentials)
        XCTAssertEqual(login.machineCode, "invalid_grant")
        XCTAssertEqual(login.retry, .noRetry)

        // On a refresh grant, the same code means the session ended.
        let refresh = VaultwardenErrorDecoder.classify(
            httpStatus: 400, body: try body(#"{"error":"invalid_grant"}"#),
            retryAfter: nil, context: .refresh
        )
        XCTAssertEqual(refresh.category, .sessionExpired)
        XCTAssertEqual(refresh.retry, .noRetry)
    }

    func testClassifyBadCredentialsAndAccountLockedAndServerError() throws {
        XCTAssertEqual(
            VaultwardenErrorDecoder.classify(httpStatus: 400, body: nil, retryAfter: nil).category,
            .badCredentials
        )
        XCTAssertEqual(
            VaultwardenErrorDecoder.classify(httpStatus: 423, body: nil, retryAfter: nil).category,
            .accountLocked
        )
        let serverError = VaultwardenErrorDecoder.classify(httpStatus: 503, body: nil, retryAfter: nil)
        XCTAssertEqual(serverError.category, .network)
        XCTAssertEqual(serverError.retry, .backoffThenRetry(retryAfter: nil))
    }

    func testTwoFactorChallengeDetectionFromMaps() throws {
        let challenge = try body(#"{"TwoFactorProviders":["0","1"],"TwoFactorProviders2":{"0":{},"1":{}}}"#)
        XCTAssertTrue(challenge.signalsTwoFactorChallenge)
        XCTAssertEqual(challenge.offeredProviderIDs, [0, 1])

        let notChallenge = try body(#"{"error":"invalid_username_or_password"}"#)
        XCTAssertFalse(notChallenge.signalsTwoFactorChallenge)
    }

    func testProviderValidationProseIsNotRetained() throws {
        let decoded = try body(
            #"{"validationErrors":{"password":["VSQ-password"]},"Message":"spoof"}"#
        )
        XCTAssertNil(decoded.validationErrors)
        XCTAssertNil(decoded.message)
        XCTAssertNil(decoded.flattenedValidationErrors)
    }
}
