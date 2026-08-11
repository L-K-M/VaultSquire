import XCTest
@testable import VaultSquire

final class OnePasswordCLIVersionGateTests: XCTestCase {
    func testParsesABareVersionToken() {
        XCTAssertEqual(
            OnePasswordCLIVersionGate.parseVersion(from: "2.38.1\n"),
            OnePasswordCLIVersion(raw: "2.38.1")
        )
    }

    func testParsesAVersionEmbeddedInSurroundingText() {
        XCTAssertEqual(
            OnePasswordCLIVersionGate.parseVersion(from: "1Password CLI 2.35.0 (darwin/arm64)"),
            OnePasswordCLIVersion(raw: "2.35.0")
        )
    }

    func testReportsNoVersionWhenTheOutputHasNoToken() {
        XCTAssertNil(OnePasswordCLIVersionGate.parseVersion(from: "command not found"))
    }

    func testAdmitsAnAllowlistedVersion() throws {
        let gate = OnePasswordCLIVersionGate(supportedVersions: ["2.38.1"])
        XCTAssertNoThrow(try gate.admit(OnePasswordCLIVersion(raw: "2.38.1")))
    }

    func testRejectsAVersionOutsideTheAllowlist() {
        let gate = OnePasswordCLIVersionGate(supportedVersions: ["2.38.1"])
        XCTAssertThrowsError(try gate.admit(OnePasswordCLIVersion(raw: "2.39.0"))) { error in
            XCTAssertEqual(
                error as? OnePasswordCLIVersionGateError, .unsupportedVersion("2.39.0")
            )
        }
    }

    func testAnEmptyAllowlistAdmitsNothing() {
        let gate = OnePasswordCLIVersionGate(supportedVersions: [])
        XCTAssertThrowsError(try gate.admit(OnePasswordCLIVersion(raw: "2.38.1")))
    }

    /// The gate's whole job is to keep untested builds out, and a beta is an
    /// untested build. Parsing must keep the pre-release suffix so
    /// `2.38.1-beta.01` is compared as itself: stripping the suffix would let a
    /// beta inherit the allowlisted stable `2.38.1`'s admission.
    func testABetaIsNotAdmittedByTheStableItIsNamedAfter() {
        let parsed = OnePasswordCLIVersionGate.parseVersion(from: "2.38.1-beta.01")
        XCTAssertEqual(parsed, OnePasswordCLIVersion(raw: "2.38.1-beta.01"))

        let gate = OnePasswordCLIVersionGate(supportedVersions: ["2.38.1"])
        XCTAssertThrowsError(try gate.admit(try XCTUnwrap(parsed))) { error in
            XCTAssertEqual(
                error as? OnePasswordCLIVersionGateError,
                .unsupportedVersion("2.38.1-beta.01")
            )
        }
    }

    /// The shipped allowlist must contain only stable CLI 2 releases. A beta's
    /// machine output is not a contract, and CLI 1 has a different command
    /// surface entirely.
    func testTheProductionAllowlistCarriesOnlyStableVersionTwoReleases() {
        let versions = OnePasswordCLIVersionGate.declaredSupportedVersions
        XCTAssertFalse(versions.isEmpty)
        for version in versions {
            XCTAssertFalse(
                version.contains("-"),
                "\(version) looks like a pre-release and must not be allowlisted"
            )
            XCTAssertTrue(
                version.hasPrefix("2."),
                "\(version) is not a CLI 2 release"
            )
            // Every entry must survive its own parser, or the gate could never
            // match the binary's reported token.
            XCTAssertEqual(
                OnePasswordCLIVersionGate.parseVersion(from: version),
                OnePasswordCLIVersion(raw: version)
            )
        }
    }

    func testTheProductionGateUsesTheDeclaredAllowlist() {
        XCTAssertEqual(
            OnePasswordCLIVersionGate.production.supportedVersions,
            OnePasswordCLIVersionGate.declaredSupportedVersions
        )
    }
}
