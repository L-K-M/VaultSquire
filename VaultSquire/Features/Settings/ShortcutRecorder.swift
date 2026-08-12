import AppKit
import SwiftUI

/// Captures one key chord for Settings.
///
/// A local `NSEvent` monitor armed only while recording, rather than an
/// `NSViewRepresentable` that takes first responder and overrides
/// `performKeyEquivalent(_:)`/`keyDown(_:)`:
///
/// - One code path. A local monitor is invoked from the app's event dispatch
///   before the event reaches the key window, so it sees the chord whether or
///   not it carries Command. The responder route needs `performKeyEquivalent`
///   for Command chords (which AppKit offers to the key window's view
///   hierarchy before the main menu) *and* `keyDown` for everything else, and
///   has to reconcile the two.
/// - No first responder to win. The recorder sits in a `Form` of standard
///   controls; an `NSViewRepresentable` there has to take focus away from
///   SwiftUI, draw its own focus ring, restore focus on the way out, and cope
///   with the window resigning key while focused. That interplay is the larger
///   risk in this window, and none of it buys anything the monitor lacks.
/// - The codebase already runs this exact idiom twice —
///   `AutoLockController.start` and `QuickSearchPanelController.startKeyMonitor`
///   — including the Swift 6 shape: assert the isolation inline, let only a
///   `Bool` out of the block because `assumeIsolated` requires a `Sendable`
///   result and `NSEvent` is not one, and decide outside whether to swallow.
///
/// The cost is that the monitor is app-wide while armed, so it is armed by an
/// explicit button press, disarmed on the first key-down, and disarmed again
/// when Settings goes away. The `handled ? nil : event` return is the safety
/// net for the remaining case: if this object is deallocated while armed the
/// monitor cannot be removed from `deinit` (it is `@MainActor` and Swift 6
/// deinits are not isolated), so the block must pass events through rather
/// than swallow them once its owner is gone.
@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var isRecording = false

    /// Why the last chord was refused. Cleared when recording starts again.
    @Published private(set) var refusal: String?

    private var monitor: Any?
    private var onCapture: ((QuickSearchShortcut) -> Void)?

    func start(onCapture: @escaping (QuickSearchShortcut) -> Void) {
        guard monitor == nil else { return }
        self.onCapture = onCapture
        refusal = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.monitor != nil else { return false }
                self.handle(event)
                return true
            }
            // A chord that is refused must not also run whatever owns it: the
            // point of refusing Command-Q here is to say so, not to quit.
            return handled ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onCapture = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        // A held key repeats; the first press is the answer, and the repeats
        // must not reach the app either.
        guard !event.isARepeat else { return }
        let capture = QuickSearchShortcut.captured(from: event)
        let callback = onCapture
        stop()

        switch capture {
        case .cancelled:
            refusal = nil
        case .refused(let reason):
            refusal = reason
        case .accepted(let shortcut):
            // The static table cannot know what SwiftUI actually installed in
            // the menu bar, so the live menu gets the last word.
            if let owner = MainMenuShortcuts.owner(
                ofKey: shortcut.key,
                modifiers: shortcut.modifiers,
                excludingItemTitled: QuickSearchShortcutStore.menuItemTitle
            ) {
                refusal = "\(shortcut.displayName) is already the \(owner) command."
                return
            }
            refusal = nil
            callback?(shortcut)
        }
    }
}
