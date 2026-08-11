import XCTest
@testable import VaultSquire

/// Exercises the clipboard invariants in SECURITY_AND_TESTING.md § "Clipboard":
/// a copied secret expires, the conditional clear never erases another app's
/// later copy, and lock/termination clears a secret this app still owns.
///
/// Tests use private named pasteboards (never the system pasteboard) and
/// synthetic canary values, never real vault data.
@MainActor
final class SecretPasteboardTests: XCTestCase {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("VSQ-clipboard-test-\(UUID().uuidString)"))
    }

    /// A sleep that returns immediately, so the timed clear fires as soon as the
    /// scheduled task runs. Used by the expiry test.
    private let immediateSleep: (TimeInterval) async -> Void = { _ in }

    /// A sleep that does not return on its own, so the timed clear stays pending
    /// and never interferes with a test that exercises the explicit clear paths.
    private let blockingSleep: (TimeInterval) async -> Void = { _ in
        try? await Task.sleep(for: .seconds(3_600))
    }

    override func tearDown() async {
        // No shared mutable store is held between tests; named pasteboards are
        // discarded with each test instance.
        await super.tearDown()
    }

    func testCopyWritesValueAndConcealedTransientHints() {
        let pasteboard = makePasteboard()
        let store = SecretPasteboard(pasteboard: pasteboard, sleep: blockingSleep)
        defer { store.clearIfOwning() }

        store.copy("VSQ-canary-secret")

        XCTAssertEqual(pasteboard.string(forType: .string), "VSQ-canary-secret")
        // Clipboard managers and Handoff are asked not to retain/sync the value.
        XCTAssertNotNil(pasteboard.string(forType: Self.concealedType))
        XCTAssertNotNil(pasteboard.string(forType: Self.transientType))
    }

    func testClearsAfterExpiry() async {
        let pasteboard = makePasteboard()
        let store = SecretPasteboard(pasteboard: pasteboard, sleep: immediateSleep)

        store.copy("VSQ-canary-secret")
        XCTAssertEqual(pasteboard.string(forType: .string), "VSQ-canary-secret")

        await store.awaitScheduledClearForTesting()

        // No other write displaced this one, so the timed clear removed it.
        XCTAssertTrue(cleared(pasteboard))
    }

    func testConditionalClearLeavesAnotherAppsCopyIntact() {
        let pasteboard = makePasteboard()
        let store = SecretPasteboard(pasteboard: pasteboard, sleep: blockingSleep)
        defer { store.clearIfOwning() }

        store.copy("VSQ-canary-secret")
        let recorded = pasteboard.changeCount

        // Another application writes to the pasteboard, bumping the change count
        // past the value this writer recorded.
        pasteboard.clearContents()
        pasteboard.setString("someone-else", forType: .string)

        store.clearIfStillOwning(recorded)

        // The other write is left intact; this writer did not erase it.
        XCTAssertEqual(pasteboard.string(forType: .string), "someone-else")
    }

    func testClearIfOwningClearsWhenStillOwner() {
        let pasteboard = makePasteboard()
        let store = SecretPasteboard(pasteboard: pasteboard, sleep: blockingSleep)
        defer { store.clearIfOwning() }

        store.copy("VSQ-canary-secret")
        XCTAssertEqual(pasteboard.string(forType: .string), "VSQ-canary-secret")

        store.clearIfOwning()
        XCTAssertTrue(cleared(pasteboard))
    }

    func testClearIfOwningLeavesDisplacedCopyIntact() {
        let pasteboard = makePasteboard()
        let store = SecretPasteboard(pasteboard: pasteboard, sleep: blockingSleep)
        defer { store.clearIfOwning() }

        store.copy("VSQ-canary-secret")

        // Another write displaces this writer's copy.
        pasteboard.clearContents()
        pasteboard.setString("someone-else", forType: .string)

        store.clearIfOwning()
        XCTAssertEqual(pasteboard.string(forType: .string), "someone-else")
    }

    func testClearIfOwningIsNoOpWhenNothingCopied() {
        let pasteboard = makePasteboard()
        let store = SecretPasteboard(pasteboard: pasteboard, sleep: blockingSleep)

        // No prior copy: clearing must be a harmless no-op.
        store.clearIfOwning()
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testSecondCopyReplacesValueAndKeepsOnlyItsOwnWindow() async {
        let pasteboard = makePasteboard()
        let store = SecretPasteboard(pasteboard: pasteboard, sleep: immediateSleep)

        store.copy("first")
        XCTAssertEqual(pasteboard.string(forType: .string), "first")

        store.copy("second")
        XCTAssertEqual(pasteboard.string(forType: .string), "second")

        await store.awaitScheduledClearForTesting()
        // The second copy's clear fired and removed it; the first copy's stale
        // clear could not have erased anything else because it never owned a
        // later change count.
        XCTAssertTrue(cleared(pasteboard))
    }

    // MARK: - Private

    /// True when no string value remains, whether the pasteboard reports that as
    /// nil or an empty string (NSPasteboard is inconsistent between the two).
    private func cleared(_ pasteboard: NSPasteboard) -> Bool {
        (pasteboard.string(forType: .string) ?? "").isEmpty
    }

    private static let concealedType = NSPasteboard.PasteboardType(rawValue: "org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType(rawValue: "org.nspasteboard.TransientType")
}
