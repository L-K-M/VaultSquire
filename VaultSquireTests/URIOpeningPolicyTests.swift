import XCTest
@testable import VaultSquire

/// The URI-opening policy: only parsed http/https destinations leave the app,
/// with no user info, and the effective scheme and host are always derived
/// for confirmation before anything opens.
final class URIOpeningPolicyTests: XCTestCase {
    func testBareHostIsPromotedToHTTPS() {
        let decision = URIOpeningPolicy.decision(for: "github.com")
        XCTAssertEqual(decision?.url.absoluteString, "https://github.com")
        XCTAssertEqual(decision?.display, "https://github.com")
    }

    func testHTTPAndHTTPSAreTheOnlyPermittedSchemes() {
        XCTAssertNotNil(URIOpeningPolicy.decision(for: "https://example.com/path?q=1"))
        XCTAssertNotNil(URIOpeningPolicy.decision(for: "http://example.com"))
    }

    func testNonWebSchemesAreBlocked() {
        for raw in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "ssh://git@github.com/repo",
            "androidapp://com.example",
            "itms-apps://apps.apple.com",
            "about:blank",
        ] {
            XCTAssertNil(URIOpeningPolicy.decision(for: raw), "\(raw) must not leave the app")
        }
    }

    func testURLCredentialsAreRejected() {
        XCTAssertNil(URIOpeningPolicy.decision(for: "https://user:pass@example.com"))
        XCTAssertNil(URIOpeningPolicy.decision(for: "https://user@example.com"))
    }

    func testHostlessAndEmptyValuesAreRejected() {
        XCTAssertNil(URIOpeningPolicy.decision(for: ""))
        XCTAssertNil(URIOpeningPolicy.decision(for: "   "))
        XCTAssertNil(URIOpeningPolicy.decision(for: "https://"))
        XCTAssertNil(URIOpeningPolicy.decision(for: "http:///path"))
    }

    func testTheEffectiveHostAndPortAreWhatGetsDisplayed() {
        let decision = URIOpeningPolicy.decision(for: "https://EXAMPLE.com:8443/login")
        XCTAssertEqual(decision?.display, "https://example.com:8443")

        let defaultPort = URIOpeningPolicy.decision(for: "https://example.com:443/x")
        XCTAssertEqual(defaultPort?.display, "https://example.com")
    }

    func testWhitespaceIsTrimmedBeforeParsing() {
        let decision = URIOpeningPolicy.decision(for: "  https://example.com  ")
        XCTAssertEqual(decision?.display, "https://example.com")
    }
}
