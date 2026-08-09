import XCTest
@testable import VaultSquire

final class AppModelTests: XCTestCase {
    @MainActor
    func testNewModelIsLocked() {
        let model = AppModel()

        XCTAssertEqual(model.accessState, .locked)
        XCTAssertTrue(model.isLocked)
    }

    @MainActor
    func testLockIsIdempotent() {
        let model = AppModel()

        model.lock()
        model.lock()

        XCTAssertTrue(model.isLocked)
    }

    @MainActor
    func testAccountPresenceStartsUnknownAndRefreshQueriesTheStore() {
        var presence = AppModel.AccountPresence.none
        let model = AppModel(queryAccountPresence: { presence })

        XCTAssertEqual(model.accountPresence, .unknown)
        XCTAssertFalse(model.hasNoAccounts, "unknown must not claim absence")

        model.refreshAccountPresence()
        XCTAssertEqual(model.accountPresence, .none)
        XCTAssertTrue(model.hasNoAccounts)

        presence = .present
        model.refreshAccountPresence()
        XCTAssertEqual(model.accountPresence, .present)
        XCTAssertFalse(model.hasNoAccounts)
    }

    @MainActor
    func testNoteAccountConfiguredMarksPresenceWithoutAStoreQuery() {
        let model = AppModel(queryAccountPresence: {
            XCTFail("noteAccountConfigured must not query the store")
            return .unknown
        })

        model.noteAccountConfigured()

        XCTAssertEqual(model.accountPresence, .present)
        XCTAssertFalse(model.hasNoAccounts)
    }
}
