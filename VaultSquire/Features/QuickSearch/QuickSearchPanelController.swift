import AppKit
import SwiftUI

@MainActor
final class QuickSearchPanelController: NSObject, NSWindowDelegate {
    private let model = QuickSearchPanelModel()
    private let panel: NSPanel

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
            items: items,
            isUnlocked: isUnlocked,
            vaultTitles: vaultTitles,
            onOpen: onOpen
        )
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
