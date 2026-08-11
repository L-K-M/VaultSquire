import AppKit
import XCTest
@testable import VaultSquire

final class QuickSearchPanelTests: XCTestCase {
    @MainActor
    func testModelClearsQuery() {
        let model = QuickSearchPanelModel()
        model.query = "synthetic query"

        model.clearQuery()

        XCTAssertEqual(model.query, "")
    }

    @MainActor
    func testResetReleasesVaultDerivedStateAndCallback() {
        let model = QuickSearchPanelModel()
        var didOpen = false
        let id = VaultItemID(
            space: VaultSpaceID(account: .vaultwardenPrimary, scope: .personal),
            rawValue: "item"
        )
        model.present(items: [], isUnlocked: true, onOpen: { _ in didOpen = true })
        model.query = "synthetic query"

        model.reset()
        model.open(id)

        XCTAssertEqual(model.query, "")
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.isUnlocked)
        XCTAssertFalse(didOpen)
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

final class VaultURLPolicyTests: XCTestCase {
    func testAcceptsOnlyHTTPFamilyURLsWithoutCredentials() {
        XCTAssertEqual(
            VaultURLPolicy.safeURL("example.com/login")?.absoluteString,
            "https://example.com/login"
        )
        XCTAssertEqual(
            VaultURLPolicy.safeURL("http://example.com:8080/path")?.scheme,
            "http"
        )
        XCTAssertNil(VaultURLPolicy.safeURL("javascript:alert(1)"))
        XCTAssertNil(VaultURLPolicy.safeURL("file:///tmp/VSQ-secret"))
        XCTAssertNil(VaultURLPolicy.safeURL("https://user:VSQ-secret@example.com"))
        XCTAssertNil(VaultURLPolicy.safeURL("https://example.com/\nspoof"))
        XCTAssertNil(VaultURLPolicy.safeURL("https://example.com/\u{202E}moc.live"))
    }

    func testConfirmationLabelUsesEffectiveSchemeHostAndPortOnly() throws {
        let url = try XCTUnwrap(VaultURLPolicy.safeURL("http://example.com:8080/a?b=c"))
        XCTAssertEqual(VaultURLPolicy.destinationLabel(url), "http://example.com:8080")
    }
}

final class ClipboardOwnershipTests: XCTestCase {
    @MainActor
    func testLockCleanupDoesNotEraseANewerClipboardValue() {
        let pasteboard = NSPasteboard.general
        ApplicationCoordinator.shared.copyVaultValue("VSQ-owned-secret", concealed: true)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("VSQ-newer-value", forType: .string))

        ApplicationCoordinator.shared.clearOwnedClipboard()

        XCTAssertEqual(pasteboard.string(forType: .string), "VSQ-newer-value")
        pasteboard.clearContents()
    }
}
