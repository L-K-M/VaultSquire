import XCTest

/// Measures the warm shortcut-to-visible Quick Search interval against the signpost
/// the application emits.
///
/// This lives in the UI test target on purpose. The interval is opened by
/// `ApplicationCoordinator.showQuickSearch()` and closed by
/// `QuickSearchPanelController.show()`, so only a fixture that drives the real menu
/// or button path produces a matched interval. Measuring from the UI test target
/// also keeps the measured application a plain Release build, because no
/// `@testable` import forces `ENABLE_TESTABILITY` onto the product.
final class VaultSquireQuickSearchPerformanceTests: XCTestCase {
    @MainActor
    func testWarmQuickSearchPresentation() {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate() }

        let openButton = app.buttons["open-quick-search"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 10))

        let field = app.textFields["quick-search-field"]

        // Warm the panel so the measured iterations exclude first-presentation cost,
        // which is the warm budget the plan specifies.
        present(openButton, field: field)
        dismiss(field)

        let metric = XCTOSSignpostMetric(
            subsystem: "ch.lkmc.VaultSquire",
            category: "performance",
            name: "Quick Search Presentation"
        )

        measure(metrics: [metric]) {
            present(openButton, field: field)
            dismiss(field)
        }
    }

    @MainActor
    private func present(_ openButton: XCUIElement, field: XCUIElement) {
        openButton.click()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
    }

    @MainActor
    private func dismiss(_ field: XCUIElement) {
        field.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 10))
    }
}
