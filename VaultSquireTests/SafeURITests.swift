import XCTest
@testable import VaultSquire

/// Exercises the URI-opening allowlist in SECURITY_AND_TESTING.md § "URI Opening":
/// only parsed http/https destinations with a host and no credentials are
/// openable; file/javascript/data/custom schemes and embedded credentials are
/// refused and render as inert text.
final class SafeURITests: XCTestCase {
    func testHTTPSandBareHostResolve() {
        let https = SafeURI.destination(for: "https://github.com/secret/repo")
        XCTAssertEqual(https?.scheme, "https")
        XCTAssertEqual(https?.host, "github.com")

        // A bare host is treated as https.
        let bare = SafeURI.destination(for: "github.com")
        XCTAssertEqual(bare?.scheme, "https")
        XCTAssertEqual(bare?.host, "github.com")
    }

    func testHTTPPermittedSoUserSeesSchemeBeforeOpening() {
        let http = SafeURI.destination(for: "http://insecure.example.com")
        XCTAssertEqual(http?.scheme, "http")
        XCTAssertEqual(http?.host, "insecure.example.com")
    }

    func testCustomAndDangerousSchemesRefused() {
        // Each of these must NOT be openable: a click must never hand them to
        // NSWorkspace.
        for raw in [
            "javascript:alert(1)",
            "file:///etc/passwd",
            "data:text/html,<script>alert(1)</script>",
            "mailto:foo@example.com",
            "ftp://example.com",
            "myapp://scheme/attack",
            "vbscript:msgbox"
        ] {
            XCTAssertNil(
                SafeURI.destination(for: raw),
                "expected '\(raw)' to be refused an open destination"
            )
        }
    }

    func testEmbeddedCredentialsRefused() {
        XCTAssertNil(SafeURI.destination(for: "https://user:pass@example.com"))
        XCTAssertNil(SafeURI.destination(for: "https://user@example.com"))
    }

    func testHostlessAndEmptyRefused() {
        for raw in ["", "   ", "https://", "https:///path-only", "not a url at all"] {
            XCTAssertNil(
                SafeURI.destination(for: raw),
                "expected '\(raw)' to be refused an open destination"
            )
        }
    }

    func testExplicitNonHTTPSchemePrefixIsNotReadAsHost() {
        // `javascript:alert(1)` must not be reparsed into an https:// host.
        XCTAssertNil(SafeURI.destination(for: "javascript:alert(1)"))
        // A leading digit is not a scheme, so `8080:foo` is scheme-less and
        // becomes a (dotless, refused) host — but never scheme `8080`.
        XCTAssertNil(SafeURI.destination(for: "8080:foo"))
    }

    func testTrimmedInput() {
        let destination = SafeURI.destination(for: "   https://example.com   ")
        XCTAssertEqual(destination?.scheme, "https")
        XCTAssertEqual(destination?.host, "example.com")
    }
}
