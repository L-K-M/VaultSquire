import AppKit
import SwiftUI

@MainActor
final class QuickSearchPanelController: NSObject, NSWindowDelegate {
    private let model = QuickSearchPanelModel()
    private let panel: NSPanel
    /// Consumes the arrow keys before the search field's field editor does.
    /// The field owns first responder and AppKit implements `moveUp:` and
    /// `moveDown:` on it, so an ancestor's `onKeyPress` never sees them. Held
    /// only while the panel is on screen: a monitor installed in `init` is
    /// process-wide and would keep intercepting keys for other windows.
    private var keyMonitor: Any?
    /// The application that was frontmost when the panel was summoned.
    ///
    /// A launcher exists to put a value into the window the user was already
    /// typing in, so dismissing has to hand focus back there rather than
    /// leaving them in VaultSquire with a clipboard they cannot paste. Nil when
    /// VaultSquire itself was frontmost — which is every invocation while the
    /// shortcut is a menu command, since a menu cannot fire unless this app is
    /// already active. There is then nothing to return to.
    private var previousApplication: NSRunningApplication?
    /// Guards the teardown, which `orderOut` re-enters through
    /// `windowDidResignKey`.
    private var isDismissing = false

    override init() {
        panel = KeyableQuickSearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 366),
            // `.nonactivatingPanel` is what makes this a launcher rather than a
            // window: summoned from another application by the global chord, it
            // comes forward without dragging VaultSquire's own windows up with
            // it and without making VaultSquire the active app — so the app the
            // user was in is still there to hand focus back to.
            styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        super.init()

        panel.title = "Quick Search"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self

