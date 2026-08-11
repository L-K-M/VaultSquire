import AppKit
import XCTest
@testable import VaultSquire

/// The clipboard contract from `SECURITY_AND_TESTING.md`: secrets expire,
/// clears are gated on the recorded change count so a later user copy is
/// never erased, and the value is never read back to prove ownership.
@MainActor
final class ClipboardServiceTests: XCTestCase {
    private final class FakePasteboard: ClipboardPasteboard {
        var changeCount = 0
        private(set) var contents: [NSPasteboard.PasteboardType: String] = [:]

        @discardableResult
        func clearContents() -> Int {
            contents = [:]
            changeCount += 1
            return changeCount
        }

        @discardableResult
        func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
            contents[type] = string
            // Only real content changes the count, like the system pasteboard.
            if type == .string, !string.isEmpty {
                changeCount += 1
            }
            return true
        }

        var string: String? { contents[.string] }
    }

    private func makeService(expiry: TimeInterval = 30) -> (ClipboardService, FakePasteboard) {
        let pasteboard = FakePasteboard()
        return (ClipboardService(pasteboard: pasteboard, secretExpiry: expiry), pasteboard)
    }

    func testSecretCopyRecordsOwnershipAndSetsConcealmentHints() {
        let (service, pasteboard) = makeService()
        service.copySecret("VSQ-Canary-secret")

        XCTAssertEqual(pasteboard.string, "VSQ-Canary-secret")
        XCTAssertNotNil(pasteboard.contents[ClipboardService.concealedType])
        XCTAssertNotNil(pasteboard.contents[ClipboardService.transientType])
        XCTAssertTrue(service.ownsSecret)
    }

    func testExpiryClearsAnOwnedSecret() async throws {
        let (service, pasteboard) = makeService(expiry: 0.05)
        service.copySecret("VSQ-Canary-secret")

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(pasteboard.string, "an expired owned secret is cleared")
        XCTAssertFalse(service.ownsSecret)
    }

    func testALaterUserCopyIsNeverErased() async throws {
        let (service, pasteboard) = makeService(expiry: 0.05)
        service.copySecret("VSQ-Canary-secret")

        // The user copies something else before the expiry fires.
        pasteboard.clearContents()
        pasteboard.setString("user's own copy", forType: .string)

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(
            pasteboard.string, "user's own copy",
            "the change-count gate must protect a copy that is not ours"
        )
    }

    func testClearIfOwnedClearsOnlyWhileTheCountMatches() {
        let (service, pasteboard) = makeService()
        service.copySecret("VSQ-Canary-secret")
        service.clearIfOwned()
        XCTAssertNil(pasteboard.string)

        service.copySecret("VSQ-Canary-secret-2")
        pasteboard.clearContents()
        pasteboard.setString("someone else's value", forType: .string)
        service.clearIfOwned()
        XCTAssertEqual(pasteboard.string, "someone else's value")
    }

    func testPlainCopyReplacesASecretAndDropsOwnership() {
        let (service, pasteboard) = makeService()
        service.copySecret("VSQ-Canary-secret")
        service.copyPlain("https://example.com")

        XCTAssertEqual(pasteboard.string, "https://example.com")
        XCTAssertFalse(service.ownsSecret)
        // A lock arriving now must not erase the user's plain value.
        service.clearIfOwned()
        XCTAssertEqual(pasteboard.string, "https://example.com")
    }

    func testLockClearWithNothingOwnedIsANoOp() {
        let (service, pasteboard) = makeService()
        pasteboard.setString("unrelated clipboard content", forType: .string)
        service.clearIfOwned()
        XCTAssertEqual(pasteboard.string, "unrelated clipboard content")
    }
}
