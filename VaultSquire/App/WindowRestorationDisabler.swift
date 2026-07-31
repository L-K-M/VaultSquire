import AppKit
import SwiftUI

@MainActor
private final class NonRestoringView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.isRestorable = false
    }
}

struct WindowRestorationDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NonRestoringView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.isRestorable = false
    }
}
