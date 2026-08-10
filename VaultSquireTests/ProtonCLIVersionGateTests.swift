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

    func testProductionGateAdmitsADeclaredVersion() throws {
        // The shipped gate admits the researched releases and nothing outside
        // them, so a real install on a supported version is not gated off.
        XCTAssertNoThrow(try ProtonCLIVersionGate.production.admit(ProtonCLIVersion(raw: "2.2.4")))
        XCTAssertThrowsError(try ProtonCLIVersionGate.production.admit(ProtonCLIVersion(raw: "9.9.9")))
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

    func testReturnsNilWhenNoVersionTokenIsPresent() {
        XCTAssertNil(ProtonCLIVersionGate.parseVersion(from: "no version here"))
        XCTAssertNil(ProtonCLIVersionGate.parseVersion(from: "2.2"))
    }
}
