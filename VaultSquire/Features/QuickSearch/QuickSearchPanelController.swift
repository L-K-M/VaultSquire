import AppKit
import SwiftUI

@MainActor
final class QuickSearchPanelController: NSObject, NSWindowDelegate {
    private let model = QuickSearchPanelModel()
    private let panel: NSPanel
    /// Observes the panel's key events so the arrow keys move the result
    /// highlight while the search field keeps focus. Only the arrows are
    /// consumed; everything else, Return included, reaches the field.
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

        // The search field holds focus, so arrow keys never reach the result
        // list on their own. Intercept them at the panel instead: up and down
        // move the model's highlight, and every other key passes through to
        // the field (Return is handled by the field's onSubmit).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window == self.panel, event.modifierFlags.isDisjoint(with: [.command, .option, .control]) else {
                return event
            }
            switch event.keyCode {
            case 125: // down arrow
                self.model.moveSelection(by: 1)
                return nil
            case 126: // up arrow
                self.model.moveSelection(by: -1)
                return nil
            default:
                return event
            }
        }
    }

    var windowForTesting: NSPanel {
        panel
    }

    var modelForTesting: QuickSearchPanelModel {
        model
    }

    func show(
        items: [VaultItemProjection] = [],
        isUnlocked: Bool = false,
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
        model.present(items: items, isUnlocked: isUnlocked, onOpen: onOpen)
        PerformanceTrace.record(.quickSearchVisible)
        AppLog.record(.quickSearchPresented)
    }

    func dismiss() {
        model.clear()
        panel.orderOut(nil)
        AppLog.record(.quickSearchDismissed)
    }

    /// Reached only through the panel's close button; Escape and the explicit lock
    /// path both go through `dismiss()`. Both routes must record the dismissal so
    /// the diagnostic event cannot be missing for one of them.
    func windowWillClose(_ notification: Notification) {
        model.clear()
        AppLog.record(.quickSearchDismissed)
    }
}
