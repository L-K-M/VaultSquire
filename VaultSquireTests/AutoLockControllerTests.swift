import XCTest
@testable import VaultSquire

/// The auto-lock rules: system lock events lock immediately, inactivity locks
/// only after the configured idle period, and input resets the idle clock.
@MainActor
final class AutoLockControllerTests: XCTestCase {
    private final class LockCounter {
        var count = 0
    }

    /// Builds a controller with an isolated defaults suite and injected clock,
    /// plus a counter that records how often the lock closure ran.
    private func makeController(
        timeoutMinutes: Double? = nil,
        now: @escaping @MainActor () -> Date
    ) -> (controller: AutoLockController, lockCount: () -> Int, start: () -> Void) {
        let suite = "VSQ-autolock-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        if let timeoutMinutes {
            defaults.set(timeoutMinutes, forKey: AutoLockController.inactivityMinutesKey)
        }
        let controller = AutoLockController(defaults: defaults, now: now)
        let counter = LockCounter()
        addTeardownBlock {
            // The controller's observers and timer all capture it weakly, so
            // releasing it leaves nothing that can fire; only the isolated
            // defaults suite needs cleanup.
            defaults.removePersistentDomain(forName: suite)
        }
        return (
            controller,
            { counter.count },
            { controller.start(onLock: { counter.count += 1 }) }
        )
    }

    func testSystemLockObservedLocksImmediately() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let (controller, lockCount, start) = makeController(now: { t0 })
        start()
        controller.systemLockObserved()
        XCTAssertEqual(lockCount(), 1)
        controller.systemLockObserved()
        XCTAssertEqual(lockCount(), 2, "every system lock event locks, idempotently")
    }

    func testInactivityLocksOnlyAfterTheTimeout() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let (controller, lockCount, start) = makeController(timeoutMinutes: 15, now: { t0 })
        start()

        controller.checkInactivity(at: t0.addingTimeInterval(14 * 60))
        XCTAssertEqual(lockCount(), 0, "fourteen idle minutes is inside the timeout")

        controller.checkInactivity(at: t0.addingTimeInterval(15 * 60))
        XCTAssertEqual(lockCount(), 1, "the timeout boundary locks")
    }

    func testActivityResetsTheIdleClock() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var current = t0
        let (controller, lockCount, start) = makeController(timeoutMinutes: 15, now: { current })
        start()

        current = t0.addingTimeInterval(14 * 60)
        controller.noteActivity()
        current = t0.addingTimeInterval(28 * 60)
        controller.checkInactivity(at: current)
        XCTAssertEqual(lockCount(), 0, "activity restarted the clock")

        current = t0.addingTimeInterval(44 * 60)
        controller.checkInactivity(at: current)
        XCTAssertEqual(lockCount(), 1)
    }

    func testAfterFiringTheClockRestartsInsteadOfRefiringEveryTick() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let (controller, lockCount, start) = makeController(timeoutMinutes: 15, now: { t0 })
        start()

        controller.checkInactivity(at: t0.addingTimeInterval(20 * 60))
        XCTAssertEqual(lockCount(), 1)
        controller.checkInactivity(at: t0.addingTimeInterval(21 * 60))
        XCTAssertEqual(lockCount(), 1, "a fired check re-arms rather than firing every tick")
    }

    func testAConfiguredNonPositiveTimeoutDisablesOnlyInactivity() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let (controller, lockCount, start) = makeController(timeoutMinutes: 0, now: { t0 })
        start()

        controller.checkInactivity(at: t0.addingTimeInterval(365 * 24 * 3600))
        XCTAssertEqual(lockCount(), 0, "inactivity is disabled")

        controller.systemLockObserved()
        XCTAssertEqual(lockCount(), 1, "system lock events still lock")
    }

    func testDefaultTimeoutAppliesWhenNothingIsConfigured() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let (controller, _, _) = makeController(now: { t0 })
        XCTAssertEqual(controller.inactivityTimeout, AutoLockController.defaultInactivityTimeout)
        XCTAssertTrue(controller.inactivityLockEnabled)
    }

    /// The Settings picker writes the defaults key and calls `reloadPolicy`;
    /// the new timeout must govern without a relaunch.
    func testReloadPolicyAppliesAChangedTimeoutWithoutRestart() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let suite = "VSQ-autolock-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(15.0, forKey: AutoLockController.inactivityMinutesKey)
        let controller = AutoLockController(defaults: defaults, now: { t0 })
        let counter = LockCounter()
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        controller.start(onLock: { counter.count += 1 })

        controller.checkInactivity(at: t0.addingTimeInterval(5 * 60))
        XCTAssertEqual(counter.count, 0, "five idle minutes is inside the original timeout")

        defaults.set(1.0, forKey: AutoLockController.inactivityMinutesKey)
        controller.reloadPolicy()
        controller.checkInactivity(at: t0.addingTimeInterval(5 * 60))
        XCTAssertEqual(counter.count, 1, "the reloaded one-minute timeout applies immediately")
    }
}
