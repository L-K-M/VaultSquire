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
    func testSecurityLockDismissesAddAccountWithEnteredPassword() {
        let app = launchApp()
        defer { app.terminate() }

        app.buttons["open-add-account"].click()
        let sheet = element("add-account-view", in: app)
        XCTAssertTrue(sheet.waitForExistence(timeout: 2))
        let password = app.secureTextFields["add-account-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 2))
        password.click()
        password.typeText("VSQ-transient-password")

        app.typeKey("l", modifierFlags: [.command, .shift])

        XCTAssertTrue(sheet.waitForNonExistence(timeout: 2))
    }

    @MainActor
    func testAddAccountExposesOnlyVaultwardenWhileCLIGatesAreOpen() {
        let app = launchApp()
        defer { app.terminate() }

        app.buttons["open-add-account"].click()
        let sheet = element("add-account-view", in: app)
        XCTAssertTrue(sheet.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Add Vaultwarden Account"].exists)
        XCTAssertTrue(app.textFields["add-account-url"].exists)
        XCTAssertTrue(app.secureTextFields["add-account-password"].exists)
        XCTAssertFalse(element("add-account-provider", in: app).exists)
        XCTAssertFalse(element("add-account-proton", in: app).exists)
        XCTAssertFalse(element("add-account-onepassword", in: app).exists)
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
