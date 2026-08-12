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

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 330),
            styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
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
        onOpen: ((VaultItemID) -> Void)? = nil
    ) {
        model.clear()
        if !panel.isVisible {
            panel.center()
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        // Announced only after the panel is key, so the view's focus assignment
        // cannot run while first responder still belongs to the window.
        model.present(
            items: items, isUnlocked: isUnlocked, vaultTitles: vaultTitles, onOpen: onOpen
        )
        PerformanceTrace.record(.quickSearchVisible)
        AppLog.record(.quickSearchPresented)
        startKeyMonitor()
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
            MainActor.assumeIsolated {
                guard let self,
                      event.window === self.panel,
                      event.modifierFlags.isDisjoint(with: [.command, .option, .control])
                else { return event }
                switch event.keyCode {
                case 125: self.model.moveSelection(by: 1); return nil   // down
                case 126: self.model.moveSelection(by: -1); return nil  // up
                case 115: self.model.selectFirst(); return nil          // home
                case 119: self.model.selectLast(); return nil           // end
                default: return event
                }
            }
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

    func dismiss() {
        stopKeyMonitor()
        model.clear()
        panel.orderOut(nil)
        AppLog.record(.quickSearchDismissed)
    }

    /// Reached only through the panel's close button; Escape and the explicit lock
    /// path both go through `dismiss()`. Both routes must record the dismissal so
    /// the diagnostic event cannot be missing for one of them.
    func windowWillClose(_ notification: Notification) {
        stopKeyMonitor()
        model.clear()
        AppLog.record(.quickSearchDismissed)
    }
}
