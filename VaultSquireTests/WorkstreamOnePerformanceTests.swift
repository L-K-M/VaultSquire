import XCTest
@testable import VaultSquire

final class WorkstreamOnePerformanceTests: XCTestCase {
    @MainActor
    func testWarmQuickSearchPresentation() {
        let controller = QuickSearchPanelController()
        controller.show()
        controller.dismiss()

        let metric = XCTOSSignpostMetric(
            subsystem: "ch.lkmc.VaultSquire",
            category: "performance",
            name: "Quick Search Presentation"
        )

        measure(metrics: [metric]) {
            controller.show()
            controller.dismiss()
        }
    }
}
