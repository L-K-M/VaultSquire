import XCTest

final class VaultSquireUITests: XCTestCase {
    @MainActor
    func testLockedShellIsTheOnlyMainWindow() {
        let app = launchApp()
        defer { app.terminate() }

        XCTAssertTrue(element("locked-shell", in: app).waitForExistence(timeout: 2))
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
        XCTAssertTrue(element("quick-search-locked", in: app).exists)

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

        XCTAssertTrue(element("settings-view", in: app).waitForExistence(timeout: 2))
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "locked-shell").count,
            1
        )
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
