import XCTest
@testable import VaultSquire

/// The clipboard contract (SECURITY_AND_TESTING.md §"Clipboard"): a copied
/// secret expires after a short lifetime and is cleared on lock and
/// termination, but only while the pasteboard still holds the value this app
/// wrote — a later user copy is never erased, and the pasteboard is never read
/// back to prove ownership.
@MainActor
final class ClipboardValueControllerTests: XCTestCase {
    /// An in-memory pasteboard that changes its change count on every write,
    /// exactly like the real one.
    private final class RecordingPasteboard: PasteboardWriting, @unchecked Sendable {
        var value: String?
        private(set) var changeCount = 0

        func replaceContents(with value: String) -> Int {
            self.value = value
            changeCount += 1
            return changeCount
        }

        func currentChangeCount() -> Int {
            changeCount
        }

        func clearContents() {
            value = nil
            changeCount += 1
        }
    }

    /// A scheduler that captures expiries instead of running real timers, so a
    /// test can fire them exactly when it wants.
    private final class TestScheduler: @unchecked Sendable {
        var pending: [(@MainActor () -> Void, TimeInterval)] = []

        func makeSchedule() -> @Sendable (@escaping @MainActor () -> Void, TimeInterval) -> Void {
            { [weak self] closure, delay in
                self?.pending.append((closure, delay))
            }
        }

        func fireAll() {
            let scheduled = pending
            pending = []
            for (closure, _) in scheduled {
                closure()
            }
        }
    }

    private func makeController(
        pasteboard: RecordingPasteboard,
        scheduler: TestScheduler
    ) -> ClipboardValueController {
        ClipboardValueController(
            pasteboard: pasteboard,
            schedule: scheduler.makeSchedule()
        )
    }

    func testExpiringCopyIsClearedWhenItsLifetimeEnds() {
        let pasteboard = RecordingPasteboard()
        let scheduler = TestScheduler()
        let controller = makeController(pasteboard: pasteboard, scheduler: scheduler)

        controller.copy("VSQ-Canary-secret", expires: true)
        XCTAssertEqual(pasteboard.value, "VSQ-Canary-secret")

        scheduler.fireAll()
        XCTAssertNil(pasteboard.value, "an expired secret must be cleared")
    }

    func testNonExpiringCopySurvivesTheScheduledClear() {
        let pasteboard = RecordingPasteboard()
        let scheduler = TestScheduler()
        let controller = makeController(pasteboard: pasteboard, scheduler: scheduler)

        controller.copy("VSQ-Canary-username", expires: false)
        scheduler.fireAll()
        XCTAssertEqual(pasteboard.value, "VSQ-Canary-username")
    }

    func testLaterUserCopyIsNeverErased() {
        let pasteboard = RecordingPasteboard()
        let scheduler = TestScheduler()
        let controller = makeController(pasteboard: pasteboard, scheduler: scheduler)

        controller.copy("VSQ-Canary-secret", expires: true)
        // The user copies something else; the change count moves on.
        pasteboard.replaceContents(with: "mine")
        scheduler.fireAll()
        XCTAssertEqual(pasteboard.value, "mine", "a user copy must never be erased")
    }

    func testClearIfOwnedClearsWhileTheValueIsStillOurs() {
        let pasteboard = RecordingPasteboard()
        let scheduler = TestScheduler()
        let controller = makeController(pasteboard: pasteboard, scheduler: scheduler)

        controller.copy("VSQ-Canary-secret", expires: true)
        controller.clearIfOwned()
        XCTAssertNil(pasteboard.value)
    }

    func testClearIfOwnedLeavesAUserCopyAlone() {
        let pasteboard = RecordingPasteboard()
        let scheduler = TestScheduler()
        let controller = makeController(pasteboard: pasteboard, scheduler: scheduler)

        controller.copy("VSQ-Canary-secret", expires: true)
        pasteboard.replaceContents(with: "mine")
        controller.clearIfOwned()
        XCTAssertEqual(pasteboard.value, "mine")
    }

    func testOlderCopyExpiryDoesNotClearANewerSecret() {
        let pasteboard = RecordingPasteboard()
        let scheduler = TestScheduler()
        let controller = makeController(pasteboard: pasteboard, scheduler: scheduler)

        controller.copy("VSQ-Canary-old", expires: true)
        controller.copy("VSQ-Canary-new", expires: true)
        // The first copy's lifetime ends while the second is still fresh.
        scheduler.pending = [scheduler.pending[0]]
        scheduler.fireAll()
        XCTAssertEqual(pasteboard.value, "VSQ-Canary-new")
    }
}
