import XCTest

final class VaultSquireUITests: XCTestCase {
    @MainActor
    func testLockedShellIsTheOnlyMainWindow() {
        let app = launchApp()
        defer { app.terminate() }

        XCTAssertTrue(app.otherElements["locked-shell"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["locked-shell-title"].exists)
        XCTAssertEqual(app.windows.count, 1)
    }

    @MainActor
    func testQuickSearchReceivesKeyboardFocusAndEscapeDismissesIt() {
        let app = launchApp()
        defer { app.terminate() }

        app.buttons["open-quick-search"].click()

        let field = app.textFields["quick-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        XCTAssertTrue(app.otherElements["quick-search-locked"].exists)

        field.typeText("synthetic-query")
        XCTAssertEqual(field.value as? String, "synthetic-query")

        field.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 2))
    }

    @MainActor
    func testSettingsOpenWithoutCreatingAnotherMainWindow() {
        let app = launchApp()
        defer { app.terminate() }

        app.buttons["open-settings"].click()

        XCTAssertTrue(app.otherElements["settings-view"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.otherElements["locked-shell"].exists)
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        return app
    }
}
