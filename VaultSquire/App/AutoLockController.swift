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
            Task { @MainActor [weak self] in
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

    private func armInactivityCheck() {
        inactivityTask?.cancel()
        inactivityTask = nil
        guard inactivityLockEnabled else { return }
        // Check at least twice per timeout so the lock lands close to the
        // boundary rather than a whole timeout late, but never more often
        // than once a minute.
        let interval = max(60, inactivityTimeout / 2)
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
