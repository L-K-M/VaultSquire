import XCTest
@testable import VaultSquire

/// The URI opening policy (SECURITY_AND_TESTING.md §"URI Opening"): only
/// parsed http/https destinations may ever be handed to the system URL opener;
/// credentials, privileged schemes, and arbitrary custom schemes are refused.
final class VaultURIPolicyTests: XCTestCase {
    func testAllowsHTTPSWithPath() {
        XCTAssertEqual(
            VaultItemDetailView.safeLinkURL(from: "https://example.com/login")?.absoluteString,
            "https://example.com/login"
        )
    }

    func testAllowsPlainHTTP() {
        XCTAssertEqual(
            VaultItemDetailView.safeLinkURL(from: "http://example.com")?.absoluteString,
            "http://example.com"
        )
    }

    func testBareDomainIsCompletedToHTTPS() {
        XCTAssertEqual(
            VaultItemDetailView.safeLinkURL(from: "github.com")?.absoluteString,
            "https://github.com"
        )
    }

    func testWhitespaceAroundURLIsTrimmed() {
        XCTAssertEqual(
            VaultItemDetailView.safeLinkURL(from: "  https://example.com  ")?.absoluteString,
            "https://example.com"
        )
    }

    func testRejectsFileScheme() {
        XCTAssertNil(VaultItemDetailView.safeLinkURL(from: "file:///etc/passwd"))
    }

    func testRejectsJavascriptScheme() {
        XCTAssertNil(VaultItemDetailView.safeLinkURL(from: "javascript:alert(1)"))
        XCTAssertNil(VaultItemDetailView.safeLinkURL(from: "javascript://example.com/x"))
    }

    func testRejectsDataScheme() {
        XCTAssertNil(VaultItemDetailView.safeLinkURL(from: "data:text/html,<script>1</script>"))
    }

    func testRejectsCustomSchemes() {
        XCTAssertNil(VaultItemDetailView.safeLinkURL(from: "ssh://host"))
        XCTAssertNil(VaultItemDetailView.safeLinkURL(from: "slack://channel"))
        XCTAssertNil(VaultItemDetailView.safeLinkURL(from: "x-apple.systempreferences:com.apple.preferences"))
    }

    func testRejectsEmbeddedCredentials() {
        XCTAssertNil(VaultItemDetailView.safeLinkURL(from: "https://user:pass@example.com"))
        XCTAssertNil(VaultItemDetailView.safeLinkURL(from: "https://user@example.com"))
    }

    func testRejectsEmptyAndBlankValues() {
        XCTAssertNil(VaultItemDetailView.safeLinkURL(from: ""))
        XCTAssertNil(VaultItemDetailView.safeLinkURL(from: "   "))
    }

    func testRejectsSchemeWithoutHost() {
        XCTAssertNil(VaultItemDetailView.safeLinkURL(from: "https:///just/a/path"))
    }

    func testLinkLabelShowsHostAndPort() {
        XCTAssertEqual(
            VaultItemDetailView.linkLabel(for: URL(string: "https://example.com/path")!),
            "example.com"
        )
        XCTAssertEqual(
            VaultItemDetailView.linkLabel(for: URL(string: "https://example.com:8443/path")!),
            "example.com:8443"
        )
    }
}
