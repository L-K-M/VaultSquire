import AppKit
import Foundation

/// The seam around the system pasteboard the controller writes through, so
/// tests can observe writes and change counts without touching the real
/// pasteboard.
protocol PasteboardWriting: Sendable {
    /// Replaces the pasteboard contents with `value` and returns the new
    /// change count.
    func replaceContents(with value: String) -> Int
    /// The pasteboard's current change count.
    func currentChangeCount() -> Int
    /// Clears the pasteboard.
    func clearContents()
}

/// The production pasteboard: the general pasteboard.
struct SystemPasteboard: PasteboardWriting {
    func replaceContents(with value: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        return pasteboard.changeCount
    }

    func currentChangeCount() -> Int {
        NSPasteboard.general.changeCount
    }

    func clearContents() {
        NSPasteboard.general.clearContents()
    }
}

/// Owns VaultSquire's clipboard writes so a copied secret can be cleared
/// after a short lifetime, and on lock or termination — but only while the
/// pasteboard still holds the value this app wrote. The change count is
/// recorded at write time and compared at clear time, so a value the user
/// copied afterwards is never erased (SECURITY_AND_TESTING.md §"Clipboard").
///
/// The controller deliberately does not read the pasteboard back: the change
/// count is sufficient proof of ownership, and reading extends the plaintext's
/// lifetime.
@MainActor
final class ClipboardValueController {
    /// The one instance the app uses, so lock and termination reach the same
    /// state as the copy buttons.
    static let shared = ClipboardValueController()

    /// The lifetime of a copied secret before it is cleared (the documented
    /// default; a shorter user preference can be layered on later).
    static let defaultExpiry: TimeInterval = 30

    private let pasteboard: any PasteboardWriting
    private let schedule: @Sendable (@escaping @MainActor () -> Void, TimeInterval) -> Void
    /// The change counts of secrets this app copied that have not expired yet.
    private var pendingExpiries: [Int] = []

    init(
        pasteboard: any PasteboardWriting = SystemPasteboard(),
        schedule: @escaping @Sendable (@escaping @MainActor () -> Void, TimeInterval) -> Void = {
            closure, delay in
            let timer = Timer(timeInterval: delay, repeats: false) { _ in
                Task { @MainActor in
                    closure()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    ) {
        self.pasteboard = pasteboard
        self.schedule = schedule
    }

    /// Writes `value` to the pasteboard. When `expires` is true the value is
    /// cleared after `Self.defaultExpiry` seconds — or sooner on lock or
    /// termination — unless the user copied something else in the meantime.
    func copy(_ value: String, expires: Bool) {
        let changeCount = pasteboard.replaceContents(with: value)
        guard expires else { return }
        pendingExpiries.append(changeCount)
        schedule({ [weak self] in
            self?.expire(changeCount)
        }, Self.defaultExpiry)
    }

    /// Clears the value this app most recently wrote if the pasteboard still
    /// holds it. Called on lock, on termination, and when a copy's lifetime
    /// ends. A later user copy (a change count this app does not own) is never
    /// erased.
    func clearIfOwned() {
        let current = pasteboard.currentChangeCount()
        if pendingExpiries.contains(current) {
            pasteboard.clearContents()
        }
        pendingExpiries.removeAll()
    }

    private func expire(_ changeCount: Int) {
        if pasteboard.currentChangeCount() == changeCount {
            pasteboard.clearContents()
        }
        pendingExpiries.removeAll { $0 == changeCount }
    }
}
