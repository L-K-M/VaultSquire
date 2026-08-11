import AppKit
import Foundation

/// The pasteboard surface `ClipboardService` needs, extracted so tests can
/// drive the ownership and expiry rules without a real system pasteboard.
/// `NSPasteboard` itself conforms.
protocol ClipboardPasteboard: AnyObject {
    var changeCount: Int { get }
    @discardableResult func clearContents() -> Int
    @discardableResult func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: ClipboardPasteboard {}

/// The single place a value is put on the system clipboard.
///
/// The clipboard section of `SECURITY_AND_TESTING.md` binds every copy of a
/// secret: it happens only after an explicit user action, it expires by
/// default after 30 seconds, the pasteboard `changeCount` recorded at write
/// time gates every clear (so a later user copy is never erased, and the value
/// is never read back to prove ownership), and the same conditional clear runs
/// on lock and on termination. Local-only/concealed hints are set for
/// clipboard managers that honor them; the documentation is explicit that a
/// clipboard manager may ignore them, and that clearing cannot revoke data
/// another process already read.
///
/// Non-secret values (titles, usernames, URLs) copy normally: they carry no
/// expiry, and writing one after a secret drops ownership of the secret
/// without touching the pasteboard — the secret's own expiry or a lock still
/// clears it only while the recorded change count matches.
@MainActor
final class ClipboardService {
    /// The shared instance the app uses. Tests construct isolated ones with a
    /// fake pasteboard.
    static let shared = ClipboardService()

    /// Default lifetime of a copied secret, per the security plan. A shorter
    /// preference may be layered on later; a longer one is not offered.
    static let defaultSecretExpiry: TimeInterval = 30

    /// Clipboard-manager hints that the value is a secret and should not be
    /// retained. Hints only: a manager that ignores them still sees the value,
    /// which is why expiry, not the hint, is the control.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let pasteboard: any ClipboardPasteboard
    private let secretExpiry: TimeInterval

    /// The change count recorded when the current secret was written. `nil`
    /// means VaultSquire owns nothing on the pasteboard right now.
    private var ownedChangeCount: Int?
    private var expiryTask: Task<Void, Never>?

    init(
        pasteboard: any ClipboardPasteboard = NSPasteboard.general,
        secretExpiry: TimeInterval = ClipboardService.defaultSecretExpiry
    ) {
        self.pasteboard = pasteboard
        self.secretExpiry = secretExpiry
    }

    /// Whether VaultSquire currently owns a secret on the pasteboard.
    var ownsSecret: Bool { ownedChangeCount != nil }

    /// Copies a secret (a password, card number, security code, or generated
    /// one-time code) with concealed/transient hints, records ownership, and
    /// arms the expiry. Never used for TOTP seeds, private keys, or recovery
    /// codes, which must never reach the clipboard at all.
    func copySecret(_ value: String) {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        // Empty-marker hint types. They are written after the value so the
        // recorded change count covers the whole write.
        pasteboard.setString("", forType: Self.concealedType)
        pasteboard.setString("", forType: Self.transientType)
        ownedChangeCount = pasteboard.changeCount
        armExpiry()
    }

    /// Copies a non-secret value with no expiry. If the previous pasteboard
    /// content was a VaultSquire secret, this write has already replaced it;
    /// ownership is simply dropped so a later clear can never erase the user's
    /// new value.
    func copyPlain(_ value: String) {
        expiryTask?.cancel()
        expiryTask = nil
        ownedChangeCount = nil
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    /// Clears the pasteboard only while it still holds the exact write this
    /// service recorded. Called on expiry, on lock, and on termination. A
    /// change-count mismatch means the user (or another app) has copied
    /// something since, and that value must survive.
    func clearIfOwned() {
        expiryTask?.cancel()
        expiryTask = nil
        guard let count = ownedChangeCount else { return }
        ownedChangeCount = nil
        guard pasteboard.changeCount == count else { return }
        pasteboard.clearContents()
    }

    private func armExpiry() {
        expiryTask?.cancel()
        let milliseconds = max(1, Int(secretExpiry * 1_000))
        expiryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(milliseconds))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.clearIfOwned()
        }
    }
}
