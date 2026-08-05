import XCTest
@testable import VaultSquire

final class VaultwardenEnvironmentTests: XCTestCase {
    // ENV-01: base URL with/without trailing slash and path prefix -> correct
    // service URLs, no double slash.
    func testServiceURLsForRootHostedServer() throws {
        let environment = try VaultwardenEnvironment(configuredURL: "https://vault.example.com/")

        XCTAssertEqual(environment.apiURL.absoluteString, "https://vault.example.com/api")
        XCTAssertEqual(environment.identityURL.absoluteString, "https://vault.example.com/identity")
        XCTAssertEqual(environment.notificationsURL.absoluteString, "https://vault.example.com/notifications")
        XCTAssertEqual(environment.redirectBasePath, "/")
    }

    func testPathPrefixAndPortArePreserved() throws {
        let environment = try VaultwardenEnvironment(
            configuredURL: "https://host.example.com:8443/vault/"
        )

        XCTAssertEqual(
            environment.apiURL.absoluteString,
            "https://host.example.com:8443/vault/api"
        )
        XCTAssertEqual(environment.origin.port, 8443)
        XCTAssertEqual(environment.basePathPrefix, "/vault")
        XCTAssertEqual(environment.redirectBasePath, "/vault/")
    }

    func testNoDoubleSlashRegardlessOfTrailingSlash() throws {
        let withSlash = try VaultwardenEnvironment(configuredURL: "https://a.example.com/p/")
        let withoutSlash = try VaultwardenEnvironment(configuredURL: "https://a.example.com/p")

        XCTAssertEqual(withSlash.apiURL, withoutSlash.apiURL)
        XCTAssertFalse(withSlash.apiURL.absoluteString.contains("//api"))
    }

    // ENV-02: HTTP URL outside dev mode -> rejected before credentials.
    func testHTTPRejectedByDefault() {
        XCTAssertThrowsError(
            try VaultwardenEnvironment(configuredURL: "http://vault.example.com")
        ) { error in
            XCTAssertEqual(error as? VaultwardenEnvironmentError, .schemeNotHTTPS)
        }
    }

    func testHTTPLoopbackAllowedOnlyInDevMode() throws {
        XCTAssertThrowsError(
            try VaultwardenEnvironment(configuredURL: "http://localhost:8080")
        )
        let dev = try VaultwardenEnvironment(
            configuredURL: "http://localhost:8080",
            allowInsecureLoopback: true
        )
        XCTAssertEqual(dev.origin.host, "localhost")
        XCTAssertEqual(dev.origin.port, 8080)
    }

    func testUserInfoQueryAndFragmentAreRejected() {
        XCTAssertThrowsError(
            try VaultwardenEnvironment(configuredURL: "https://user:pw@vault.example.com")
        ) { XCTAssertEqual($0 as? VaultwardenEnvironmentError, .userInfoNotAllowed) }
        XCTAssertThrowsError(
            try VaultwardenEnvironment(configuredURL: "https://vault.example.com/?x=1")
        ) { XCTAssertEqual($0 as? VaultwardenEnvironmentError, .queryNotAllowed) }
        XCTAssertThrowsError(
            try VaultwardenEnvironment(configuredURL: "https://vault.example.com/#frag")
        ) { XCTAssertEqual($0 as? VaultwardenEnvironmentError, .fragmentNotAllowed) }
    }

    func testUnsupportedSchemeRejected() {
        XCTAssertThrowsError(
            try VaultwardenEnvironment(configuredURL: "ftp://vault.example.com")
        ) { XCTAssertEqual($0 as? VaultwardenEnvironmentError, .unsupportedScheme) }
    }

    // Redirect policy: only same-origin, HTTPS-preserving, within base path.
    func testRedirectPolicyAllowsSameOriginWithinBasePath() throws {
        let environment = try VaultwardenEnvironment(configuredURL: "https://vault.example.com/p")
        let origin = environment.origin
        let base = environment.redirectBasePath

        XCTAssertTrue(origin.permitsRedirect(
            to: URL(string: "https://vault.example.com/p/api/config")!,
            withinBasePath: base
        ))
    }

    func testRedirectPolicyRefusesCrossOriginDowngradeAndPathEscape() throws {
        let environment = try VaultwardenEnvironment(configuredURL: "https://vault.example.com/p")
        let origin = environment.origin
        let base = environment.redirectBasePath

        // Cross-origin host.
        XCTAssertFalse(origin.permitsRedirect(
            to: URL(string: "https://evil.example.com/p/api")!, withinBasePath: base
        ))
        // HTTPS -> HTTP downgrade.
        XCTAssertFalse(origin.permitsRedirect(
            to: URL(string: "http://vault.example.com/p/api")!, withinBasePath: base
        ))
        // Different port.
        XCTAssertFalse(origin.permitsRedirect(
            to: URL(string: "https://vault.example.com:9999/p/api")!, withinBasePath: base
        ))
        // Path-prefix escape.
        XCTAssertFalse(origin.permitsRedirect(
            to: URL(string: "https://vault.example.com/other/api")!, withinBasePath: base
        ))
    }

    func testRedirectHostComparisonIsCaseInsensitive() throws {
        let environment = try VaultwardenEnvironment(configuredURL: "https://Vault.Example.com")
        XCTAssertTrue(environment.origin.permitsRedirect(
            to: URL(string: "https://vault.example.com/api")!,
            withinBasePath: environment.redirectBasePath
        ))
    }
}
