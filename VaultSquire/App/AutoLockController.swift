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
    enum InactivityPreference: Int, CaseIterable, Identifiable {
        case oneMinute = 1
        case fiveMinutes = 5
        case fifteenMinutes = 15
        case thirtyMinutes = 30
        case oneHour = 60
        case never = 0

        static let defaultValue: Self = .fifteenMinutes

        var id: Int { rawValue }

        var minutes: Double {
            Double(rawValue)
        }

        var timeout: TimeInterval? {
            guard self != .never else { return nil }
            return minutes * 60
        }

        var title: String {
            switch self {
            case .oneMinute:
                "After 1 minute"
            case .fiveMinutes:
                "After 5 minutes"
            case .fifteenMinutes:
                "After 15 minutes"
            case .thirtyMinutes:
                "After 30 minutes"
            case .oneHour:
                "After 1 hour"
            case .never:
                "Never lock for inactivity"
            }
        }
    }

    /// The app's controller, started from the root scene with the shell's
    /// lock-everything action. Tests construct isolated instances.
    static let shared = AutoLockController()

    /// User defaults key for the inactivity timeout, in minutes. Absent means
    /// the default; a value of 0 or less disables the inactivity trigger (the
    /// system-event triggers always apply).
    static let inactivityMinutesKey = "VaultSquire.autoLockMinutes"
    static let defaultInactivityTimeout: TimeInterval = 15 * 60

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
        inactivityPreference.timeout ?? Self.defaultInactivityTimeout
    }

    /// Whether the inactivity trigger is on. Absent means on; an explicitly
    /// configured non-positive value disables it. System events still lock.
    var inactivityLockEnabled: Bool {
        inactivityPreference != .never
    }

    var inactivityPreference: InactivityPreference {
        guard let value = defaults.object(forKey: Self.inactivityMinutesKey) as? NSNumber else {
            return .defaultValue
        }
        let minutes = value.intValue
        if minutes <= 0 {
            return .never
        }
        return InactivityPreference(rawValue: minutes) ?? .defaultValue
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
            MainActor.assumeIsolated {
                self?.noteActivity()
            }
            return event
        }

        scheduleInactivityCheck()
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
        scheduleInactivityCheck()
    }

    /// Re-applies the stored setting immediately. Shorter timeouts can lock at
    /// once when the current idle period already exceeds the new deadline.
    func preferencesDidChange() {
        checkInactivity(at: now())
        scheduleInactivityCheck()
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

    private func scheduleInactivityCheck() {
        inactivityTask?.cancel()
        inactivityTask = nil
        guard started, let timeout = inactivityPreference.timeout else { return }
        let deadline = lastActivity.addingTimeInterval(timeout)
        let delay = max(0, deadline.timeIntervalSince(now()))
        inactivityTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.checkInactivity(at: self.now())
            self.scheduleInactivityCheck()
        }
    }
}
