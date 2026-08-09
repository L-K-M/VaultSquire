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
    func testAddAccountOpensAsASheetWithoutASecondWindow() {
        let app = launchApp()
        defer { app.terminate() }

        app.buttons["open-add-account"].click()

        XCTAssertTrue(element("add-account-view", in: app).waitForExistence(timeout: 2))
        // The sign-in form rendered its fields and primary action.
        XCTAssertTrue(app.buttons["add-account-submit"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.textFields["add-account-url"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.secureTextFields["add-account-password"].waitForExistence(timeout: 2))
        // The flow is a sheet over the single main window, so the locked shell
        // is never duplicated. Wait for it to settle before counting.
        let shells = app.descendants(matching: .any).matching(identifier: "locked-shell")
        XCTAssertTrue(shells.firstMatch.waitForExistence(timeout: 2))
        XCTAssertEqual(shells.count, 1)
    }

    @MainActor
    func testAddAccountListsProtonPassAsStagedWithoutCredentialFields() {
        let app = launchApp()
        defer { app.terminate() }

        app.buttons["open-add-account"].click()
        let sheet = element("add-account-view", in: app)
        XCTAssertTrue(sheet.waitForExistence(timeout: 2))

        // The provider choice defaults to Vaultwarden with its form visible.
        XCTAssertTrue(app.textFields["add-account-url"].waitForExistence(timeout: 2))

        clickProviderSegment("Proton Pass", in: app)

        XCTAssertTrue(element("add-account-proton", in: app).waitForExistence(timeout: 3))
        // The staged pane collects nothing: no plain or secure fields anywhere
        // in the sheet while Proton Pass is selected.
        XCTAssertEqual(sheet.textFields.count, 0)
        XCTAssertEqual(sheet.secureTextFields.count, 0)

        clickProviderSegment("Vaultwarden", in: app)
        XCTAssertTrue(app.textFields["add-account-url"].waitForExistence(timeout: 3))
    }

    /// Clicks one segment of the provider picker. macOS exposes a SwiftUI
    /// segmented control differently across releases (radio buttons in a radio
    /// group, a segmented control with child buttons, or plain buttons), so
    /// the plausible queries are tried in order; a total miss fails with the
    /// live hierarchy so the real shape is in the log.
    @MainActor
    private func clickProviderSegment(_ label: String, in app: XCUIApplication) {
        let candidates: [XCUIElement] = [
            app.radioButtons[label],
            app.segmentedControls.buttons[label],
            app.buttons[label],
            app.staticTexts[label],
        ]
        for candidate in candidates where candidate.waitForExistence(timeout: 1) {
            candidate.click()
            return
        }
        XCTFail(
            "No provider segment matched '\(label)'. Hierarchy: \(app.debugDescription)"
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
