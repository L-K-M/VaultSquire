import AppKit
import Foundation

/// Writes a secret to the system pasteboard for a bounded lifetime, then clears
/// it only while this writer's copy still owns the pasteboard.
///
/// `SECURITY_AND_TESTING.md` (§ "Clipboard") requires a copied secret to expire
/// (default 30 seconds, with a shorter preference allowed), to be cleared
/// conditionally on the pasteboard's `changeCount` so a later copy by another
/// application is never erased, and to be cleared again on lock and
/// termination. The copied value is never retained and the pasteboard is never
/// read back to prove ownership: the change count recorded at write time is the
/// only proof of ownership, so this type holds no secret after the write.
///
/// Concealed/Transient pasteboard hints are set so clipboard managers and
/// Handoff are asked not to retain or sync the value. They are hints only; the
/// timed, conditional clear above is the real control, and a clipboard manager
/// that ignores them can still read the value before it expires — a residual
/// risk the product states honestly rather than claiming absolute prevention.
@MainActor
final class SecretPasteboard {
    static let shared = SecretPasteboard()

    /// The default secret lifetime, matching the documented default.
    static let defaultExpiry: TimeInterval = 30

    private let pasteboard: NSPasteboard
    private let sleep: (TimeInterval) async -> Void
    private var ownedChangeCount: Int?
    private var clearTask: Task<Void, Never>?

    init(
        pasteboard: NSPasteboard = .general,
        sleep: @escaping (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(max(0, seconds)))
        }
    ) {
        self.pasteboard = pasteboard
        self.sleep = sleep
    }

    /// Writes `value` and schedules a conditional clear after `expiry`. A
    /// subsequent write cancels the previous clear and starts its own window, so
    /// only the most recent copy's lifetime is in flight.
    func copy(_ value: String, expiry: TimeInterval = SecretPasteboard.defaultExpiry) {
        cancelClear()

        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        // Community-standard hints (nspasteboard.org): a concealed value is
        // excluded from clipboard history, and a transient one is not persisted
        // or handed off. Presence of the type is the signal; the stored value
        // is empty. These are best-effort and do not replace the timed clear.
        pasteboard.setString("", forType: Self.concealedType)
        pasteboard.setString("", forType: Self.transientType)

        // `changeCount` is non-optional, so the recorded value is taken
        // directly: it is the proof of ownership for the conditional clear.
        let recorded = pasteboard.changeCount
        ownedChangeCount = recorded
        clearTask = Task { [weak self] in
            await self?.sleep(expiry)
            // Cancellation is re-checked after the sleep so a second copy that
            // cancelled this task cannot have its value cleared by this one.
            guard !Task.isCancelled else { return }
            self?.clearIfStillOwning(recorded)
        }
    }

    /// Clears the pasteboard only if this writer's recorded change count is
    /// still current. A copy made by another application in the meantime bumps
    /// the count, so its value is left intact rather than erased.
    func clearIfStillOwning(_ changeCount: Int) {
        guard pasteboard.changeCount == changeCount else { return }
        pasteboard.clearContents()
        if ownedChangeCount == changeCount {
            ownedChangeCount = nil
        }
    }

    /// Clears the pasteboard if this writer currently owns it, and stops the
    /// pending clear. Idempotent; called on lock and termination so a copied
    /// secret does not outlive the session that produced it.
    func clearIfOwning() {
        cancelClear()
        guard let ownedChangeCount else { return }
        clearIfStillOwning(ownedChangeCount)
    }

    /// Awaits the scheduled clear, or returns immediately if none is pending.
    /// Lets tests observe the post-expiry state deterministically instead of
    /// polling a real timer. DEBUG-only so it cannot ship in a release build.
    #if DEBUG
    func awaitScheduledClearForTesting() async {
        await clearTask?.value
    }
    #endif

    private func cancelClear() {
        clearTask?.cancel()
        clearTask = nil
    }

    internal static let concealedType = NSPasteboard.PasteboardType(rawValue: "org.nspasteboard.ConcealedType")
    internal static let transientType = NSPasteboard.PasteboardType(rawValue: "org.nspasteboard.TransientType")
}
