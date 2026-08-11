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
    func testClearAlsoDropsSelection() {
        let model = QuickSearchPanelModel()
        model.present(items: makeItems(["a", "b"]), isUnlocked: true, onOpen: nil)
        model.moveSelection(by: 1)
        XCTAssertNotNil(model.selectedIndex)

        model.clear()

        XCTAssertNil(model.selectedIndex)
    }

    @MainActor
    func testArrowDownFromNoSelectionPicksFirstResult() {
        let model = QuickSearchPanelModel()
        model.present(items: makeItems(["a", "b", "c"]), isUnlocked: true, onOpen: nil)

        model.moveSelection(by: 1)

        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.selectedItemID?.rawValue, "a")
    }

    @MainActor
    func testArrowUpFromNoSelectionPicksLastResult() {
        let model = QuickSearchPanelModel()
        model.present(items: makeItems(["a", "b", "c"]), isUnlocked: true, onOpen: nil)

        model.moveSelection(by: -1)

        XCTAssertEqual(model.selectedIndex, 2)
        XCTAssertEqual(model.selectedItemID?.rawValue, "c")
    }

    @MainActor
    func testMoveSelectionClampsToBounds() {
        let model = QuickSearchPanelModel()
        model.present(items: makeItems(["a", "b", "c"]), isUnlocked: true, onOpen: nil)

        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedIndex, 2)

        model.moveSelection(by: -5)
        XCTAssertEqual(model.selectedIndex, 0)
    }

    @MainActor
    func testEnterOpensSelectionWhenPresentOtherwiseFirst() {
        let model = QuickSearchPanelModel()
        model.present(items: makeItems(["a", "b", "c"]), isUnlocked: true, onOpen: nil)

        XCTAssertEqual(model.openOnEnterItemID?.rawValue, "a")

        model.moveSelection(by: 3) // clamp to last
        XCTAssertEqual(model.openOnEnterItemID?.rawValue, "c")
    }

    @MainActor
    func testEnterIsNilWhenThereAreNoResults() {
        let model = QuickSearchPanelModel()
        model.present(items: [], isUnlocked: true, onOpen: nil)

        XCTAssertNil(model.openOnEnterItemID)
    }

    private func makeItems(_ rawValues: [String]) -> [VaultItemProjection] {
        let account = AccountID(provider: .vaultwarden, rawValue: "primary")
        let space = VaultSpaceID(account: account, scope: .personal)
        return rawValues.map {
            VaultItemProjection(
                id: VaultItemID(space: space, rawValue: $0),
                displayTitle: "Title \($0)",
                displaySubtitle: nil,
                category: .login,
                username: nil,
                websites: [],
                groupingLabels: [],
                capabilities: [.viewItems],
                cacheReference: ProviderCacheReference(
                    scope: .wholeAccount(account),
                    captureGeneration: SnapshotGeneration(rawValue: 1)
                )
            )
        }
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

        controller.modelForTesting.query = "synthetic query"
        controller.dismiss()

        XCTAssertFalse(controller.windowForTesting.isVisible)
        XCTAssertEqual(controller.modelForTesting.query, "")
    }

    /// The warm Quick Search signpost interval is opened by the coordinator and
    /// closed by the controller, so the coordinator hop is the measured path. This
    /// keeps the two halves from drifting apart again.
    @MainActor
    func testCoordinatorPresentsAndDismissesTheSamePanel() {
        ApplicationCoordinator.shared.showQuickSearch()

        let panel = ApplicationCoordinator.shared
            .quickSearchControllerForTesting?
            .windowForTesting
        XCTAssertNotNil(panel)
        XCTAssertEqual(panel?.isVisible, true)

        ApplicationCoordinator.shared.dismissQuickSearch()
        XCTAssertEqual(panel?.isVisible, false)
    }
}
