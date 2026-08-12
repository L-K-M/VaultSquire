import AppKit
import SwiftUI

/// A brief note that a copy happened, shown after Quick Search has gone.
///
/// The panel dismisses itself on a successful copy and hands focus back to
/// whatever the user was in, which leaves them looking at their own window with
/// no sign anything occurred — the value is on the clipboard and nothing says
/// so. That reads as a shortcut that did nothing.
///
/// Two rules it lives by. It never shows a value, only which kind of value was
/// copied: the strings come from `QuickSearchCopy.name` and are fixed. And it
/// is non-activating and click-through, so the focus Quick Search just handed
/// back is not taken away again by the thing announcing the handover.
@MainActor
enum CopyConfirmationPanel {
    private static var current: NSPanel?
    private static var dismissal: Task<Void, Never>?

    static let visibleDuration: Duration = .seconds(2)

    /// Says what was copied, and how long a secret will last.
    ///
    /// The expiry is worth saying because it is short and the user cannot see
    /// it anywhere else; a username carries none, and claiming one would be a
    /// lie in the safe direction rather than a harmless simplification.
    static func show(_ copied: QuickSearchCopy) {
        let expires = copied != .username
        let detail = expires
            ? "Press Command-V to paste. Clears in \(Int(ClipboardService.defaultSecretExpiry)) seconds."
            : "Press Command-V to paste."
        present(title: "\(copied.name) copied", detail: detail)
    }

    static func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        current?.orderOut(nil)
        current = nil
    }

    private static func present(title: String, detail: String) {
        dismiss()

        let hosting = NSHostingView(rootView: ConfirmationView(title: title, detail: detail))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        // Click-through. The user has just been handed back to their own
        // window; a HUD that swallowed the next click would undo that.
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // Nothing on it is secret, but it is still a window naming vault
        // activity, so it is excluded from captures like every other one.
        panel.sharingType = .none
        panel.contentView = hosting

        if let frame = (screenUnderPointer() ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.midY - size.height / 2
            ))
        }
        panel.orderFrontRegardless()
        current = panel

        dismissal = Task { @MainActor in
            try? await Task.sleep(for: visibleDuration)
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    /// The screen the pointer is on, which is where the user is looking — the
    /// main screen is where the menu bar is, which may be neither.
    private static func screenUnderPointer() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
    }
}

private struct ConfirmationView: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }
}
