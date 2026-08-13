import XCTest
@testable import VaultSquire

final class VaultItemDetailTests: XCTestCase {
    func testOnlyNonSecretFieldsAllowTextSelection() {
        XCTAssertTrue(makeField(kind: .plain).allowsTextSelection)
        XCTAssertTrue(makeField(kind: .uri).allowsTextSelection)
        XCTAssertFalse(makeField(kind: .secret).allowsTextSelection)
        XCTAssertFalse(makeField(kind: .totpSeed).allowsTextSelection)
    }

    /// The concealed form is length-aware — a PIN must not look like a
    /// thirty-character password — and capped, so a long value does not become
    /// a wall of bullets.
    func testSecretMaskTracksLengthUpToTheCap() {
        XCTAssertEqual(VaultItemDetailView.mask(for: "1234").count, 4)
        XCTAssertEqual(VaultItemDetailView.mask(for: "abcdefghij").count, 10)
        XCTAssertEqual(VaultItemDetailView.mask(for: "x").count, 1)
        let long = String(repeating: "p", count: 80)
        XCTAssertEqual(VaultItemDetailView.mask(for: long).count, 12)
        XCTAssertTrue(VaultItemDetailView.mask(for: long).allSatisfy { $0 == "•" })
    }

    private func makeField(kind: VaultItemDetail.DetailField.Kind) -> VaultItemDetail.DetailField {
        VaultItemDetail.DetailField(
            id: "field",
            label: "Field",
            value: "VSQ-Synthetic-value",
            kind: kind
        )
    }
}
