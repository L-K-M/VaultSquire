import XCTest
@testable import VaultSquire

final class DiagnosticsTests: XCTestCase {
    func testApplicationLogHasOnlyFixedAllowlistedEvents() {
        XCTAssertEqual(
            Set(AppLogEvent.allCases.map(\.rawValue)),
            [
                "application.did-finish-launching",
                "application.will-terminate",
                "quick-search.dismissed",
                "quick-search.presented",
                "vault.locked"
            ]
        )
    }
}
