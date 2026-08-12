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
                // A fixed name. The chord that could not be registered is not
                // part of it — the event says a registration failed, never
                // which keys the user chose.
                "quick-search.hotkey-unavailable",
                "quick-search.presented",
                "vault.locked"
            ]
        )
    }
}
