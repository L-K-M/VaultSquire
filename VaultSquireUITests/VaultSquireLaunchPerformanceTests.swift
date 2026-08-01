import XCTest

final class VaultSquireLaunchPerformanceTests: XCTestCase {
    @MainActor
    func testColdLaunchToResponsiveLockedShell() {
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)]) {
            let app = XCUIApplication()
            app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
            app.launch()
        }
    }
}
