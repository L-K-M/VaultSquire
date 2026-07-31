import XCTest
@testable import VaultSquire

final class AppModelTests: XCTestCase {
    @MainActor
    func testNewModelIsLocked() {
        let model = AppModel()

        XCTAssertEqual(model.accessState, .locked)
        XCTAssertTrue(model.isLocked)
    }

    @MainActor
    func testLockIsIdempotent() {
        let model = AppModel()

        model.lock()
        model.lock()

        XCTAssertTrue(model.isLocked)
    }
}
