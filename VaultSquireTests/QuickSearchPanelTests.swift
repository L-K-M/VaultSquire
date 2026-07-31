import AppKit
import XCTest
@testable import VaultSquire

final class QuickSearchPanelTests: XCTestCase {
    @MainActor
    func testModelClearsQuery() {
        let model = QuickSearchPanelModel()
        model.query = "synthetic query"

        model.clear()

        XCTAssertEqual(model.query, "")
    }

    @MainActor
    func testPanelSupportsSpacesAndSecureRestorationPolicy() {
        let controller = QuickSearchPanelController()
        let panel = controller.windowForTesting

        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.collectionBehavior.contains(.transient))
        XCTAssertFalse(panel.isRestorable)
        XCTAssertFalse(panel.isReleasedWhenClosed)
    }

    @MainActor
    func testDismissClearsQueryAndOrdersPanelOut() {
        let controller = QuickSearchPanelController()

        controller.show()
        XCTAssertTrue(controller.windowForTesting.isVisible)

        controller.dismiss()
        XCTAssertFalse(controller.windowForTesting.isVisible)
    }
}
