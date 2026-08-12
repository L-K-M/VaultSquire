import AppKit
import Foundation

/// Locks every vault when the Mac is no longer under the user's active
/// control, and after a configurable period without input.
///
/// `SECURITY_AND_TESTING.md` requires lock on configured inactivity, screen
/// lock, screensaver start, session resignation, system sleep, and explicit
/// command; the explicit command lives in the menu and toolbar, and this
/// controller supplies the rest. Every trigger runs the same lock closure the
/// toolbar uses, so system lock, sleep, and inactivity also cancel tracked
/// sync/CLI work and drop the clipboard secret through `AppModel.lock()`.
///
/// The inactivity clock watches input events delivered to this application.
/// When the app is not focused no events arrive, so the timeout fires on
/// schedule — the standard password-manager behavior of locking while the
/// user reads without touching anything is intentional.
@MainActor
final class AutoLockController {
    /// The app's controller, started from the root scene with the shell's
    /// lock-everything action. Tests construct isolated instances.
    static let shared = AutoLockController()

    /// User defaults key for the inactivity timeout, in minutes. Absent means
    /// the default; a value of 0 or less disables the inactivity trigger (the
    /// system-event triggers always apply).
    static let inactivityMinutesKey = "VaultSquire.autoLockMinutes"
    static let defaultInactivityTimeout: TimeInterval = 15 * 60

    /// The timeouts Settings offers, in minutes. `0` is the explicit "never"
    /// that disables the idle clock; the system triggers — screen lock,
    /// screensaver, sleep, session resignation — always apply and are not
    /// offered as a choice, because they are what makes an unattended Mac safe.
    static let offeredInactivityMinutes = [1, 5, 15, 30, 60, 0]

    /// Distributed notification names for the screen lock and screensaver
    /// triggers. macOS publishes no public constants for these.
    static let screenIsLockedNotification = "com.apple.screenIsLocked"
    static let screensaverDidStartNotification = "com.apple.screensaver.didstart"

    private let defaults: UserDefaults
    private let now: @MainActor () -> Date
    private var onLock: (@MainActor () -> Void)?

    private var distributedObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var inactivityTask: Task<Void, Never>?
    private var lastActivity: Date
    private var started = false

    init(
        defaults: UserDefaults = .standard,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.now = now
        self.lastActivity = now()
    }

    /// The configured inactivity timeout in seconds. Only meaningful when
    /// `inactivityLockEnabled` is true.
    var inactivityTimeout: TimeInterval {
        let minutes = defaults.double(forKey: Self.inactivityMinutesKey)
        return minutes > 0 ? minutes * 60 : Self.defaultInactivityTimeout
    }

    /// Whether the inactivity trigger is on. Absent means on; an explicitly
    /// configured non-positive value disables it. System events still lock.
    var inactivityLockEnabled: Bool {
        guard defaults.object(forKey: Self.inactivityMinutesKey) != nil else { return true }
        return defaults.double(forKey: Self.inactivityMinutesKey) > 0
    }

    /// The configured timeout in whole minutes, for Settings to show and set.
    /// `0` means the idle clock is off. Absent reads as the default rather than
    /// as zero, so an installation that has never been configured reports the
    /// timeout it is actually running.
    var inactivityMinutes: Int {
        guard defaults.object(forKey: Self.inactivityMinutesKey) != nil else {
            return Int(Self.defaultInactivityTimeout / 60)
        }
        // Rounded, not truncated. A stored 0.5 truncates to 0, which would show
        // "Never" in Settings while `inactivityLockEnabled` is still true and
        // the vault really locks after thirty seconds — a display that
        // contradicts the behaviour in the direction that makes someone think
        // they are less protected than they are.
        return max(0, Int(defaults.double(forKey: Self.inactivityMinutesKey).rounded()))
    }

    /// Stores a new timeout and restarts the idle clock, so the choice takes
    /// effect now rather than at the next launch. The clock restarts from this
    /// moment: shortening the timeout must not lock the vault retroactively for
    /// time the user spent reading under the old one.
    func setInactivityMinutes(_ minutes: Int) {
        defaults.set(Double(max(0, minutes)), forKey: Self.inactivityMinutesKey)
        lastActivity = now()
        armInactivityCheck()
    }

    /// Installs the lock closure and starts watching. Idempotent: calling
    /// again replaces the lock closure without doubling the observers.
    func start(onLock: @escaping @MainActor () -> Void) {
        self.onLock = onLock
        guard !started else { return }
        started = true

        let center = DistributedNotificationCenter.default()
        for name in [Self.screenIsLockedNotification, Self.screensaverDidStartNotification] {
            let observer = center.addObserver(
                forName: NSNotification.Name(name),
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.systemLockObserved()
                }
            }
            distributedObservers.append(observer)
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            let observer = workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.systemLockObserved()
                }
            }
            workspaceObservers.append(observer)
        }

        // Any input aimed at this app counts as activity. The monitor only
        // observes; it never consumes the event.
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved]
        ) { [weak self] event in
            // A local monitor is called on the main thread as part of event
            // dispatch, so the activity note is taken inline. Hopping through a
            // Task would allocate one per event, and `.mouseMoved` alone
            // delivers those continuously while the pointer is over the window.
            MainActor.assumeIsolated {
                self?.noteActivity()
            }
            return event
        }

        armInactivityCheck()
    }

    /// Removes every observer and stops the inactivity check. The shared
    /// controller runs for the app's lifetime; this exists for tests.
    func stop() {
        for observer in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        distributedObservers = []
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers = []
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        inactivityTask?.cancel()
        inactivityTask = nil
        started = false
    }

    /// Records input activity, restarting the idle clock.
    func noteActivity() {
        lastActivity = now()
    }

    /// A screen lock, screensaver start, sleep, or session resignation: lock
    /// immediately, without waiting for the inactivity clock.
    func systemLockObserved() {
        onLock?()
    }

    /// Locks when `date` is at least one timeout past the last activity. The
    /// timer calls this with the current time; tests call it directly to drive
    /// the rule without sleeping.
    func checkInactivity(at date: Date) {
        guard inactivityLockEnabled else { return }
        guard date.timeIntervalSince(lastActivity) >= inactivityTimeout else { return }
        // Reset first so a lock that shows a prompt does not re-fire every tick.
        lastActivity = date
        onLock?()
    }

    /// How often the idle clock is examined, derived from the timeout so the
    /// lock lands near its boundary rather than up to a whole timeout late.
    ///
    /// Four checks per timeout, floored at five seconds so the one-minute
    /// choice is honoured to within a few seconds, and capped so the long
    /// timeouts still wake at most once a minute. Exposed for the test that
    /// pins this relationship; a fixed one-minute poll would let the shortest
    /// offered timeout overrun by a further full minute.
    var inactivityCheckInterval: TimeInterval {
        min(max(5, inactivityTimeout / 4), max(60, inactivityTimeout / 2))
    }

    private func armInactivityCheck() {
        inactivityTask?.cancel()
        inactivityTask = nil
        // `started` matters now that `setInactivityMinutes` can reach this from
        // Settings: without it, a controller that was never started would spawn
        // a poll that runs for the object's lifetime checking against a nil
        // lock closure.
        guard started, inactivityLockEnabled else { return }
        let interval = inactivityCheckInterval
        inactivityTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.checkInactivity(at: self.now())
            }
        }
    }
}
