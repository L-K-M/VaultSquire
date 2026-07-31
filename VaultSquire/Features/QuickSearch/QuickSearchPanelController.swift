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
            rootView: QuickSearchView(model: model) { [weak panel, weak model] in
                model?.clear()
                panel?.orderOut(nil)
            }
        )
    }

    var windowForTesting: NSPanel {
        panel
    }

    func show() {
        model.clear()
        if !panel.isVisible {
            panel.center()
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        PerformanceTrace.record(.quickSearchVisible)
        AppLog.record(.quickSearchPresented)
    }

    func dismiss() {
        model.clear()
        panel.orderOut(nil)
        AppLog.record(.quickSearchDismissed)
    }

    func windowWillClose(_ notification: Notification) {
        model.clear()
    }
}
