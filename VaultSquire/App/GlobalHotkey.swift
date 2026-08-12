import AppKit
import Carbon.HIToolbox

/// Registers one system-wide hotkey through Carbon's `RegisterEventHotKey`.
///
/// This is the Apple no-dependency route named in
/// `docs/dependencies/keyboard-shortcuts.md`, taken in preference to the
/// third-party package candidate recorded there. Two properties decide it.
///
/// It asks for **no permission**. A `CGEventTap` or a global `NSEvent` monitor
/// sees every keystroke on the Mac and needs Accessibility or Input Monitoring
/// to do it. A registered hot key asks the window server to deliver one chord
/// and nothing else; the app learns only that its own chord was pressed. For a
/// password manager that difference is the whole argument — the permission this
/// does not request is precisely the one that would let it read everything the
/// user types. The dependency document rules out monitors and taps for the same
/// reason.
///
/// And it adds no dependency. That document already requires VaultSquire to own
/// the recorder, the serialization, the conflict behaviour and the callback
/// lifetime whichever route is taken, which is all of the work; the package
/// would have supplied only what is below.
@MainActor
enum GlobalHotkey {
    /// Four characters identifying this app's hot keys in Carbon's shared
    /// namespace, so the callback can tell ours from another app's.
    private static let signature: OSType = 0x5653_5152  // 'VSQR'
    private static let identifier: UInt32 = 1

    private static var hotKeyRef: EventHotKeyRef?
    private static var eventHandler: EventHandlerRef?

    /// Whether a chord is currently claimed.
    static var isRegistered: Bool { hotKeyRef != nil }

    /// Claims a chord system-wide, replacing any previous claim.
    ///
    /// Returns false when the system or another application already holds it.
    /// That is the authoritative conflict check, and the reason this app keeps
    /// only a short table of its own chords rather than trying to predict every
    /// chord macOS and every other application might own.
    @discardableResult
    static func register(_ shortcut: QuickSearchShortcut, onPressed: @escaping () -> Void) -> Bool {
        unregister()
        // Stored before the handler is installed, so a chord pressed between
        // these two calls cannot find an empty box.
        pressHandler = { onPressed() }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installed = InstallEventHandler(
            GetApplicationEventTarget(), hotKeyCallback, 1, &eventType, nil, &eventHandler
        )
        guard installed == noErr else {
            unregister()
            AppLog.record(.quickSearchHotkeyUnavailable)
            return false
        }

        let hotKeyID = EventHotKeyID(signature: signature, id: identifier)
        let registered = RegisterEventHotKey(
            shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard registered == noErr else {
            // A failed registration must not strand the handler, or the next
            // attempt installs a second one on top of it.
            unregister()
            AppLog.record(.quickSearchHotkeyUnavailable)
            return false
        }
        return true
    }

    static func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        pressHandler = nil
    }
}

/// What to run when the chord arrives.
///
/// A file-scoped box rather than `self` passed through Carbon's opaque
/// `userData`: reconstructing a main-actor object from a raw pointer inside a C
/// callback is exactly the boundary strict concurrency exists to refuse, and
/// this app registers exactly one hot key, so there is no instance to
/// disambiguate. `nonisolated(unsafe)` is the honest annotation — it is written
/// only from the main actor, and read only from the callback, which runs on the
/// main thread as part of the application's own Carbon event dispatch.
private nonisolated(unsafe) var pressHandler: (@Sendable () -> Void)?

/// The C entry point. Verifies the event really is our hot key and hops to the
/// main actor before anything else happens.
private let hotKeyCallback: EventHandlerUPP = { _, event, _ in
    guard let event else { return OSStatus(eventNotHandledErr) }
    var pressed = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &pressed
    )
    guard status == noErr, pressed.signature == 0x5653_5152 else {
        return OSStatus(eventNotHandledErr)
    }
    if let handler = pressHandler {
        Task { @MainActor in handler() }
    }
    return noErr
}
