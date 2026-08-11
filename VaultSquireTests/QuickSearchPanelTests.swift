import AppKit
import XCTest
@testable import VaultSquire

final class QuickSearchPanelTests: XCTestCase {
    /// Records the item the panel model asked to open.
    private final class OpenRecorder {
        var opened: [VaultItemID] = []
    }

    /// A presented model with `itemCount` synthetic results, plus a recorder
    /// for its open requests.
    @MainActor
    private func makePanelModel(
        itemCount: Int
    ) -> (QuickSearchPanelModel, OpenRecorder) {
        let account = AccountID(provider: .vaultwarden, rawValue: "quick-search-test")
        let space = VaultSpaceID(account: account, scope: .personal)
        let items = (0..<itemCount).map { index in
            VaultItemProjection(
                id: VaultItemID(space: space, rawValue: "item-\(index)"),
                displayTitle: "Item \(index)",
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
        let recorder = OpenRecorder()
        let model = QuickSearchPanelModel()
        model.present(items: items, isUnlocked: true) { recorder.opened.append($0) }
        return (model, recorder)
    }

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

    // MARK: - Keyboard selection

    @MainActor
    func testPresentationHighlightsTheTopResult() {
        let (model, _) = makePanelModel(itemCount: 3)
        XCTAssertEqual(model.selection, model.results.first?.id)
    }

    @MainActor
    func testArrowMovementClampsAtBothEnds() {
        let (model, _) = makePanelModel(itemCount: 3)

        model.moveSelection(by: -1)
        XCTAssertEqual(model.selection, model.results[0].id, "up from the top stays at the top")

        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selection, model.results[2].id)

        model.moveSelection(by: 1)
        XCTAssertEqual(model.selection, model.results[2].id, "down from the bottom stays at the bottom")
    }

    @MainActor
    func testTypingResetsTheHighlightToTheTopMatch() {
        let (model, _) = makePanelModel(itemCount: 3)
        model.moveSelection(by: 1)

        model.query = "Item 2"

        XCTAssertEqual(model.results.count, 1)
        XCTAssertEqual(model.selection, model.results.first?.id)
    }

    @MainActor
    func testReturnOpensTheHighlightedResult() {
        let (model, recorder) = makePanelModel(itemCount: 3)
        model.moveSelection(by: 1)

        let opened = model.openSelectionOrFirst()

        XCTAssertEqual(opened, model.results[1].id)
        XCTAssertEqual(recorder.opened, [model.results[1].id])
    }

    @MainActor
    func testReturnWithNoResultsOpensNothing() {
        let (model, recorder) = makePanelModel(itemCount: 0)

        XCTAssertNil(model.openSelectionOrFirst())
        XCTAssertTrue(recorder.opened.isEmpty)
    }
}
