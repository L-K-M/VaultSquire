import XCTest
@testable import VaultSquire

final class ProtonCLIVersionGateTests: XCTestCase {
    func testEmptyAllowlistRejectsEveryVersion() {
        let gate = ProtonCLIVersionGate(supportedVersions: [])
        XCTAssertThrowsError(try gate.admit(ProtonCLIVersion(raw: "2.2.4"))) { error in
            XCTAssertEqual(error as? ProtonCLIVersionGateError, .unsupportedVersion("2.2.4"))
        }
    }

    func testAdmitsAnExactlyListedVersion() throws {
        let gate = ProtonCLIVersionGate(supportedVersions: ["2.2.4"])
        XCTAssertNoThrow(try gate.admit(ProtonCLIVersion(raw: "2.2.4")))
    }

    func testRejectsAnUnlistedNeighborVersion() {
        let gate = ProtonCLIVersionGate(supportedVersions: ["2.2.4"])
        XCTAssertThrowsError(try gate.admit(ProtonCLIVersion(raw: "2.2.5"))) { error in
            XCTAssertEqual(error as? ProtonCLIVersionGateError, .unsupportedVersion("2.2.5"))
        }
    }

    func testProductionGateAdmitsNoDocumentationOnlyCandidate() {
        XCTAssertTrue(ProtonCLIVersionGate.production.supportedVersions.isEmpty)
        for candidate in ProtonCLIVersionGate.documentedCandidateVersions {
            XCTAssertThrowsError(
                try ProtonCLIVersionGate.production.admit(ProtonCLIVersion(raw: candidate))
            )
        }
    }

    func testParsesADottedVersionFromNoisyOutput() {
        let version = ProtonCLIVersionGate.parseVersion(from: "proton-pass version 2.2.4 (build abc)\n")
        XCTAssertEqual(version, ProtonCLIVersion(raw: "2.2.4"))
    }

    func testParsesABareVersionToken() {
        XCTAssertEqual(
            ProtonCLIVersionGate.parseVersion(from: "2.2.3"),
            ProtonCLIVersion(raw: "2.2.3")
        )
    }

    func testPrereleaseAndOversizedComponentsCannotMasqueradeAsStable() {
        XCTAssertNil(ProtonCLIVersionGate.parseVersion(from: "2.2.4-beta.1"))
        XCTAssertNil(ProtonCLIVersionGate.parseVersion(from: "1234567890.2.4"))
        XCTAssertThrowsError(
            try ProtonCLIVersionGate(supportedVersions: []).admit(
                ProtonCLIVersion(raw: String(repeating: "9", count: 10_000))
            )
        ) { error in
            XCTAssertEqual(
                error as? ProtonCLIVersionGateError,
                .unsupportedVersion("<invalid>")
            )
        }
    }

    func testReturnsNilWhenNoVersionTokenIsPresent() {
        XCTAssertNil(ProtonCLIVersionGate.parseVersion(from: "no version here"))
        XCTAssertNil(ProtonCLIVersionGate.parseVersion(from: "2.2"))
    }
}
