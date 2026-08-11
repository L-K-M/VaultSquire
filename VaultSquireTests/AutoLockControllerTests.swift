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

    /// An installation nobody has configured must report the timeout it is
    /// actually running, not zero, or Settings would offer to change something
    /// away from a value it never showed.
    func testUnconfiguredMinutesReportTheRunningDefault() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let (controller, _, _) = makeController(now: { t0 })
        XCTAssertEqual(
            controller.inactivityMinutes, Int(AutoLockController.defaultInactivityTimeout / 60)
        )
    }

    /// Settings writes through this, and the new timeout has to apply now
    /// rather than at the next launch.
    func testSettingTheTimeoutTakesEffectImmediately() {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let (controller, lockCount, start) = makeController(timeoutMinutes: 60, now: { clock })
        start()

        controller.setInactivityMinutes(5)
        XCTAssertEqual(controller.inactivityMinutes, 5)
        XCTAssertEqual(controller.inactivityTimeout, 5 * 60)

        clock = clock.addingTimeInterval(6 * 60)
        controller.checkInactivity(at: clock)
        XCTAssertEqual(lockCount(), 1, "six idle minutes is past the new five-minute timeout")
    }

    /// Shortening the timeout must not lock retroactively for time already
    /// spent reading under the longer one.
    func testShorteningTheTimeoutRestartsTheClock() {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let (controller, lockCount, start) = makeController(timeoutMinutes: 60, now: { clock })
        start()

        // Fifty idle minutes under the old hour-long timeout …
        clock = clock.addingTimeInterval(50 * 60)
        controller.setInactivityMinutes(5)

        // … does not count against the new five-minute one.
        controller.checkInactivity(at: clock)
        XCTAssertEqual(lockCount(), 0)

        clock = clock.addingTimeInterval(5 * 60)
        controller.checkInactivity(at: clock)
        XCTAssertEqual(lockCount(), 1)
    }

    func testChoosingNeverDisablesOnlyTheIdleClock() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let (controller, lockCount, start) = makeController(timeoutMinutes: 15, now: { t0 })
        start()

        controller.setInactivityMinutes(0)
        XCTAssertFalse(controller.inactivityLockEnabled)
        controller.checkInactivity(at: t0.addingTimeInterval(365 * 24 * 3600))
        XCTAssertEqual(lockCount(), 0)

        controller.systemLockObserved()
        XCTAssertEqual(lockCount(), 1, "the system triggers are not a preference")
    }

    /// Every offered choice has a label, and "never" is the only non-positive
    /// one, so the picker can never show a blank or a negative timeout.
    func testEveryOfferedTimeoutIsSaneAndDistinct() {
        let offered = AutoLockController.offeredInactivityMinutes
        XCTAssertEqual(Set(offered).count, offered.count, "no duplicate choices")
        XCTAssertEqual(offered.filter { $0 <= 0 }, [0], "exactly one 'never', and it is zero")
        XCTAssertTrue(
            offered.contains(Int(AutoLockController.defaultInactivityTimeout / 60)),
            "the running default is one of the choices, or it could never be chosen again"
        )
    }
}
