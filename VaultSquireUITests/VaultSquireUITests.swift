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

        selectProvider("Proton Pass", expecting: element("add-account-proton", in: app), in: app)

        // The staged pane collects nothing: no plain or secure fields anywhere
        // in the sheet while Proton Pass is selected.
        XCTAssertEqual(sheet.textFields.count, 0)
        XCTAssertEqual(sheet.secureTextFields.count, 0)

        selectProvider("Vaultwarden", expecting: app.textFields["add-account-url"], in: app)
    }

    /// Selects one provider segment and waits for its content to appear.
    ///
    /// Two defenses, both observed necessary on hosted runners (run
    /// 31336737076): a stray `UserNotificationCenter` dialog can float over
    /// the sheet so a synthesized click lands on the dialog instead of the
    /// segment — dialogs are dismissed before each attempt and the click is
    /// retried until the expected content appears. And macOS exposes a
    /// SwiftUI segmented control differently across releases, so the
    /// plausible queries are tried in order (the radio-button form is the one
    /// macOS 26 uses). A total miss fails with the live hierarchy in the
    /// message.
    @MainActor
    private func selectProvider(
        _ label: String,
        expecting marker: XCUIElement,
        in app: XCUIApplication
    ) {
        for _ in 0..<3 {
            dismissStrayNotificationDialogs()
            let candidates: [XCUIElement] = [
                app.radioButtons[label],
                app.segmentedControls.buttons[label],
                app.buttons[label],
                app.staticTexts[label],
            ]
            guard let segment = candidates.first(where: { $0.waitForExistence(timeout: 1) }) else {
                continue
            }
            segment.click()
            if marker.waitForExistence(timeout: 3) {
                return
            }
        }
        XCTFail(
            "Selecting '\(label)' never presented its content. Hierarchy: \(app.debugDescription)"
        )
    }

    /// Closes any dialog the system notification agent floated over the app,
    /// preferring its close-style button and falling back to Escape.
    @MainActor
    private func dismissStrayNotificationDialogs() {
        let center = XCUIApplication(bundleIdentifier: "com.apple.UserNotificationCenter")
        for _ in 0..<3 {
            let dialog = center.dialogs.firstMatch
            guard dialog.exists else { return }
            let close = dialog.buttons["Close"].exists
                ? dialog.buttons["Close"]
                : dialog.buttons.firstMatch
            if close.exists {
                close.click()
            } else {
                dialog.typeKey(.escape, modifierFlags: [])
            }
            _ = dialog.waitForNonExistence(timeout: 2)
        }
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