        panel.contentViewController = NSHostingController(
            rootView: QuickSearchView(model: model) { [weak self] in
                self?.dismiss()
            }
        )
    }

    var windowForTesting: NSPanel {
        panel
    }

    var modelForTesting: QuickSearchPanelModel {
        model
    }

    /// Whether the panel is on screen, so the coordinator can keep a visible
    /// panel's list current without ever raising a dismissed one.
    var isVisible: Bool {
        panel.isVisible
    }

    func show(
        items: [VaultItemProjection] = [],
        isUnlocked: Bool = false,
        vaultTitles: [AccountID: String] = [:],
        onOpen: ((VaultItemID) -> Void)? = nil,
        onDeliver: ((
            QuickSearchCopy, VaultItemID, SecretDelivery, @escaping @MainActor () -> Void
        ) async -> SecretDeliveryOutcome)? = nil,
        onCancelCopy: ((VaultItemID) -> Void)? = nil
    ) {
        model.clear()
        if !panel.isVisible {
            panel.center()
            // Captured before activating, and only on a fresh presentation:
            // re-invoking the shortcut over a visible panel would otherwise
            // record VaultSquire as the application to go back to and lose the
            // one the user actually came from.
            previousApplication = frontmostOtherApplication()
        }
        // The panel is made key without activating the application: a
        // non-activating panel can hold first responder for its search field
        // while the app the user came from stays active underneath. That is
        // what lets the copy actions end with focus back where it started.
        panel.makeKeyAndOrderFront(nil)
        // Announced only after the panel is key, so the view's focus assignment
        // cannot run while first responder still belongs to the window.
        model.present(
            items: items,
            isUnlocked: isUnlocked,
            vaultTitles: vaultTitles,
            onOpen: onOpen,
            onDeliver: onDeliver,
            // Typing needs somewhere to type. When VaultSquire was already
            // frontmost there is no previous application, and the clipboard is
            // the only thing that makes sense.
            deliveryTarget: previousApplication.map { .typed(intoProcess: $0.processIdentifier) }
                ?? .clipboard,
            onCancelCopy: onCancelCopy,
            onFinish: { [weak self] restoringFocus in
                self?.dismiss(restoringFocus: restoringFocus)
            },
            onCopied: { copied, outcome in
                CopyConfirmationPanel.show(copied, outcome)
            }
        )
        PerformanceTrace.record(.quickSearchVisible)
        AppLog.record(.quickSearchPresented)
        startKeyMonitor()
    }

    private func frontmostOtherApplication() -> NSRunningApplication? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        return frontmost
    }

    /// Arrow keys, Home and End move the highlight while the search field keeps
    /// the text cursor and first responder.
    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // A local monitor is delivered on the main thread, and its return
            // value decides synchronously whether the field sees the key, so
            // the isolation is asserted rather than hopped through — the same
            // pattern the auto-lock input monitor uses.
            //
            // Only a Bool comes back out. `NSEvent` is not `Sendable`, so
            // returning the event itself across the isolation boundary does not
            // compile under Swift 6; the event is swallowed or passed on here
            // instead, outside the block.
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self.panel else { return false }
                let modifiers = event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                    .subtracting([.capsLock, .function, .numericPad])

                // Return and its modified forms are read here rather than
                // through the field's `onSubmit`, which sees only the plain
                // one: a single-line field editor maps Shift-Return and
                // Option-Return to `insertNewlineIgnoringFieldEditor:`, which
                // never fires the field's action, so those two would silently
                // do nothing.
                if event.keyCode == 36 || event.keyCode == 76 {
                    switch modifiers {
                    case []: self.model.perform(.primary)
                    case [.shift]: self.model.perform(.copyUsername)
                    case [.option]: self.model.perform(.copyOneTimeCode)
                    case [.command]: self.model.perform(.show)
                    default: return false
                    }
                    return true
                }

                guard modifiers.isDisjoint(with: [.command, .option, .control]) else {
                    return false
                }
                switch event.keyCode {
                case 125: self.model.moveSelection(by: 1)   // down
                case 126: self.model.moveSelection(by: -1)  // up
                case 115: self.model.selectFirst()          // home
                case 119: self.model.selectLast()           // end
                default: return false
                }
                return true
            }
            return handled ? nil : event
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    /// Refreshes what a visible panel is searching, leaving the query and the
    /// focus alone.
    func update(
        items: [VaultItemProjection],
        isUnlocked: Bool,
        vaultTitles: [AccountID: String] = [:]
    ) {
        model.update(items: items, isUnlocked: isUnlocked, vaultTitles: vaultTitles)
    }

    /// Takes the panel down. `restoringFocus` is false only when the user asked
    /// to be taken into VaultSquire, when they moved focus themselves, and when
    /// something other than the user closed the panel — a lock or a
    /// termination, where pushing them into whatever was behind us is its own
    /// surprise.
    func dismiss(restoringFocus: Bool = true) {
        guard !isDismissing else { return }
        isDismissing = true
        defer { isDismissing = false }

        stopKeyMonitor()
        model.cancelInFlightWork()
        model.clear()
        panel.orderOut(nil)
        if restoringFocus, let previous = previousApplication, !previous.isTerminated {
            // macOS 14 replaced "activate ignoring other apps" with a
            // cooperative handoff: the active application yields first and the
            // target then comes forward, rather than the system treating it as
            // an application stealing focus from the user.
            NSApp.yieldActivation(to: previous)
            previous.activate()
        }
        previousApplication = nil
        AppLog.record(.quickSearchDismissed)
    }

    /// Clicking another window is a dismissal: the panel floats over every
    /// application with a list of titles and usernames on it and must not be
    /// left behind. Focus is already where the user put it, so nothing is
    /// handed back. Held open during a fetch, because a provider CLI that
    /// raises its own authorization prompt takes key status away from us.
    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible, !model.isWorking else { return }
        dismiss(restoringFocus: false)
    }

    /// Reached only through the panel's close button; Escape and the explicit lock
    /// path both go through `dismiss()`. Both routes must record the dismissal so
    /// the diagnostic event cannot be missing for one of them.
    func windowWillClose(_ notification: Notification) {
        stopKeyMonitor()
        model.cancelInFlightWork()
        model.clear()
        previousApplication = nil
        AppLog.record(.quickSearchDismissed)
    }
}

/// A panel that can take key status and first responder despite being
/// non-activating, so the search field accepts typing when the panel was
/// summoned from another application. `NSPanel` refuses both by default for a
/// non-activating style mask.
private final class KeyableQuickSearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
