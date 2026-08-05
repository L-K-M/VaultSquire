import XCTest
@testable import VaultSquire

final class VaultwardenErrorTests: XCTestCase {
    private func body(_ json: String) throws -> VaultwardenErrorBody {
        try JSONDecoder().decode(VaultwardenErrorBody.self, from: Data(json.utf8))
    }

    // ERR-01: default, compact, identity, and validation error shapes decode
    // to a stable message in the fixed precedence order.
    func testDecodePrecedenceIdentityErrorDescriptionWins() throws {
        let decoded = try body(#"{"error":"invalid_grant","error_description":"desc","Message":"msg"}"#)
        XCTAssertEqual(
            VaultwardenErrorDecoder.safeMessage(from: decoded, httpStatus: 400),
            "desc"
        )
    }

    func testDecodePrecedenceFallsThroughToMessageThenModelThenValidation() throws {
        XCTAssertEqual(
            VaultwardenErrorDecoder.safeMessage(from: try body(#"{"Message":"top"}"#), httpStatus: 400),
            "top"
        )
        XCTAssertEqual(
            VaultwardenErrorDecoder.safeMessage(
                from: try body(#"{"ErrorModel":{"Message":"model"}}"#), httpStatus: 400
            ),
            "model"
        )
        XCTAssertEqual(
            VaultwardenErrorDecoder.safeMessage(
                from: try body(#"{"validationErrors":{"":["v1","v2"]}}"#), httpStatus: 400
            ),
            "v1 v2"
        )
    }

    func testDecodePrecedenceGenericStatusWhenEmpty() throws {
        let message = VaultwardenErrorDecoder.safeMessage(from: try body("{}"), httpStatus: 503)
        XCTAssertTrue(message.contains("503"))
    }

    func testClassify429IsRateLimitWithBackoff() throws {
        let error = VaultwardenErrorDecoder.classify(
            httpStatus: 429, body: try body(#"{"error":"rate"}"#), retryAfter: 30
        )
        XCTAssertEqual(error.category, .rateLimit)
        XCTAssertEqual(error.retry, .backoffThenRetry(retryAfter: 30))
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

    func testValidationErrorsAreOrderedDeterministically() throws {
        let decoded = try body(#"{"validationErrors":{"b":["second"],"a":["first"]}}"#)
        XCTAssertEqual(decoded.flattenedValidationErrors, "first second")
    }
}
